// probe is the reverse-proxy example's visitor (README.md,
// scripts/test-reverse-proxy.sh): a browser or app on the
// internet. Every subcommand prints one JSON object (wait: a number) and
// exits 1 when an expectation fails.
//
//	probe get   -url URL [-want-status N] [-want-service S] [-want-header K=V] [-auth FILE] [-header K=V]
//	probe ws    -url URL [-n N]           WebSocket: the service's view, then N echoes
//	probe bench -url URL [-n N]           kept-alive GETs
//	probe wait  -url URL [-timeout D]     ms until the URL answers 200
//	probe ports -host IP -ports 80,443,...
//
// Common flags: -addr host:port (where the TCP connection goes: the test's
// stand-in for DNS), -ca FILE (the certificate roots the visitor trusts:
// the test's stand-in for the public CAs).
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

type probe struct {
	u    *url.URL
	addr string
	tls  *tls.Config
	user string // user:password for Basic auth, or ""
	send []string
	hc   *http.Client
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: probe get|ws|bench|wait|ports [flags]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	rawURL := fs.String("url", "", "the URL as the visitor uses it")
	addr := fs.String("addr", "", "host:port to connect to (default: the URL's)")
	ca := fs.String("ca", "", "PEM file of the certificate roots to trust")
	auth := fs.String("auth", "", "file holding user:password for Basic auth")
	wantStatus := fs.Int("want-status", 200, "get: the status to expect")
	wantService := fs.String("want-service", "", "get, ws: the service that must answer")
	var wantHeaders, sendHeaders multi
	fs.Var(&sendHeaders, "header", "get: K=V to send (repeatable), e.g. a forged X-Forwarded-For")
	fs.Var(&wantHeaders, "want-header", "get, ws: K=V the service must see (repeatable; V empty: absent)")
	n := fs.Int("n", 100, "ws: echoes; bench: requests")
	timeout := fs.Duration("timeout", 2*time.Minute, "wait: give up after")
	host := fs.String("host", "", "ports: the address to try")
	ports := fs.String("ports", "", "ports: comma-separated")
	_ = fs.Parse(os.Args[2:])

	if os.Args[1] == "ports" {
		out(openPorts(*host, *ports), nil)
		return
	}
	p, err := newProbe(*rawURL, *addr, *ca, *auth)
	die(err)
	p.send = sendHeaders
	switch os.Args[1] {
	case "get":
		out(p.get(*wantStatus, *wantService, wantHeaders))
	case "ws":
		out(p.ws(*n, *wantService, wantHeaders))
	case "bench":
		out(p.bench(*n))
	case "wait":
		ms, err := p.wait(*timeout)
		die(err)
		fmt.Println(ms)
	default:
		die(fmt.Errorf("unknown subcommand %q", os.Args[1]))
	}
}

type multi []string

func (m *multi) String() string     { return strings.Join(*m, ",") }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }

func out(v any, err error) {
	if v != nil {
		b, _ := json.Marshal(v)
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

func newProbe(rawURL, addr, ca, auth string) (*probe, error) {
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("-url %q: want an absolute URL", rawURL)
	}
	p := &probe{u: u, addr: addr}
	if p.addr == "" {
		port := u.Port()
		if port == "" {
			port = map[string]string{"https": "443", "wss": "443", "http": "80", "ws": "80"}[u.Scheme]
		}
		p.addr = net.JoinHostPort(u.Hostname(), port)
	}
	p.tls = &tls.Config{ServerName: u.Hostname(), MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"}}
	if ca != "" {
		pem, err := os.ReadFile(ca) // #nosec G304 G703 -- the test names it
		if err != nil {
			return nil, err
		}
		p.tls.RootCAs = x509.NewCertPool()
		if !p.tls.RootCAs.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("%s: no certificate", ca)
		}
	}
	if auth != "" {
		b, err := os.ReadFile(auth) // #nosec G304 G703 -- the test names it
		if err != nil {
			return nil, err
		}
		p.user = strings.TrimSpace(string(b))
	}
	p.hc = &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{
		DialContext:     func(ctx context.Context, network, _ string) (net.Conn, error) { return p.dial(ctx) },
		DialTLSContext:  func(ctx context.Context, network, _ string) (net.Conn, error) { return p.dialTLS(ctx) },
		MaxIdleConns:    1,
		IdleConnTimeout: time.Minute,
	}}
	return p, nil
}

func (p *probe) dial(ctx context.Context) (net.Conn, error) {
	return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", p.addr)
}

func (p *probe) dialTLS(ctx context.Context) (net.Conn, error) {
	raw, err := p.dial(ctx)
	if err != nil {
		return nil, err
	}
	c := tls.Client(raw, p.tls)
	if err := c.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	return c, nil
}

// seen is what the service reported (svc/main.go).
type seen struct {
	Service    string            `json:"service"`
	Host       string            `json:"host"`
	Path       string            `json:"path"`
	RemoteAddr string            `json:"remote_addr"`
	Headers    map[string]string `json:"headers"`
}

func (s *seen) expect(service string, headers []string) error {
	if service != "" && s.Service != service {
		return fmt.Errorf("answered by %q, want %q", s.Service, service)
	}
	for _, kv := range headers {
		k, v, _ := strings.Cut(kv, "=")
		if got := s.Headers[http.CanonicalHeaderKey(k)]; got != v {
			return fmt.Errorf("the service saw %s %q, want %q", k, got, v)
		}
	}
	return nil
}

func (p *probe) request() (*http.Response, float64, error) {
	req, err := http.NewRequest(http.MethodGet, p.u.String(), nil) // #nosec G704 -- the test names the URL
	if err != nil {
		return nil, 0, err
	}
	if p.user != "" {
		user, pass, _ := strings.Cut(p.user, ":")
		req.SetBasicAuth(user, pass)
	}
	for _, kv := range p.send {
		k, v, _ := strings.Cut(kv, "=")
		req.Header.Set(k, v)
	}
	t0 := time.Now()
	resp, err := p.hc.Do(req) // #nosec G704 -- the test names the URL
	return resp, float64(time.Since(t0).Microseconds()) / 1000, err
}

func (p *probe) get(status int, service string, headers []string) (map[string]any, error) {
	resp, ms, err := p.request()
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	o := map[string]any{"status": resp.StatusCode, "ms": ms}
	if resp.StatusCode != status {
		return o, fmt.Errorf("HTTP %d, want %d", resp.StatusCode, status)
	}
	if status != http.StatusOK {
		return o, nil
	}
	var s seen
	if err := json.Unmarshal(body, &s); err != nil {
		return o, fmt.Errorf("not the service's answer: %v", err)
	}
	o["seen"] = s
	return o, s.expect(service, headers)
}

func pct(ms []float64, q float64) float64 {
	s := slices.Clone(ms)
	slices.Sort(s)
	return s[min(len(s)-1, int(q*float64(len(s))))]
}

func summary(ms []float64) map[string]any {
	return map[string]any{"n": len(ms), "p50_ms": pct(ms, 0.5), "p95_ms": pct(ms, 0.95), "max_ms": pct(ms, 1)}
}

func (p *probe) bench(n int) (map[string]any, error) {
	var ms []float64
	for i := 0; i <= n; i++ { // the first opens the connection, not measured
		resp, d, err := p.request()
		if err != nil {
			return nil, err
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		if i > 0 {
			ms = append(ms, d)
		}
	}
	return summary(ms), nil
}

func (p *probe) wait(timeout time.Duration) (int64, error) {
	t0 := time.Now()
	for time.Since(t0) < timeout {
		p.hc.CloseIdleConnections()
		if resp, _, err := p.request(); err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return time.Since(t0).Milliseconds(), nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return 0, fmt.Errorf("no answer within %s", timeout)
}

// ---- WebSocket: one session, the service's view first, then echoes ----

func (p *probe) ws(n int, service string, headers []string) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	t0 := time.Now()
	var c net.Conn
	var err error
	if p.u.Scheme == "wss" || p.u.Scheme == "https" {
		c, err = p.dialTLS(ctx)
	} else {
		c, err = p.dial(ctx)
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = c.Close() }()
	_ = c.SetDeadline(time.Now().Add(time.Minute))
	key := make([]byte, 16)
	_, _ = rand.Read(key)
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n",
		p.u.RequestURI(), p.u.Host, base64.StdEncoding.EncodeToString(key))
	if p.user != "" {
		req += "Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte(p.user)) + "\r\n"
	}
	_, _ = io.WriteString(c, req+"\r\n")
	r := bufio.NewReader(c)
	resp, err := http.ReadResponse(r, nil)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		return map[string]any{"status": resp.StatusCode}, fmt.Errorf("upgrade answered HTTP %d", resp.StatusCode)
	}
	first, err := readText(r)
	if err != nil {
		return nil, err
	}
	o := map[string]any{"status": resp.StatusCode, "upgrade_ms": float64(time.Since(t0).Microseconds()) / 1000}
	var s seen
	if err := json.Unmarshal(first, &s); err != nil {
		return o, fmt.Errorf("first message: %v", err)
	}
	o["seen"] = s
	if err := s.expect(service, headers); err != nil {
		return o, err
	}
	var ms []float64
	for i := range n {
		msg := []byte("echo " + strconv.Itoa(i))
		t := time.Now()
		if err := writeMasked(c, msg); err != nil {
			return o, err
		}
		got, err := readText(r)
		if err != nil {
			return o, err
		}
		if string(got) != string(msg) {
			return o, fmt.Errorf("echo %q, want %q", got, msg)
		}
		ms = append(ms, float64(time.Since(t).Microseconds())/1000)
	}
	if n > 0 {
		o["echo"] = summary(ms)
	}
	return o, nil
}

func writeMasked(w io.Writer, p []byte) error {
	if len(p) >= 126 {
		return errors.New("probe sends short frames only")
	}
	mask := make([]byte, 4)
	_, _ = rand.Read(mask)
	f := append([]byte{0x81, 0x80 | byte(len(p))}, mask...) // #nosec G115 -- len(p) < 126
	for i, b := range p {
		f = append(f, b^mask[i%4])
	}
	_, err := w.Write(f)
	return err
}

func readText(r *bufio.Reader) ([]byte, error) {
	h := make([]byte, 2)
	if _, err := io.ReadFull(r, h); err != nil {
		return nil, err
	}
	n := uint64(h[1] & 0x7f)
	switch n {
	case 126:
		b := make([]byte, 2)
		if _, err := io.ReadFull(r, b); err != nil {
			return nil, err
		}
		n = uint64(binary.BigEndian.Uint16(b))
	case 127:
		return nil, errors.New("frame too large")
	}
	p := make([]byte, n)
	if _, err := io.ReadFull(r, p); err != nil {
		return nil, err
	}
	if h[0]&0x0f != 0x1 {
		return nil, fmt.Errorf("frame opcode %d", h[0]&0x0f)
	}
	return p, nil
}

func openPorts(host, ports string) map[string]any {
	open := []int{}
	for _, s := range strings.Split(ports, ",") {
		port, err := strconv.Atoi(s)
		if err != nil {
			continue
		}
		if c, err := net.DialTimeout("tcp", net.JoinHostPort(host, s), 3*time.Second); err == nil { // #nosec G704 -- the test names the address
			_ = c.Close()
			open = append(open, port)
		}
	}
	return map[string]any{"host": host, "open": open}
}
