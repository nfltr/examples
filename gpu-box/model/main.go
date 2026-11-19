// The stand-in model server (README.md): the part of the OpenAI API that
// Ollama and vLLM serve (GET /v1/models, POST /v1/chat/completions with and
// without "stream"), without a model. Token i of every answer is "w<i> ",
// one every -token-ms, so a client can check what it received and when.
// On the box, a real `ollama serve` (127.0.0.1:11434) takes its place.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:11434", "address (Ollama's default)")
	tokenMS := flag.Int("token-ms", 10, "time per generated token")
	flag.Parse()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"object": "list", "data": []any{map[string]any{"id": "stand-in", "object": "model"}}})
	})
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model     string `json:"model"`
			Stream    bool   `json:"stream"`
			MaxTokens int    `json:"max_tokens"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		n := req.MaxTokens
		if n <= 0 || n > 4096 {
			n = 16
		}
		tick := time.Duration(*tokenMS) * time.Millisecond
		if !req.Stream {
			var sb strings.Builder
			for i := range n {
				time.Sleep(tick)
				fmt.Fprintf(&sb, "w%d ", i)
			}
			writeJSON(w, map[string]any{
				"id": "chatcmpl-stand-in", "object": "chat.completion", "created": time.Now().Unix(), "model": req.Model,
				"choices": []any{map[string]any{"index": 0, "finish_reason": "length",
					"message": map[string]any{"role": "assistant", "content": sb.String()}}},
				"usage": map[string]any{"prompt_tokens": 0, "completion_tokens": n, "total_tokens": n},
			})
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		fl := w.(http.Flusher)
		for i := range n {
			time.Sleep(tick)
			b, _ := json.Marshal(map[string]any{
				"id": "chatcmpl-stand-in", "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": req.Model,
				"choices": []any{map[string]any{"index": 0, "finish_reason": nil,
					"delta": map[string]any{"role": "assistant", "content": fmt.Sprintf("w%d ", i)}}},
			})
			if _, err := w.Write(append(append([]byte("data: "), b...), '\n', '\n')); err != nil { // nosemgrep: no-direct-write-to-responsewriter -- text/event-stream of JSON-encoded chunks, not HTML
				return
			}
			fl.Flush()
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
	})
	srv := &http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
