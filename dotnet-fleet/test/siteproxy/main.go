// Command siteproxy is a customer site's outbound HTTP proxy in the
// end-to-end test (scripts/test-dotnet-fleet-example.sh): the only way out
// of edge-2's network. It answers CONNECT to the addresses -allow lists
// (the site's firewall ask) with 200 and splices the bytes; every other
// request gets 403. One JSON line per request on stdout:
// {"method":"CONNECT","target":"relay:8443","allowed":true}.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"slices"
	"strings"
	"sync"
	"time"
)

func main() {
	listen := flag.String("listen", ":3128", "address to listen on")
	allow := flag.String("allow", "", "comma-separated host:port targets CONNECT may reach")
	flag.Parse()
	allowed := strings.Split(*allow, ",")
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	var mu sync.Mutex
	enc := json.NewEncoder(os.Stdout)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go func() {
			defer func() { _ = c.Close() }()
			_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
			req, err := http.ReadRequest(bufio.NewReader(c))
			if err != nil {
				return
			}
			_ = c.SetReadDeadline(time.Time{})
			ok := req.Method == http.MethodConnect && slices.Contains(allowed, req.Host)
			mu.Lock()
			_ = enc.Encode(map[string]any{"method": req.Method, "target": req.Host, "allowed": ok})
			mu.Unlock()
			if !ok {
				_, _ = io.WriteString(c, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
				return
			}
			up, err := net.DialTimeout("tcp", req.Host, 10*time.Second)
			if err != nil {
				_, _ = io.WriteString(c, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
				return
			}
			defer func() { _ = up.Close() }()
			_, _ = io.WriteString(c, "HTTP/1.1 200 Connection established\r\n\r\n")
			go func() { _, _ = io.Copy(up, c); _ = up.(*net.TCPConn).CloseWrite() }()
			_, _ = io.Copy(c, up)
		}()
	}
}
