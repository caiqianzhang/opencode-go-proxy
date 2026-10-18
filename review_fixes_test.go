package main

import (
	"bytes"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestRewritePreservesTopLevelBytesAndLargeNumbers(t *testing.T) {
	body := []byte(`{"model":"m","stream":true,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]},{"type":"agent_message","id":"a1","content":[{"type":"input_text","text":"Payload:\n"},{"type":"encrypted_content","encrypted_content":"DO-THIS"}]}],"seed":9007199254740993}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed != 1 {
		t.Fatalf("changed = %d, want 1", stats.Changed)
	}
	if !bytes.HasPrefix(out, []byte(`{"model":"m","stream":true,"input":[`)) {
		t.Fatalf("top-level key order changed: %s", out)
	}
	agentAt := bytes.Index(body, []byte(`{"type":"agent_message"`))
	if agentAt < 0 {
		t.Fatal("test body is missing agent_message")
	}
	if !bytes.HasPrefix(out, body[:agentAt]) {
		t.Fatalf("bytes before the changed item changed:\n got %s\nwant prefix %s", out, body[:agentAt])
	}
	if !bytes.Contains(out, []byte(`"seed":9007199254740993`)) {
		t.Fatalf("large integer was not preserved: %s", out)
	}
	if bytes.Contains(out, []byte(`"agent_message"`)) {
		t.Fatalf("agent_message was not rewritten: %s", out)
	}
	if !bytes.Contains(out, []byte(`DO-THIS`)) {
		t.Fatalf("task payload was lost: %s", out)
	}
}

func TestTextMentioningAgentMessageIsByteIdentical(t *testing.T) {
	body := []byte(`{"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"mention agent_message and encrypted_content"}]}]}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats != (rewriteStats{}) {
		t.Fatalf("stats = %+v, want zero", stats)
	}
	if !bytes.Equal(out, body) {
		t.Fatalf("body was re-serialized:\n got %s\nwant %s", out, body)
	}
}

func TestSkipsNonPlaintextEncryptedContent(t *testing.T) {
	body := []byte(`{"input":[{"type":"agent_message","content":[{"type":"encrypted_content","encrypted_content":"\u0000\u0001binary"}]}]}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Skipped != 1 || stats.Changed != 0 {
		t.Fatalf("stats = %+v, want skipped=1 changed=0", stats)
	}
	if !bytes.Equal(out, body) {
		t.Fatalf("non-plaintext payload should be left untouched:\n got %s\nwant %s", out, body)
	}
}

func TestDisableUnwrapLeavesAgentMessageUntouched(t *testing.T) {
	body := []byte(`{"input":[{"type":"agent_message","content":[{"type":"encrypted_content","encrypted_content":"DO-THIS"}]}]}`)

	out, stats := rewriteAgentMessages(body, false)
	if stats.Skipped != 1 || stats.Changed != 0 {
		t.Fatalf("stats = %+v, want skipped=1 changed=0", stats)
	}
	if !bytes.Equal(out, body) {
		t.Fatalf("body changed while unwrap was disabled:\n got %s\nwant %s", out, body)
	}
}

func TestAgentMessageStringContent(t *testing.T) {
	body := []byte(`{"input":[{"type":"agent_message","content":"DO-THIS"}]}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed != 1 {
		t.Fatalf("changed = %d, want 1", stats.Changed)
	}
	if !bytes.Contains(out, []byte(`"text":"DO-THIS"`)) {
		t.Fatalf("string content was lost: %s", out)
	}
}

func TestStructuredEncryptedContentPreservesLargeNumber(t *testing.T) {
	body := []byte(`{"input":[{"type":"agent_message","content":[{"type":"encrypted_content","encrypted_content":{"seed":9007199254740993}}]}]}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed != 1 {
		t.Fatalf("changed = %d, want 1", stats.Changed)
	}
	if !bytes.Contains(out, []byte(`9007199254740993`)) {
		t.Fatalf("structured payload lost integer precision: %s", out)
	}
}

func TestScannerHandlesBracketsAndEscapedQuotesInText(t *testing.T) {
	body := []byte(`{"input":[{"type":"message","content":[{"type":"input_text","text":"literal ] } \"quoted\""}]},{"type":"agent_message","content":[{"type":"encrypted_content","encrypted_content":"TASK"}]}]}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed != 1 {
		t.Fatalf("changed = %d, want 1", stats.Changed)
	}
	if !bytes.Contains(out, []byte(`literal ] } \"quoted\"`)) {
		t.Fatalf("earlier text was not preserved: %s", out)
	}
	if !bytes.Contains(out, []byte(`"text":"TASK"`)) {
		t.Fatalf("task payload was lost: %s", out)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("read failed") }
func (failingReader) Close() error             { return nil }

func TestTransformTransportPassesOversizedBodyUntouched(t *testing.T) {
	original := `{"input":[{"type":"agent_message","content":[{"type":"encrypted_content","encrypted_content":"DO-THIS"}]}]}`
	var forwarded string
	base := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			return nil, err
		}
		forwarded = string(body)
		return &http.Response{StatusCode: http.StatusNoContent, Body: http.NoBody}, nil
	})
	tr := &transformTransport{
		base:          base,
		maxBodyBytes:  10,
		disableUnwrap: false,
		logger:        log.New(io.Discard, "", 0),
	}

	req, err := http.NewRequest(http.MethodPost, "http://example.test/v1/responses", strings.NewReader(original))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if _, err := tr.RoundTrip(req); err != nil {
		t.Fatalf("RoundTrip: %v", err)
	}
	if forwarded != original {
		t.Fatalf("oversized body was modified:\n got %s\nwant %s", forwarded, original)
	}
}

func TestTransformTransportReturnsReadError(t *testing.T) {
	base := roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("base transport should not be called")
		return nil, nil
	})
	tr := &transformTransport{
		base:          base,
		maxBodyBytes:  1024,
		disableUnwrap: false,
		logger:        log.New(io.Discard, "", 0),
	}

	req, err := http.NewRequest(http.MethodPost, "http://example.test/v1/responses", failingReader{})
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.ContentLength = 10
	if _, err := tr.RoundTrip(req); err == nil {
		t.Fatal("RoundTrip returned nil error for a failing body")
	}
}

func newFrontWithConfig(t *testing.T, upstream *httptest.Server, cfg Config) *httptest.Server {
	t.Helper()

	target, err := url.Parse(upstream.URL + "/inference/go/openai")
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}
	cfg.Upstream = target
	handler, err := NewProxy(cfg)
	if err != nil {
		t.Fatalf("NewProxy: %v", err)
	}
	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)
	return front
}

func TestClientTokenIsRequiredWhenConfigured(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newFrontWithConfig(t, upstream, Config{
		APIToken:    "upstream-key",
		ClientToken: "client-secret",
	})

	resp, err := http.Post(front.URL+"/v1/responses", "application/json", strings.NewReader(`{"input":[]}`))
	if err != nil {
		t.Fatalf("unauthenticated request: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}

	req, err := http.NewRequest(http.MethodPost, front.URL+"/v1/responses", strings.NewReader(`{"input":[]}`))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer wrong-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("wrong-token request: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 for a wrong token", resp.StatusCode)
	}

	req, err = http.NewRequest(http.MethodPost, front.URL+"/v1/responses", strings.NewReader(`{"input":[]}`))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer client-secret")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("authenticated request: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", resp.StatusCode)
	}

	got := <-requests
	if value := got.header.Get("Authorization"); value != "Bearer upstream-key" {
		t.Fatalf("upstream Authorization = %q, want %q", value, "Bearer upstream-key")
	}
}

func TestProxyCanDisableEncryptedContentUnwrap(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newFrontWithConfig(t, upstream, Config{
		DisableEncryptedContentUnwrap: true,
	})

	body := `{"input":[{"type":"agent_message","content":[{"type":"encrypted_content","encrypted_content":"DO-THIS"}]}]}`
	req, err := http.NewRequest(http.MethodPost, front.URL+"/v1/responses", strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("thread-id", "thread-no-unwrap")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	resp.Body.Close()

	got := <-requests
	if string(got.body) != body {
		t.Fatalf("body changed while unwrap was disabled:\n got %s\nwant %s", got.body, body)
	}
}

func TestLoopbackHostDetection(t *testing.T) {
	tests := []struct {
		host string
		want bool
	}{
		{"127.0.0.1", true},
		{"localhost", true},
		{"::1", true},
		{"[::1]", true},
		{"0.0.0.0", false},
		{"::", false},
		{"192.168.1.20", false},
		{"", false},
	}
	for _, tt := range tests {
		if got := isLoopbackHost(tt.host); got != tt.want {
			t.Errorf("isLoopbackHost(%q) = %v, want %v", tt.host, got, tt.want)
		}
	}
}

func TestListenNetworkMatchesAddressFamily(t *testing.T) {
	tests := []struct {
		host string
		want string
	}{
		{"127.0.0.1", "tcp4"},
		{"0.0.0.0", "tcp4"},
		{"::1", "tcp6"},
		{"::", "tcp6"},
		{"[::1]", "tcp6"},
		{"localhost", "tcp"},
		{"", "tcp"},
	}
	for _, tt := range tests {
		if got := listenNetwork(tt.host); got != tt.want {
			t.Errorf("listenNetwork(%q) = %q, want %q", tt.host, got, tt.want)
		}
	}
}
