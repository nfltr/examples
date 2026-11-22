// probe is the remote-desktop example's VNC viewer on machine B (README.md,
// scripts/test-remote-desktop.sh): the RFB handshake (RFC 6143) a viewer
// makes through B's nfltr cat forward, with VNC authentication (section
// 7.2.2), then the desktop's size and name from ServerInit and one full
// framebuffer update (raw encoding). Prints one JSON line; exits 1 when the
// server refuses the password or the handshake fails.
//
//	probe -addr 127.0.0.1:15900 -pass P
package main

import (
	"crypto/des"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/bits"
	"net"
	"os"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:15900", "the VNC server's address on B")
	pass := flag.String("pass", "", "the VNC password")
	flag.Parse()
	out, err := view(*addr, *pass)
	if err != nil {
		fmt.Fprintln(os.Stderr, "probe:", err)
		os.Exit(1)
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
}

type desktop struct {
	Width, Height int
	Name          string
	FrameBytes    int `json:"frame_bytes"`
}

func view(addr, pass string) (desktop, error) {
	var d desktop
	c, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		return d, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(30 * time.Second))
	ver := make([]byte, 12)
	if _, err := io.ReadFull(c, ver); err != nil {
		return d, fmt.Errorf("protocol version: %w", err)
	}
	if _, err := c.Write([]byte("RFB 003.008\n")); err != nil {
		return d, err
	}
	var n [1]byte
	if _, err := io.ReadFull(c, n[:]); err != nil || n[0] == 0 {
		return d, fmt.Errorf("security types: %v", err)
	}
	types := make([]byte, n[0])
	if _, err := io.ReadFull(c, types); err != nil {
		return d, err
	}
	if !contains(types, 2) {
		return d, fmt.Errorf("no VNC authentication offered (%v)", types)
	}
	if _, err := c.Write([]byte{2}); err != nil {
		return d, err
	}
	challenge := make([]byte, 16)
	if _, err := io.ReadFull(c, challenge); err != nil {
		return d, err
	}
	// The key is the password's first 8 bytes, each byte's bits reversed.
	key := make([]byte, 8)
	copy(key, pass)
	for i := range key {
		key[i] = bits.Reverse8(key[i])
	}
	block, err := des.NewCipher(key)
	if err != nil {
		return d, err
	}
	resp := make([]byte, 16)
	block.Encrypt(resp[:8], challenge[:8])
	block.Encrypt(resp[8:], challenge[8:])
	if _, err := c.Write(resp); err != nil {
		return d, err
	}
	var result uint32
	if err := binary.Read(c, binary.BigEndian, &result); err != nil {
		return d, err
	}
	if result != 0 {
		return d, errors.New("the server refused the password")
	}
	if _, err := c.Write([]byte{1}); err != nil { // ClientInit: shared
		return d, err
	}
	var init struct {
		W, H   uint16
		Format [16]byte
		NameN  uint32
	}
	if err := binary.Read(c, binary.BigEndian, &init); err != nil {
		return d, err
	}
	name := make([]byte, init.NameN)
	if _, err := io.ReadFull(c, name); err != nil {
		return d, err
	}
	d.Width, d.Height, d.Name = int(init.W), int(init.H), string(name)
	bpp := int(init.Format[0]) / 8
	// SetEncodings (raw only), then FramebufferUpdateRequest for the whole screen.
	req := []byte{2, 0, 0, 1, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	binary.BigEndian.PutUint16(req[14:], init.W)
	binary.BigEndian.PutUint16(req[16:], init.H)
	if _, err := c.Write(req); err != nil {
		return d, err
	}
	var hdr [4]byte
	if _, err := io.ReadFull(c, hdr[:]); err != nil || hdr[0] != 0 {
		return d, fmt.Errorf("framebuffer update: %v (type %d)", err, hdr[0])
	}
	for range binary.BigEndian.Uint16(hdr[2:]) {
		var r struct {
			X, Y, W, H uint16
			Enc        int32
		}
		if err := binary.Read(c, binary.BigEndian, &r); err != nil {
			return d, err
		}
		if r.Enc != 0 {
			return d, fmt.Errorf("encoding %d, asked for raw", r.Enc)
		}
		px, err := io.CopyN(io.Discard, c, int64(r.W)*int64(r.H)*int64(bpp))
		d.FrameBytes += int(px)
		if err != nil {
			return d, err
		}
	}
	return d, nil
}

func contains(b []byte, v byte) bool {
	for _, x := range b {
		if x == v {
			return true
		}
	}
	return false
}
