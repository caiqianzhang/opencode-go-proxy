package main

import (
	"bufio"
	"bytes"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type capturedRequest struct {
	path   string
	query  string
	header http.Header
	body   []byte
}

func newCaptureServer(t *testing.T) (*httptest.Server, <-chan capturedRequest) {
	t.Helper()

	requests := make(chan capturedRequest, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read upstream body: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		requests <- capturedRequest{
			path:   r.URL.Path,
			query:  r.URL.RawQuery,
			header: r.Header.Clone(),
			body:   body,
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)
	return server, requests
}

func newTestFront(t *testing.T, upstream *httptest.Server, token string) *httptest.Server {
	t.Helper()

	target, err := url.Parse(upstream.URL + "/inference/go/openai")
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}

	handler, err := NewProxy(Config{
		Upstream:      target,
		APIToken:      token,
		SessionPrefix: "sess-",
	})
	if err != nil {
		t.Fatalf("NewProxy: %v", err)
	}

	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)
	return front
}

func doProxyRequest(t *testing.T, front *httptest.Server, headers map[string]string) *http.Response {
	t.Helper()

	req, err := http.NewRequest(http.MethodPost, front.URL+"/v1/responses?trace=1", strings.NewReader(`{"model":"test"}`))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer incoming")
	for key, value := range headers {
		req.Header.Set(key, value)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func TestPrefersThreadIDAndRewritesPath(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	resp := doProxyRequest(t, front, map[string]string{
		"thread-id":           "thread-123",
		"session-id":          "session-456",
		"x-client-request-id": "request-789",
	})
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusNoContent)
	}

	got := <-requests
	if got.path != "/inference/go/openai/v1/responses" {
		t.Fatalf("path = %q, want %q", got.path, "/inference/go/openai/v1/responses")
	}
	if got.query != "trace=1" {
		t.Fatalf("query = %q, want %q", got.query, "trace=1")
	}
	if value := got.header.Get("x-opencode-session"); value != "sess-thread-123" {
		t.Fatalf("x-opencode-session = %q, want %q", value, "sess-thread-123")
	}
	if value := got.header.Get("Authorization"); value != "Bearer incoming" {
		t.Fatalf("Authorization = %q, want %q", value, "Bearer incoming")
	}
	for _, key := range []string{"thread-id", "session-id", "x-client-request-id"} {
		if value := got.header.Get(key); value != "" {
			t.Fatalf("%s should be stripped, got %q", key, value)
		}
	}
}

func TestFallsBackToSessionID(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	doProxyRequest(t, front, map[string]string{"session-id": "session-456"})

	got := <-requests
	if value := got.header.Get("x-opencode-session"); value != "sess-session-456" {
		t.Fatalf("x-opencode-session = %q, want %q", value, "sess-session-456")
	}
}

func TestFallsBackToClientRequestID(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	doProxyRequest(t, front, map[string]string{"x-client-request-id": "request-789"})

	got := <-requests
	if value := got.header.Get("x-opencode-session"); value != "sess-request-789" {
		t.Fatalf("x-opencode-session = %q, want %q", value, "sess-request-789")
	}
}

func TestGeneratesUUIDWhenNoSessionHeaderExists(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	doProxyRequest(t, front, nil)

	got := <-requests
	value := got.header.Get("x-opencode-session")
	if len(value) != len("sess-")+36 {
		t.Fatalf("x-opencode-session = %q, want sess- followed by a UUID", value)
	}
	if !strings.HasPrefix(value, "sess-") {
		t.Fatalf("x-opencode-session = %q, want sess- prefix", value)
	}
}

func TestDoesNotDoublePrefixSession(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	doProxyRequest(t, front, map[string]string{"thread-id": "sess-existing"})

	got := <-requests
	if value := got.header.Get("x-opencode-session"); value != "sess-existing" {
		t.Fatalf("x-opencode-session = %q, want %q", value, "sess-existing")
	}
}

func TestOverridesAuthorizationWhenTokenConfigured(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "real-key")

	doProxyRequest(t, front, map[string]string{"thread-id": "thread-123"})

	got := <-requests
	if value := got.header.Get("Authorization"); value != "Bearer real-key" {
		t.Fatalf("Authorization = %q, want %q", value, "Bearer real-key")
	}
}

func TestStripsCodexOnlyHeaders(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	doProxyRequest(t, front, map[string]string{
		"thread-id":             "thread-123",
		"x-codex-beta-features": "remote_compaction_v2",
		"x-codex-window-id":     "thread-123:0",
		"x-codex-turn-metadata": `{"thread_id":"thread-123"}`,
	})

	got := <-requests
	for _, key := range []string{"x-codex-beta-features", "x-codex-window-id", "x-codex-turn-metadata"} {
		if value := got.header.Get(key); value != "" {
			t.Fatalf("%s should be stripped, got %q", key, value)
		}
	}
}

func TestStreamsResponseBeforeUpstreamCompletes(t *testing.T) {
	release := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Error("upstream does not support flushing")
			return
		}
		_, _ = io.WriteString(w, "data: first\n\n")
		flusher.Flush()
		<-release
		_, _ = io.WriteString(w, "data: second\n\n")
		flusher.Flush()
	}))
	t.Cleanup(upstream.Close)
	t.Cleanup(unblock)

	front := newTestFront(t, upstream, "")
	req, err := http.NewRequest(http.MethodPost, front.URL+"/v1/responses", strings.NewReader(`{"stream":true}`))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("thread-id", "thread-stream")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })

	lineCh := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(resp.Body).ReadString('\n')
		lineCh <- line
	}()

	select {
	case line := <-lineCh:
		if line != "data: first\n" {
			t.Fatalf("first line = %q, want %q", line, "data: first\n")
		}
		unblock()
	case <-time.After(2 * time.Second):
		unblock()
		t.Fatal("proxy buffered the streaming response")
	}
}

func TestLogsOneLinePerRequestWithoutLeakingCredentials(t *testing.T) {
	upstream, _ := newCaptureServer(t)
	target, err := url.Parse(upstream.URL + "/inference/go/openai")
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}

	var logs bytes.Buffer
	handler, err := NewProxy(Config{
		Upstream: target,
		APIToken: "super-secret-key",
		Logger:   log.New(&logs, "", 0),
	})
	if err != nil {
		t.Fatalf("NewProxy: %v", err)
	}
	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)

	doProxyRequest(t, front, map[string]string{
		"thread-id":     "thread-log",
		"Authorization": "Bearer super-secret-key",
	})

	output := logs.String()
	if !strings.Contains(output, "/v1/responses") {
		t.Fatalf("log output %q should mention the request path", output)
	}
	if !strings.Contains(output, "sess-thread-log") {
		t.Fatalf("log output %q should mention the derived session", output)
	}
	if strings.Contains(output, "super-secret-key") {
		t.Fatalf("log output %q must not contain the API token", output)
	}
	if lines := strings.Count(strings.TrimSpace(output), "\n") + 1; lines != 1 {
		t.Fatalf("expected exactly 1 log line, got %d in %q", lines, output)
	}
}

func TestDumpDirWritesRequestBody(t *testing.T) {
	upstream, _ := newCaptureServer(t)
	target, err := url.Parse(upstream.URL + "/inference/go/openai")
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}

	dumpDir := t.TempDir()
	handler, err := NewProxy(Config{
		Upstream: target,
		DumpDir:  dumpDir,
	})
	if err != nil {
		t.Fatalf("NewProxy: %v", err)
	}
	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)

	doProxyRequest(t, front, map[string]string{"thread-id": "thread-dump"})

	entries, err := os.ReadDir(dumpDir)
	if err != nil {
		t.Fatalf("read dump dir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("dump dir has %d files, want 1", len(entries))
	}
	data, err := os.ReadFile(filepath.Join(dumpDir, entries[0].Name()))
	if err != nil {
		t.Fatalf("read dump file: %v", err)
	}
	if !strings.Contains(string(data), `{"model":"test"}`) {
		t.Fatalf("dump file = %q, want it to contain the request body", data)
	}
}

func TestEmptyDumpDirStillForwardsRequests(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	target, err := url.Parse(upstream.URL + "/inference/go/openai")
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}

	handler, err := NewProxy(Config{Upstream: target})
	if err != nil {
		t.Fatalf("NewProxy: %v", err)
	}
	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)

	doProxyRequest(t, front, map[string]string{"thread-id": "thread-nodump"})

	got := <-requests
	if got.path != "/inference/go/openai/v1/responses" {
		t.Fatalf("path = %q, want the rewritten upstream path", got.path)
	}
}

func TestHealthzBypassesUpstream(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	resp, err := http.Get(front.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read health body: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if string(body) != "ok\n" {
		t.Fatalf("body = %q, want %q", body, "ok\n")
	}
	select {
	case got := <-requests:
		t.Fatalf("health request reached upstream: %+v", got)
	default:
	}
}
