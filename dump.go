package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"
)

// dumper writes request bodies to disk for offline inspection. It exists to
// answer "what does Codex actually send?" without a packet capture, and is
// intended for debugging only: bodies are stored verbatim, so they may contain
// prompts, file contents, and other sensitive data.
type dumper struct {
	dir string
	seq atomic.Uint64
}

func newDumper(dir string) (*dumper, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create dump dir %q: %w", dir, err)
	}
	return &dumper{dir: dir}, nil
}

// wrap returns a handler that stores each request body before delegating.
// The body is restored so downstream code sees an unmodified request.
func (d *dumper) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil {
			body, err := io.ReadAll(r.Body)
			_ = r.Body.Close()
			if err != nil {
				http.Error(w, "failed to read request body", http.StatusBadRequest)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			r.ContentLength = int64(len(body))
			d.write(r, body)
		}
		next.ServeHTTP(w, r)
	})
}

// write stores one body per request. Failures are non-fatal: losing a debug
// dump should never break a working proxy.
func (d *dumper) write(r *http.Request, body []byte) {
	seq := d.seq.Add(1)
	name := fmt.Sprintf("%s-%06d-%s.json", time.Now().Format("20060102T150405"), seq, sanitize(r.URL.Path))
	_ = os.WriteFile(filepath.Join(d.dir, name), body, 0o600)
}

// sanitize turns a URL path into a flat, filesystem-safe filename fragment.
func sanitize(path string) string {
	out := make([]rune, 0, len(path))
	for _, r := range path {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			out = append(out, r)
		default:
			out = append(out, '_')
		}
	}
	if len(out) == 0 {
		return "root"
	}
	return string(out)
}
