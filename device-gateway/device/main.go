// device is the device-gateway example's stand-in for a small device on a
// LAN (README.md): what a microcontroller typically serves, with no nfltr
// on it.
//
//	device serve        HTTP on :80 ({"device":"esp32-demo","temp_c":21.5}),
//	                    a raw TCP socket on :7 (echoes each line), a UDP
//	                    socket on :5683 (echoes each datagram) and a
//	                    maintenance port on :23 that the gateway does not
//	                    publish (writes "maintenance" and closes)
//	device udp ADDR MSG one datagram to ADDR; exit 0 when MSG comes back
//	                    within 5 s (the test's UDP client)
package main

import (
	"bytes"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"time"
)

func tcp(addr string, handle func(net.Conn)) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go func() { defer c.Close(); handle(c) }()
	}
}

func serve() {
	go tcp(":7", func(c net.Conn) { _, _ = io.Copy(c, c) })
	go tcp(":23", func(c net.Conn) { _, _ = io.WriteString(c, "maintenance\n") })
	go func() {
		pc, err := net.ListenPacket("udp", ":5683")
		if err != nil {
			log.Fatal(err)
		}
		buf := make([]byte, 1500)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				log.Fatal(err)
			}
			_, _ = pc.WriteTo(buf[:n], from)
		}
	}()
	srv := &http.Server{Addr: ":80", ReadHeaderTimeout: 10 * time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"device":"esp32-demo","temp_c":21.5}`+"\n")
		})}
	log.Fatal(srv.ListenAndServe())
}

func udp(addr, msg string) error {
	c, err := net.Dial("udp", addr)
	if err != nil {
		return err
	}
	defer c.Close()
	buf := make([]byte, 1500)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) { // a datagram may be lost: resend each second
		if _, err := io.WriteString(c, msg); err != nil {
			return err
		}
		_ = c.SetReadDeadline(time.Now().Add(time.Second))
		if n, err := c.Read(buf); err == nil && bytes.Equal(buf[:n], []byte(msg)) {
			return nil
		}
	}
	return os.ErrDeadlineExceeded
}

func main() {
	switch {
	case len(os.Args) == 2 && os.Args[1] == "serve":
		serve()
	case len(os.Args) == 4 && os.Args[1] == "udp":
		if err := udp(os.Args[2], os.Args[3]); err != nil {
			log.Fatal(err)
		}
	default:
		log.Fatal("usage: device serve | device udp ADDR MSG")
	}
}
