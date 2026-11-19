// The laptop's client (README.md): what any OpenAI-compatible tool does
// against the box, measured. It reads OPENAI_BASE_URL.
//
//	client wait -timeout 60s until one completion is answered; prints the ms it took
//	client bench -n 100      JSON: completion and time-to-first-token percentiles, bytes
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"
)

const tokens = 16

type client struct {
	base string
	hc   *http.Client
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: client wait|bench [flags]")
		os.Exit(1)
	}
	c := &client{base: strings.TrimSuffix(os.Getenv("OPENAI_BASE_URL"), "/"), hc: &http.Client{Timeout: 10 * time.Second}}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	n := fs.Int("n", 100, "bench: completions of each kind")
	timeout := fs.Duration("timeout", 60*time.Second, "wait: give up after")
	_ = fs.Parse(os.Args[2:])
	switch os.Args[1] {
	case "wait":
		start := time.Now()
		for {
			if _, _, err := c.complete(); err == nil {
				fmt.Println(time.Since(start).Milliseconds())
				return
			}
			if time.Since(start) > *timeout {
				fmt.Fprintln(os.Stderr, "no answer within", *timeout)
				os.Exit(1)
			}
			time.Sleep(50 * time.Millisecond)
		}
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

func want() string {
	var sb strings.Builder
	for i := range tokens {
		fmt.Fprintf(&sb, "w%d ", i)
	}
	return sb.String()
}

func (c *client) requestBody(stream bool) ([]byte, int, error) {
	body, err := json.Marshal(map[string]any{
		"model": "stand-in", "stream": stream, "max_tokens": tokens,
		"messages": []any{map[string]string{"role": "user", "content": "Say sixteen words."}},
	})
	return body, len(body), err
}

func (c *client) post(stream bool) (*http.Response, int, error) {
	body, _, _ := c.requestBody(stream)
	req, _ := http.NewRequest(http.MethodPost, c.base+"/chat/completions", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, 0, err
	}
	if resp.StatusCode != http.StatusOK {
		_ = resp.Body.Close()
		return nil, 0, fmt.Errorf("status %s", resp.Status)
	}
	return resp, len(body), nil
}

// complete: one answer without streaming; its latency and the bytes both ways.
func (c *client) complete() (time.Duration, int, error) {
	t0 := time.Now()
	resp, reqBytes, err := c.post(false)
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, 0, err
	}
	var out struct {
		Choices []struct {
			Message struct{ Content string } `json:"message"`
		} `json:"choices"`
	}
	if json.Unmarshal(b, &out) != nil || len(out.Choices) != 1 || out.Choices[0].Message.Content != want() {
		return 0, 0, errors.New("wrong answer")
	}
	return time.Since(t0), reqBytes + len(b), nil
}

// stream: one streamed answer; time to its first token, to its end, and the bytes both ways.
func (c *client) stream() (ttft, total time.Duration, nbytes int, err error) {
	t0 := time.Now()
	resp, reqBytes, err := c.post(true)
	if err != nil {
		return 0, 0, 0, err
	}
	defer resp.Body.Close()
	var got strings.Builder
	cr := &countReader{r: resp.Body}
	sc := bufio.NewScanner(cr)
	done := false
	for sc.Scan() {
		line, ok := strings.CutPrefix(sc.Text(), "data: ")
		if !ok {
			continue
		}
		if line == "[DONE]" {
			done = true
			break
		}
		var ch struct {
			Choices []struct {
				Delta struct{ Content string } `json:"delta"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(line), &ch) != nil || len(ch.Choices) != 1 {
			return 0, 0, 0, errors.New("bad chunk")
		}
		if got.Len() == 0 {
			ttft = time.Since(t0)
		}
		got.WriteString(ch.Choices[0].Delta.Content)
	}
	if !done || got.String() != want() {
		return 0, 0, 0, errors.New("wrong or cut stream")
	}
	return ttft, time.Since(t0), reqBytes + cr.n, nil
}

type countReader struct {
	r io.Reader
	n int
}

func (c *countReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += n
	return n, err
}

func (c *client) bench(n int) error {
	// One unmeasured call first: it opens the connection.
	if _, _, err := c.complete(); err != nil {
		return err
	}
	var lat, ttft, total []float64
	var cBytes, sBytes, reqBytes int
	for range n {
		d, b, err := c.complete()
		if err != nil {
			return err
		}
		lat, cBytes = append(lat, ms(d)), b
		f, t, sb, err := c.stream()
		if err != nil {
			return err
		}
		ttft, total, sBytes = append(ttft, ms(f)), append(total, ms(t)), sb
		_, reqBytes, _ = c.requestBody(true)
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"n": n, "tokens": tokens,
		"completion_ms": pct(lat), "ttft_ms": pct(ttft), "stream_ms": pct(total),
		"completion_bytes": cBytes, "stream_bytes": sBytes, "stream_request_bytes": reqBytes,
	})
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func pct(v []float64) map[string]float64 {
	slices.Sort(v)
	at := func(p float64) float64 { return v[int(p*float64(len(v)-1))] }
	return map[string]float64{"p50": at(0.5), "p95": at(0.95), "max": v[len(v)-1]}
}
