// svc stands in for the services behind the reverse proxy (README.md,
// scripts/test-reverse-proxy.sh): each listener answers every
// request with what it saw (its name, the request's host and path, the
// connection's peer and the proxy headers) as JSON, and /ws upgrades to a
// WebSocket that sends the same JSON first, then echoes every text frame.
//
//	svc 127.0.0.1:9001=photos 127.0.0.1:9002=api ...
package main

import (
	"bufio"
	"crypto/sha1" // #nosec G505 -- the WebSocket handshake (RFC 6455 4.2.2) is defined with SHA-1
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// seen is what a service tells the visitor about the request it got.
type seen struct {
	Service    string            `json:"service"`
	Host       string            `json:"host"`
	Path       string            `json:"path"`
	RemoteAddr string            `json:"remote_addr"`
	Headers    map[string]string `json:"headers"`
}

var proxyHeaders = []string{"X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Real-Ip", "Forwarded", "Via", "X-Auth-User", "Authorization"}

func view(name string, r *http.Request) seen {
	s := seen{Service: name, Host: r.Host, Path: r.URL.Path, RemoteAddr: r.RemoteAddr, Headers: map[string]string{}}
	for _, h := range proxyHeaders {
		if v := r.Header.Values(h); len(v) > 0 {
			s.Headers[h] = strings.Join(v, ", ")
		}
	}
	if _, ok := s.Headers["Authorization"]; ok {
		s.Headers["Authorization"] = "(present)" // never echo a credential
	}
	return s
}

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: svc addr=name ...")
	}
	errc := make(chan error)
	for _, a := range os.Args[1:] {
		addr, name, ok := strings.Cut(a, "=")
		if !ok {
			log.Fatalf("want addr=name, got %q", a) // #nosec G706 -- the operator's own argument, quoted
		}
		mux := http.NewServeMux()
		mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) { websocket(w, r, view(name, r)) })
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(view(name, r))
		})
		srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
		go func() { errc <- srv.ListenAndServe() }()
	}
	log.Fatal(<-errc)
}

// websocket answers the upgrade, sends v, then echoes text frames until the
// client closes.
func websocket(w http.ResponseWriter, r *http.Request, v seen) {
	key := r.Header.Get("Sec-WebSocket-Key")
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") || key == "" {
		http.Error(w, "want a WebSocket upgrade", http.StatusBadRequest)
		return
	}
	c, rw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		return
	}
	defer func() { _ = c.Close() }()
	// nosemgrep: use-of-sha1 -- the WebSocket handshake (RFC 6455 4.2.2) is defined with SHA-1
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")) // #nosec G401 -- RFC 6455
	_, _ = fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		base64.StdEncoding.EncodeToString(sum[:]))
	first, _ := json.Marshal(v)
	if writeFrame(rw.Writer, first) != nil {
		return
	}
	for {
		msg, err := readFrame(rw.Reader)
		if err != nil || writeFrame(rw.Writer, msg) != nil {
			return
		}
	}
}

func writeFrame(w *bufio.Writer, p []byte) error {
	hdr := []byte{0x81}
	switch n := len(p); {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n < 1<<16:
		hdr = binary.BigEndian.AppendUint16(append(hdr, 126), uint16(n)) // #nosec G115 -- n < 1<<16
	default:
		hdr = binary.BigEndian.AppendUint64(append(hdr, 127), uint64(n))
	}
	_, _ = w.Write(hdr)
	_, _ = w.Write(p)
	return w.Flush()
}

// readFrame returns the next text frame's payload (client frames are
// masked; this stand-in takes unfragmented frames only).
func readFrame(r *bufio.Reader) ([]byte, error) {
	for {
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
			b := make([]byte, 8)
			if _, err := io.ReadFull(r, b); err != nil {
				return nil, err
			}
			n = binary.BigEndian.Uint64(b)
		}
		if n > 1<<20 {
			return nil, errors.New("frame too large")
		}
		var mask []byte
		if h[1]&0x80 != 0 {
			mask = make([]byte, 4)
			if _, err := io.ReadFull(r, mask); err != nil {
				return nil, err
			}
		}
		p := make([]byte, n)
		if _, err := io.ReadFull(r, p); err != nil {
			return nil, err
		}
		for i := range p {
			if mask != nil {
				p[i] ^= mask[i%4]
			}
		}
		switch h[0] & 0x0f {
		case 0x8:
			return nil, io.EOF
		case 0x1:
			return p, nil
		}
	}
}
