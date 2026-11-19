// probe is the Home Assistant example's visitor (README.md,
// scripts/test-home-assistant.sh): the phone or laptop away from
// home, plus the one-time onboarding of the test's Home Assistant. Every
// subcommand prints one JSON object and exits 1 when a check fails.
//
//	probe onboard -base http://127.0.0.1:8123 -token FILE
//	probe check   -base URL -addr HOST:PORT -pin SHA256 -token FILE
//	probe bench   -base URL -addr HOST:PORT -pin SHA256 -token FILE -n N
//	probe wait    -base URL -addr HOST:PORT -pin SHA256 -token FILE -timeout D
//	probe ports   -host IP -ports 80,443,...
//
// -addr is where the visitor's TCP connection goes (the test's stand-in for
// DNS); -pin is the SHA-256 of the certificate the visitor must see (the
// test's stand-in for a public CA). Not part of either setup: README.md
// counts it apart.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const clientID = "http://probe.example/"

type probe struct {
	base, addr, pin, token string
	read                   atomic.Int64 // bytes read from the server
	hc                     *http.Client
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: probe onboard|check|bench|wait|ports [flags]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	base := fs.String("base", "", "Home Assistant's URL as the visitor uses it")
	addr := fs.String("addr", "", "host:port to connect to (default: the URL's)")
	pin := fs.String("pin", "", "SHA-256 (hex) of the certificate the visitor must see")
	tokenFile := fs.String("token", "", "file holding the long-lived access token")
	n := fs.Int("n", 200, "bench: requests and events")
	timeout := fs.Duration("timeout", 2*time.Minute, "wait: give up after")
	host := fs.String("host", "", "ports: the address to try")
	ports := fs.String("ports", "", "ports: comma-separated")
	_ = fs.Parse(os.Args[2:])

	p := &probe{base: strings.TrimSuffix(*base, "/"), addr: *addr, pin: *pin}
	p.hc = &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{DialTLSContext: p.dialTLS, DialContext: p.dial}}
	if *tokenFile != "" && os.Args[1] != "onboard" {
		b, err := os.ReadFile(*tokenFile) // #nosec G304 G703 -- the test names it
		die(err)
		p.token = strings.TrimSpace(string(b))
	}
	var out any
	var err error
	switch os.Args[1] {
	case "onboard":
		err = p.onboard(*tokenFile)
		out = map[string]bool{"onboarded": err == nil}
	case "check":
		out, err = p.check()
	case "bench":
		out, err = p.bench(*n)
	case "wait":
		out, err = p.wait(*timeout)
	case "ports":
		out = openPorts(*host, *ports)
	default:
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if out != nil {
		b, _ := json.Marshal(out)
		fmt.Println(string(b))
	}
	die(err)
}

func die(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "probe:", err)
		os.Exit(1)
	}
}

// ---- transport: where the visitor connects and what it trusts ----

type counted struct {
	net.Conn
	n *atomic.Int64
}

func (c counted) Read(b []byte) (int, error) {
	k, err := c.Conn.Read(b)
	c.n.Add(int64(k))
	return k, err
}

func (p *probe) dial(ctx context.Context, network, a string) (net.Conn, error) {
	if p.addr != "" {
		a = p.addr
	}
	c, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, network, a)
	if err != nil {
		return nil, err
	}
	return counted{c, &p.read}, nil
}

func (p *probe) dialTLS(ctx context.Context, network, a string) (net.Conn, error) {
	host, _, _ := net.SplitHostPort(a)
	raw, err := p.dial(ctx, network, a)
	if err != nil {
		return nil, err
	}
	c := tls.Client(raw, &tls.Config{
		ServerName: host, MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"},
		InsecureSkipVerify: true, // #nosec G402 -- verified by the pin below
		// #nosec G123 -- no ClientSessionCache: every connection is a full handshake, so the pin check always runs
		VerifyPeerCertificate: func(certs [][]byte, _ [][]*x509.Certificate) error {
			if len(certs) > 0 {
				if s := sha256.Sum256(certs[0]); hex.EncodeToString(s[:]) == p.pin {
					return nil
				}
			}
			return errors.New("the server's certificate does not match the pin")
		},
	})
	if err := c.HandshakeContext(ctx); err != nil {
		_ = c.Close()
		return nil, err
	}
	return c, nil
}

func (p *probe) do(method, path, token string, body io.Reader, ctype string) (int, []byte, error) {
	req, err := http.NewRequest(method, p.base+path, body)
	if err != nil {
		return 0, nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	resp, err := p.hc.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	b, err := io.ReadAll(resp.Body)
	return resp.StatusCode, b, err
}

// ---- Home Assistant's WebSocket API (/api/websocket), a minimal client ----

type ws struct {
	c  net.Conn
	r  *bufio.Reader
	id int
}

func (p *probe) wsOpen() (*ws, error) {
	u, err := url.Parse(p.base)
	if err != nil {
		return nil, err
	}
	a := u.Host
	if u.Port() == "" {
		a = net.JoinHostPort(u.Hostname(), map[string]string{"https": "443", "http": "80"}[u.Scheme])
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var c net.Conn
	if u.Scheme == "https" {
		c, err = p.dialTLS(ctx, "tcp", a)
	} else {
		c, err = p.dial(ctx, "tcp", a)
	}
	if err != nil {
		return nil, err
	}
	key := make([]byte, 16)
	_, _ = rand.Read(key)
	_, _ = fmt.Fprintf(c, "GET /api/websocket HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		u.Host, base64.StdEncoding.EncodeToString(key))
	r := bufio.NewReader(c)
	resp, err := http.ReadResponse(r, nil)
	if err != nil {
		_ = c.Close()
		return nil, err
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		_ = c.Close()
		return nil, fmt.Errorf("websocket upgrade: HTTP %d", resp.StatusCode)
	}
	return &ws{c: c, r: r}, nil
}

func (w *ws) send(v map[string]any) error {
	if _, ok := v["type"]; ok && v["type"] != "auth" {
		w.id++
		v["id"] = w.id
	}
	payload, _ := json.Marshal(v)
	hdr := []byte{0x81} // FIN, text
	switch n := len(payload); {
	case n < 126:
		hdr = append(hdr, 0x80|byte(n))
	case n < 1<<16:
		hdr = append(hdr, 0x80|126, byte(n>>8), byte(n)) // #nosec G115 -- n < 1<<16 in this case
	default:
		hdr = append(hdr, 0x80|127)
		hdr = binary.BigEndian.AppendUint64(hdr, uint64(n))
	}
	mask := make([]byte, 4)
	_, _ = rand.Read(mask)
	hdr = append(hdr, mask...)
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	_ = w.c.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err := w.c.Write(append(hdr, payload...))
	return err
}

// recv returns the next text message (Home Assistant sends unfragmented,
// unmasked frames; pings are answered by nothing and skipped).
func (w *ws) recv() (map[string]any, error) {
	_ = w.c.SetReadDeadline(time.Now().Add(15 * time.Second))
	for {
		h := make([]byte, 2)
		if _, err := io.ReadFull(w.r, h); err != nil {
			return nil, err
		}
		n := uint64(h[1] & 0x7f)
		switch n {
		case 126:
			b := make([]byte, 2)
			if _, err := io.ReadFull(w.r, b); err != nil {
				return nil, err
			}
			n = uint64(binary.BigEndian.Uint16(b))
		case 127:
			b := make([]byte, 8)
			if _, err := io.ReadFull(w.r, b); err != nil {
				return nil, err
			}
			n = binary.BigEndian.Uint64(b)
		}
		if n > 64<<20 {
			return nil, fmt.Errorf("websocket frame of %d bytes", n)
		}
		body := make([]byte, n)
		if _, err := io.ReadFull(w.r, body); err != nil {
			return nil, err
		}
		switch h[0] & 0x0f {
		case 0x8:
			return nil, errors.New("websocket closed by the server")
		case 0x1:
			var m map[string]any
			return m, json.Unmarshal(body, &m)
		}
	}
}

// auth runs Home Assistant's WebSocket handshake: auth_required, auth,
// then auth_ok or auth_invalid.
func (w *ws) auth(token string) (string, error) {
	if m, err := w.recv(); err != nil || m["type"] != "auth_required" {
		return "", fmt.Errorf("no auth_required: %v %v", m, err)
	}
	if err := w.send(map[string]any{"type": "auth", "access_token": token}); err != nil {
		return "", err
	}
	m, err := w.recv()
	if err != nil {
		return "", err
	}
	t, _ := m["type"].(string)
	return t, nil
}

// result waits for the answer to the last command sent.
func (w *ws) result() (map[string]any, error) {
	for {
		m, err := w.recv()
		if err != nil {
			return nil, err
		}
		if m["type"] == "result" && m["id"] == float64(w.id) {
			if m["success"] != true {
				return m, fmt.Errorf("command failed: %v", m["error"])
			}
			return m, nil
		}
	}
}

// ---- subcommands ----

// onboard creates the owner account on a fresh Home Assistant (the
// onboarding API the first browser visit uses) and a long-lived access
// token for the probe.
func (p *probe) onboard(tokenFile string) error {
	deadline := time.Now().Add(3 * time.Minute)
	for {
		code, _, err := p.do("GET", "/api/onboarding", "", nil, "")
		if err == nil && code == 200 {
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Home Assistant never answered /api/onboarding: %d %v", code, err)
		}
		time.Sleep(time.Second)
	}
	pw := make([]byte, 18)
	_, _ = rand.Read(pw)
	user, _ := json.Marshal(map[string]string{"client_id": clientID, "name": "Owner", "username": "owner", "password": hex.EncodeToString(pw), "language": "en"})
	code, b, err := p.do("POST", "/api/onboarding/users", "", bytes.NewReader(user), "application/json")
	if err != nil || code != 200 {
		return fmt.Errorf("onboarding user: %d %v %s", code, err, b)
	}
	var authCode struct {
		AuthCode string `json:"auth_code"`
	}
	if err := json.Unmarshal(b, &authCode); err != nil {
		return err
	}
	form := url.Values{"grant_type": {"authorization_code"}, "code": {authCode.AuthCode}, "client_id": {clientID}}
	code, b, err = p.do("POST", "/auth/token", "", strings.NewReader(form.Encode()), "application/x-www-form-urlencoded")
	if err != nil || code != 200 {
		return fmt.Errorf("token: %d %v", code, err)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(b, &tok); err != nil {
		return err
	}
	// The rest of the onboarding a first visit walks through, so / serves the app.
	for _, step := range []struct{ path, body string }{
		{"/api/onboarding/core_config", "{}"},
		{"/api/onboarding/analytics", "{}"},
		{"/api/onboarding/integration", `{"client_id":"` + clientID + `","redirect_uri":"` + clientID + `"}`},
	} {
		if code, b, err := p.do("POST", step.path, tok.AccessToken, strings.NewReader(step.body), "application/json"); err != nil || code != 200 {
			return fmt.Errorf("onboarding %s: %d %v %s", step.path, code, err, b)
		}
	}
	w, err := p.wsOpen()
	if err != nil {
		return err
	}
	defer func() { _ = w.c.Close() }()
	if t, err := w.auth(tok.AccessToken); err != nil || t != "auth_ok" {
		return fmt.Errorf("websocket auth: %s %v", t, err)
	}
	if err := w.send(map[string]any{"type": "auth/long_lived_access_token", "client_name": "probe", "lifespan": 30}); err != nil {
		return err
	}
	m, err := w.result()
	if err != nil {
		return err
	}
	llat, _ := m["result"].(string)
	return os.WriteFile(tokenFile, []byte(llat), 0o600) // #nosec G703 -- the test names it
}

var scriptRef = regexp.MustCompile(`(?:src|href)="(/frontend_latest/[^"]+\.js)"`)

// check judges what a visitor away from home gets: the UI, the REST API
// and the WebSocket with the owner's token, and refusals without it.
func (p *probe) check() (map[string]any, error) {
	res := map[string]any{}
	var failed []string
	ok := func(name string, pass bool, detail any) {
		res[name] = map[string]any{"pass": pass, "detail": detail}
		if !pass {
			failed = append(failed, name)
		}
	}

	code, body, err := p.do("GET", "/", "", nil, "")
	ok("ui", err == nil && code == 200 && bytes.Contains(body, []byte("home-assistant")), fmt.Sprintf("HTTP %d %v", code, err))

	code, body, err = p.do("GET", "/api/", p.token, nil, "")
	ok("rest_api", err == nil && code == 200 && bytes.Contains(body, []byte("API running")), fmt.Sprintf("HTTP %d %v", code, err))

	code, _, err = p.do("GET", "/api/states", "", nil, "")
	ok("rest_refused_without_token", err == nil && code == 401, fmt.Sprintf("HTTP %d %v", code, err))

	w, err := p.wsOpen()
	if err == nil {
		var t string
		t, err = w.auth("not-a-token")
		ok("websocket_refused_without_token", err == nil && t == "auth_invalid", fmt.Sprintf("%s %v", t, err))
		_ = w.c.Close()
	} else {
		ok("websocket_refused_without_token", false, err.Error())
	}

	ms, err := p.liveUpdate()
	ok("websocket_live_update", err == nil, map[string]any{"ms": ms, "err": fmt.Sprint(err)})

	if len(failed) > 0 {
		return res, fmt.Errorf("failed: %s", strings.Join(failed, ", "))
	}
	return res, nil
}

// liveUpdate is HA's live updates: subscribe to state_changed over the
// WebSocket, change a state through the REST API, and time until the
// change arrives on the WebSocket.
func (p *probe) liveUpdate() (float64, error) {
	w, err := p.wsOpen()
	if err != nil {
		return 0, err
	}
	defer func() { _ = w.c.Close() }()
	if t, err := w.auth(p.token); err != nil || t != "auth_ok" {
		return 0, fmt.Errorf("websocket auth: %s %v", t, err)
	}
	if err := w.send(map[string]any{"type": "subscribe_events", "event_type": "state_changed"}); err != nil {
		return 0, err
	}
	if _, err := w.result(); err != nil {
		return 0, err
	}
	val := strconv.FormatInt(time.Now().UnixNano(), 10)
	t0 := time.Now()
	st, _ := json.Marshal(map[string]string{"state": val})
	if code, b, err := p.do("POST", "/api/states/sensor.probe", p.token, bytes.NewReader(st), "application/json"); err != nil || (code != 200 && code != 201) {
		return 0, fmt.Errorf("set state: %d %v %s", code, err, b)
	}
	for {
		m, err := w.recv()
		if err != nil {
			return 0, err
		}
		if ev, _ := m["event"].(map[string]any); ev != nil {
			data, _ := ev["data"].(map[string]any)
			ns, _ := data["new_state"].(map[string]any)
			if data["entity_id"] == "sensor.probe" && ns["state"] == val {
				return float64(time.Since(t0).Microseconds()) / 1000, nil
			}
		}
	}
}

func pct(ms []float64, q float64) float64 {
	s := slices.Clone(ms)
	slices.Sort(s)
	return s[min(len(s)-1, int(q*float64(len(s))))]
}

func summary(ms []float64) map[string]any {
	return map[string]any{"n": len(ms), "p50_ms": pct(ms, 0.5), "p95_ms": pct(ms, 0.95), "max_ms": pct(ms, 1)}
}

// bench: n sequential REST calls over one kept-alive connection (after 10
// warm-up calls), n WebSocket command round trips (ping/pong on one
// socket), and the bytes a visitor reads to open the app cold (the page and
// the scripts it names) and to open the WebSocket session the UI starts
// with (auth, get_states, get_config, get_services).
func (p *probe) bench(n int) (map[string]any, error) {
	for range 10 {
		if _, _, err := p.do("GET", "/api/", p.token, nil, ""); err != nil {
			return nil, err
		}
	}
	var rest []float64
	for range n {
		t0 := time.Now()
		code, _, err := p.do("GET", "/api/", p.token, nil, "")
		if err != nil || code != 200 {
			return nil, fmt.Errorf("rest: %d %v", code, err)
		}
		rest = append(rest, float64(time.Since(t0).Microseconds())/1000)
	}

	w, err := p.wsOpen()
	if err != nil {
		return nil, err
	}
	defer func() { _ = w.c.Close() }()
	if t, err := w.auth(p.token); err != nil || t != "auth_ok" {
		return nil, fmt.Errorf("websocket auth: %s %v", t, err)
	}
	var wsMs []float64
	for range n {
		t0 := time.Now()
		if err := w.send(map[string]any{"type": "ping"}); err != nil {
			return nil, err
		}
		for {
			m, err := w.recv()
			if err != nil {
				return nil, err
			}
			if m["type"] == "pong" && m["id"] == float64(w.id) {
				break
			}
		}
		wsMs = append(wsMs, float64(time.Since(t0).Microseconds())/1000)
	}

	var live []float64
	for range 20 {
		ms, err := p.liveUpdate()
		if err != nil {
			return nil, err
		}
		live = append(live, ms)
	}

	p.hc.CloseIdleConnections()
	before := p.read.Load()
	code, page, err := p.do("GET", "/", "", nil, "")
	if err != nil || code != 200 {
		return nil, fmt.Errorf("page: %d %v", code, err)
	}
	scripts := 0
	for _, m := range scriptRef.FindAllSubmatch(page, -1) {
		if code, _, err := p.do("GET", string(m[1]), "", nil, ""); err != nil || code != 200 {
			return nil, fmt.Errorf("%s: %d %v", m[1], code, err)
		}
		scripts++
	}
	coldBytes := p.read.Load() - before

	before = p.read.Load()
	t0 := time.Now()
	w2, err := p.wsOpen()
	if err != nil {
		return nil, err
	}
	defer func() { _ = w2.c.Close() }()
	if t, err := w2.auth(p.token); err != nil || t != "auth_ok" {
		return nil, fmt.Errorf("websocket auth: %s %v", t, err)
	}
	for _, c := range []string{"get_states", "get_config", "get_services"} {
		if err := w2.send(map[string]any{"type": c}); err != nil {
			return nil, err
		}
		if _, err := w2.result(); err != nil {
			return nil, err
		}
	}
	return map[string]any{
		"rest":                 summary(rest),
		"websocket_round_trip": summary(wsMs),
		"live_update":          summary(live),
		"open_session_ms":      float64(time.Since(t0).Microseconds()) / 1000,
		"open_session_bytes":   p.read.Load() - before,
		"cold_load_bytes":      coldBytes,
		"cold_load_scripts":    scripts,
	}, nil
}

// wait: until the REST API answers with the token again (after a restart).
func (p *probe) wait(timeout time.Duration) (map[string]any, error) {
	t0 := time.Now()
	var last error
	for time.Since(t0) < timeout {
		p.hc.CloseIdleConnections()
		code, _, err := p.do("GET", "/api/", p.token, nil, "")
		if err == nil && code == 200 {
			return map[string]any{"ms": time.Since(t0).Milliseconds()}, nil
		}
		last = fmt.Errorf("HTTP %d %v", code, err)
		time.Sleep(100 * time.Millisecond)
	}
	return nil, fmt.Errorf("not answered within %s: %v", timeout, last)
}

// openPorts: which TCP ports of host accept a connection.
func openPorts(host, ports string) map[string]any {
	open := []int{}
	tried := []int{}
	for s := range strings.SplitSeq(ports, ",") {
		port, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil {
			continue
		}
		tried = append(tried, port)
		c, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 3*time.Second) // #nosec G704 -- the test names the host it scans
		if err == nil {
			_ = c.Close()
			open = append(open, port)
		}
	}
	return map[string]any{"host": host, "tried": tried, "open": open}
}
