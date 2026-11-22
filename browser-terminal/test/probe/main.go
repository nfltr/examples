// probe is the browser-terminal example's browser on machine B (README.md,
// scripts/test-browser-terminal.sh): what a browser asks of ttyd through
// B's nfltr cat forward. Exits 1 when a check fails.
//
//	probe http -url URL [-user U -pass P] -want CODE   the page's HTTP status is CODE
//	probe type -url URL -user U -pass P -marker M      the terminal (ttyd's websocket)
//	                                                   runs `echo M | tr a-z A-Z` and
//	                                                   shows the upper-cased M
package main

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/net/websocket"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: probe http|type [flags]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	u := fs.String("url", "http://127.0.0.1:7681", "ttyd's address on B")
	user := fs.String("user", "", "ttyd's user (-c)")
	pass := fs.String("pass", "", "ttyd's password (-c)")
	want := fs.Int("want", 200, "http: the wanted status")
	marker := fs.String("marker", "", "type: the text typed")
	_ = fs.Parse(os.Args[2:])
	var err error
	switch os.Args[1] {
	case "http":
		err = status(*u, *user, *pass, *want)
	case "type":
		err = typeLine(*u, *user, *pass, *marker)
	default:
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "probe:", err)
		os.Exit(1)
	}
}

var client = &http.Client{Timeout: 20 * time.Second}

func get(u, user, pass string) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	if user != "" {
		req.SetBasicAuth(user, pass)
	}
	return client.Do(req)
}

func status(u, user, pass string, want int) error {
	resp, err := get(u, user, pass)
	if err != nil {
		return err
	}
	resp.Body.Close()
	fmt.Println(resp.StatusCode)
	if resp.StatusCode != want {
		return fmt.Errorf("status %d, want %d", resp.StatusCode, want)
	}
	return nil
}

// typeLine does what ttyd's page does: its token (/token), the websocket
// (/ws, subprotocol tty) opened with the token, then keystrokes ('0' and
// the bytes) and the terminal's output ('0' and the bytes) until the
// upper-cased marker shows.
func typeLine(u, user, pass, marker string) error {
	resp, err := get(u+"/token", user, pass)
	if err != nil {
		return err
	}
	var tok struct{ Token string }
	err = json.NewDecoder(resp.Body).Decode(&tok)
	resp.Body.Close()
	if err != nil {
		return fmt.Errorf("token: %w", err)
	}
	cfg, err := websocket.NewConfig(strings.Replace(u, "http", "ws", 1)+"/ws", u)
	if err != nil {
		return err
	}
	cfg.Protocol = []string{"tty"}
	cfg.Header = http.Header{"Authorization": {"Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+pass))}}
	ws, err := websocket.DialConfig(cfg)
	if err != nil {
		return fmt.Errorf("websocket: %w", err)
	}
	defer ws.Close()
	_ = ws.SetDeadline(time.Now().Add(30 * time.Second))
	hello, _ := json.Marshal(map[string]any{"AuthToken": tok.Token, "columns": 100, "rows": 30})
	if err := websocket.Message.Send(ws, hello); err != nil {
		return err
	}
	if err := websocket.Message.Send(ws, []byte("0echo "+marker+" | tr a-z A-Z\r")); err != nil {
		return err
	}
	want := strings.ToUpper(marker)
	var seen strings.Builder
	for {
		var msg []byte
		if err := websocket.Message.Receive(ws, &msg); err != nil {
			if err == io.EOF {
				err = fmt.Errorf("the terminal closed")
			}
			return fmt.Errorf("%w (output so far %q)", err, seen.String())
		}
		if len(msg) > 0 && msg[0] == '0' {
			seen.Write(msg[1:])
			// the typed line echoes the lower-case marker; its output is the upper-cased one
			if strings.Contains(seen.String(), "\n"+want) {
				fmt.Println(want)
				return nil
			}
		}
	}
}
