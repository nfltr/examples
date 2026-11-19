// The laptop's DNS client (README.md): what a laptop's resolver asks
// Pi-hole, measured. DNS_SERVER (host:port) and DNS_NET (udp or tcp) name
// the path; the flags override them.
//
//	client once -name N -want A   one A query; exit 0 when an answer is A, 3 when the answers differ, 1 when none came
//	client wait -name N -want A   until once passes; prints the ms it took
//	client bench -n 100           JSON: cold (a new name each query) and cached (one name) percentiles, bytes
//
// Over tcp each query opens its own connection unless -reuse is set
// (RFC 7766: a client may keep one open, as stub resolvers do).
package main

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"slices"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// errWrong: an answer came, but not the one wanted.
var errWrong = errors.New("wrong answer")

type client struct {
	server, netw string
	reuse        bool
	conn         net.Conn // tcp with -reuse
	sent, got    int      // bytes of the last query and answer on the wire
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: client once|wait|bench [flags]")
		os.Exit(1)
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	server := fs.String("server", os.Getenv("DNS_SERVER"), "host:port")
	netw := fs.String("net", envOr("DNS_NET", "udp"), "udp or tcp")
	reuse := fs.Bool("reuse", false, "tcp: one connection for every query")
	name := fs.String("name", "www.example.com", "once, wait: the name to ask for")
	want := fs.String("want", "", "once, wait: the A record wanted (empty: any)")
	n := fs.Int("n", 100, "bench: queries of each kind")
	timeout := fs.Duration("timeout", 60*time.Second, "wait: give up after")
	_ = fs.Parse(os.Args[2:])
	c := &client{server: *server, netw: *netw, reuse: *reuse}
	check := func() error {
		a, err := c.query(*name)
		if err != nil {
			return err
		}
		if *want != "" && !slices.Contains(a, *want) {
			return fmt.Errorf("%w: %s is %v, want %s", errWrong, *name, a, *want)
		}
		return nil
	}
	switch os.Args[1] {
	case "once":
		if err := check(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			if errors.Is(err, errWrong) {
				os.Exit(3)
			}
			os.Exit(1)
		}
	case "wait":
		start := time.Now()
		for check() != nil {
			if time.Since(start) > *timeout {
				fmt.Fprintln(os.Stderr, "no answer within", *timeout)
				os.Exit(1)
			}
			time.Sleep(50 * time.Millisecond)
		}
		fmt.Println(time.Since(start).Milliseconds())
	case "bench":
		if err := c.bench(*n); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown command", os.Args[1])
		os.Exit(1)
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// query asks for name's A records and returns them.
func (c *client) query(name string) ([]string, error) {
	var idb [2]byte
	_, _ = rand.Read(idb[:])
	id := binary.BigEndian.Uint16(idb[:])
	q, err := (&dnsmessage.Message{
		Header:    dnsmessage.Header{ID: id, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name + "."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}},
	}).Pack()
	if err != nil {
		return nil, err
	}
	b, err := c.exchange(q)
	if err != nil {
		return nil, err
	}
	var m dnsmessage.Message
	if err := m.Unpack(b); err != nil {
		return nil, err
	}
	if m.ID != id {
		return nil, fmt.Errorf("answer for another query (id %d, want %d)", m.ID, id)
	}
	var out []string
	for _, r := range m.Answers {
		if a, ok := r.Body.(*dnsmessage.AResource); ok {
			out = append(out, netip.AddrFrom4(a.A).String())
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no A record for %s (%s)", name, m.RCode)
	}
	return out, nil
}

func (c *client) exchange(q []byte) ([]byte, error) {
	deadline := time.Now().Add(3 * time.Second)
	if c.netw == "udp" {
		conn, err := net.Dial("udp", c.server)
		if err != nil {
			return nil, err
		}
		defer conn.Close()
		_ = conn.SetDeadline(deadline)
		if _, err := conn.Write(q); err != nil {
			return nil, err
		}
		b := make([]byte, 1232)
		n, err := conn.Read(b)
		c.sent, c.got = len(q), n
		return b[:n], err
	}
	conn := c.conn
	if conn == nil {
		var err error
		if conn, err = net.DialTimeout("tcp", c.server, 3*time.Second); err != nil {
			return nil, err
		}
		if c.reuse {
			c.conn = conn
		} else {
			defer conn.Close()
		}
	}
	_ = conn.SetDeadline(deadline)
	if _, err := conn.Write(append(binary.BigEndian.AppendUint16(nil, uint16(len(q))), q...)); err != nil { // #nosec G115 -- a packed query is far below 64 KiB
		return nil, err
	}
	var l [2]byte
	if _, err := io.ReadFull(conn, l[:]); err != nil {
		return nil, err
	}
	b := make([]byte, binary.BigEndian.Uint16(l[:]))
	_, err := io.ReadFull(conn, b)
	c.sent, c.got = 2+len(q), 2+len(b)
	return b, err
}

type stats struct {
	N        int     `json:"n"`
	P50      float64 `json:"p50"`
	P95      float64 `json:"p95"`
	Max      float64 `json:"max"`
	Failures int     `json:"failures"`
}

func summarize(ms []float64, failures int) stats {
	slices.Sort(ms)
	if len(ms) == 0 {
		return stats{Failures: failures}
	}
	at := func(p float64) float64 { return ms[min(len(ms)-1, int(p*float64(len(ms))))] }
	return stats{N: len(ms), P50: at(0.5), P95: at(0.95), Max: ms[len(ms)-1], Failures: failures}
}

// bench: n cold queries (a name nobody asked for, so Pi-hole asks its
// upstream), then one unmeasured query and n cached ones (Pi-hole answers
// from its cache).
func (c *client) bench(n int) error {
	var run [4]byte
	_, _ = rand.Read(run[:])
	measure := func(name func(int) string) ([]float64, int) {
		var ms []float64
		failures := 0
		for i := range n {
			start := time.Now()
			if _, err := c.query(name(i)); err != nil {
				failures++
				continue
			}
			ms = append(ms, float64(time.Since(start).Microseconds())/1000)
		}
		return ms, failures
	}
	cold, coldFail := measure(func(i int) string { return fmt.Sprintf("c%s-%d.example.com", hex.EncodeToString(run[:]), i) })
	if _, err := c.query("www.example.com"); err != nil {
		return err
	}
	cached, cachedFail := measure(func(int) string { return "www.example.com" })
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"server": c.server, "net": c.netw, "reuse": c.reuse,
		"cold_ms": summarize(cold, coldFail), "cached_ms": summarize(cached, cachedFail),
		"query_bytes": c.sent, "answer_bytes": c.got,
	})
}
