package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

func TestRewritesAgentMessageIntoUserMessage(t *testing.T) {
	body := []byte(`{
		"model": "m",
		"input": [
			{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hello"}]},
			{
				"type": "agent_message",
				"id": "msg-1",
				"author": "/root",
				"recipient": "/root/child",
				"content": [
					{"type": "input_text", "text": "Message Type: NEW_TASK\nTask name: /root/child\nPayload:\n"},
					{"type": "encrypted_content", "encrypted_content": "DO-THIS"}
				]
			}
		]
	}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed == 0 {
		t.Fatal("changed = 0, want the agent_message to be rewritten")
	}

	var doc struct {
		Input []struct {
			Type    string `json:"type"`
			Role    string `json:"role"`
			ID      string `json:"id"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"input"`
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if len(doc.Input) != 2 {
		t.Fatalf("input has %d items, want 2", len(doc.Input))
	}

	item := doc.Input[1]
	if item.Type != "message" {
		t.Fatalf("rewritten item type = %q, want %q", item.Type, "message")
	}
	if item.Role != "user" {
		t.Fatalf("rewritten item role = %q, want %q", item.Role, "user")
	}
	if item.ID != "msg-1" {
		t.Fatalf("rewritten item id = %q, want %q", item.ID, "msg-1")
	}
	for _, part := range item.Content {
		if part.Type != "input_text" {
			t.Fatalf("content part type = %q, want only input_text", part.Type)
		}
	}
	text := item.Content[0].Text + item.Content[1].Text
	if !strings.Contains(text, "DO-THIS") {
		t.Fatalf("rewritten text %q should carry the task payload", text)
	}
}

func TestUnwrapsEncryptedContentInsideOtherItems(t *testing.T) {
	body := []byte(`{"input":[{"type":"message","role":"user","content":[
		{"type":"encrypted_content","encrypted_content":"PAYLOAD"}
	]}]}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed == 0 {
		t.Fatal("changed = 0, want the encrypted_content part to be unwrapped")
	}
	if strings.Contains(string(out), "encrypted_content") {
		t.Fatalf("result %s still contains encrypted_content", out)
	}
	if !strings.Contains(string(out), "PAYLOAD") {
		t.Fatalf("result %s lost the payload text", out)
	}
}

func TestOrdinaryRequestIsByteIdentical(t *testing.T) {
	body := []byte(`{"model":"m","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}],"stream":true}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed != 0 {
		t.Fatalf("changed = %d, want 0", stats.Changed)
	}
	if string(out) != string(body) {
		t.Fatalf("body was re-serialized:\n got %s\nwant %s", out, body)
	}
}

func TestNonJSONBodyPassesThrough(t *testing.T) {
	body := []byte("not json at all")

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed != 0 {
		t.Fatalf("changed = %d, want 0", stats.Changed)
	}
	if string(out) != string(body) {
		t.Fatalf("body = %q, want it unchanged", out)
	}
}

func TestNonStringEncryptedContentIsSerialized(t *testing.T) {
	body := []byte(`{"input":[{"type":"agent_message","content":[
		{"type":"encrypted_content","encrypted_content":{"task":"analyze"}}
	]}]}`)

	out, stats := rewriteAgentMessages(body, true)
	if stats.Changed == 0 {
		t.Fatal("changed = 0, want a change")
	}
	if !strings.Contains(string(out), "analyze") {
		t.Fatalf("result %s should carry the structured payload", out)
	}
}

func TestProxyRewritesAgentMessageEndToEnd(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	body := `{"model":"m","input":[{"type":"agent_message","author":"/root","recipient":"/root/c","content":[{"type":"encrypted_content","encrypted_content":"RELAY-OK"}]}]}`
	req, err := http.NewRequest(http.MethodPost, front.URL+"/v1/responses", strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("thread-id", "thread-transform")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })

	got := <-requests
	if strings.Contains(string(got.body), "agent_message") {
		t.Fatalf("upstream received %s, which still contains agent_message", got.body)
	}
	if !strings.Contains(string(got.body), "RELAY-OK") {
		t.Fatalf("upstream received %s, which lost the payload", got.body)
	}
	if got.header.Get("Content-Length") != strconv.Itoa(len(got.body)) && got.header.Get("Content-Length") != "" {
		t.Fatalf("Content-Length %q does not match body length %d", got.header.Get("Content-Length"), len(got.body))
	}
}

func TestProxyLeavesOrdinaryBodyUntouched(t *testing.T) {
	upstream, requests := newCaptureServer(t)
	front := newTestFront(t, upstream, "")

	body := `{"model":"m","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}]}`
	req, err := http.NewRequest(http.MethodPost, front.URL+"/v1/responses", strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("thread-id", "thread-untouched")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })

	got := <-requests
	if string(got.body) != body {
		t.Fatalf("upstream body changed:\n got %s\nwant %s", got.body, body)
	}
}
