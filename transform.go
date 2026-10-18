package main

import (
	"bytes"
	"encoding/json"
	"unicode"
	"unicode/utf8"
)

// rewriteStats reports what happened to a request body.
type rewriteStats struct {
	Changed int
	Skipped int
}

// rewriteAgentMessages adapts Codex MultiAgent V2 task delivery to providers
// that only implement the public Responses API.
//
// Codex hands a subagent its task as an input item of type "agent_message"
// whose real payload sits in an "encrypted_content" content block. Both are
// OpenAI-internal extensions: a plain Responses implementation accepts only
// message/function_call/function_call_output/reasoning items and the public
// content types, so it drops the whole item and the subagent sees an empty
// task envelope.
//
// The rewrite replaces only the affected items in the raw JSON. Every other
// byte, including key order and large integers, is preserved so prompt prefix
// caching keeps working.
//
// If unwrapEncrypted is false, or a payload does not look like plaintext, the
// affected item is left untouched and counted as Skipped. This avoids feeding
// real ciphertext to a model as if it were the task.
func rewriteAgentMessages(body []byte, unwrapEncrypted bool) ([]byte, rewriteStats) {
	var stats rewriteStats
	if !bytes.Contains(body, []byte(`"agent_message"`)) && !bytes.Contains(body, []byte(`"encrypted_content"`)) {
		return body, stats
	}

	input, ok := findObjectMember(body, "input")
	if !ok {
		return body, stats
	}
	items, ok := arrayItemSpans(body, input)
	if !ok {
		return body, stats
	}

	type replacement struct {
		span byteSpan
		data []byte
	}
	var replacements []replacement

	for _, item := range items {
		raw := body[item.start:item.end]
		newItem, changed, skipped := rewriteItem(raw, unwrapEncrypted)
		if skipped {
			stats.Skipped++
			continue
		}
		if !changed {
			continue
		}
		stats.Changed++
		replacements = append(replacements, replacement{span: item, data: newItem})
	}

	if len(replacements) == 0 {
		return body, stats
	}

	out := make([]byte, 0, len(body)+64)
	last := 0
	for _, rep := range replacements {
		out = append(out, body[last:rep.span.start]...)
		out = append(out, rep.data...)
		last = rep.span.end
	}
	out = append(out, body[last:]...)
	return out, stats
}

// rewriteItem rewrites one input item. It returns changed=false when the item
// is not affected, and skipped=true when it contains encrypted content that
// cannot safely be turned into text.
func rewriteItem(raw []byte, unwrapEncrypted bool) ([]byte, bool, bool) {
	var probe struct {
		Type    string          `json:"type"`
		ID      string          `json:"id"`
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return nil, false, false
	}

	if probe.Type == "agent_message" {
		parts, _, skipped := rewriteContent(probe.Content, unwrapEncrypted)
		if skipped {
			return nil, false, true
		}
		message := map[string]any{"type": "message", "role": "user"}
		if probe.ID != "" {
			message["id"] = probe.ID
		}
		if parts == nil {
			parts = []any{}
		}
		message["content"] = parts
		out, err := json.Marshal(message)
		if err != nil {
			return nil, false, true
		}
		return out, true, false
	}

	if bytes.Contains(raw, []byte(`"encrypted_content"`)) {
		return rewriteContentField(raw, unwrapEncrypted)
	}
	return nil, false, false
}

// rewriteContentField handles encrypted content inside non-agent items while
// preserving every field except the rewritten content array.
func rewriteContentField(raw []byte, unwrapEncrypted bool) ([]byte, bool, bool) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return nil, false, false
	}
	content, ok := fields["content"]
	if !ok {
		return nil, false, false
	}
	parts, changed, skipped := rewriteContent(content, unwrapEncrypted)
	if skipped {
		return nil, false, true
	}
	if !changed {
		return nil, false, false
	}
	encoded, err := json.Marshal(parts)
	if err != nil {
		return nil, false, true
	}
	fields["content"] = encoded
	out, err := json.Marshal(fields)
	if err != nil {
		return nil, false, true
	}
	return out, true, false
}

// rewriteContent turns encrypted_content parts into plain input_text parts.
// Other content parts are embedded verbatim.
func rewriteContent(content json.RawMessage, unwrapEncrypted bool) ([]any, bool, bool) {
	content = bytes.TrimSpace(content)
	if len(content) == 0 || bytes.Equal(content, []byte("null")) {
		return nil, false, false
	}

	if content[0] == '"' {
		var text string
		if err := json.Unmarshal(content, &text); err != nil {
			return nil, false, false
		}
		return []any{inputText(text)}, true, false
	}
	if content[0] != '[' {
		return nil, false, false
	}

	var rawParts []json.RawMessage
	if err := json.Unmarshal(content, &rawParts); err != nil {
		return nil, false, false
	}

	parts := make([]any, 0, len(rawParts))
	changed := false
	for _, rawPart := range rawParts {
		var part struct {
			Type             string          `json:"type"`
			EncryptedContent json.RawMessage `json:"encrypted_content"`
		}
		if err := json.Unmarshal(rawPart, &part); err != nil {
			parts = append(parts, rawPart)
			continue
		}
		if part.Type != "encrypted_content" {
			parts = append(parts, rawPart)
			continue
		}

		text, ok := decodeEncryptedPayload(part.EncryptedContent, unwrapEncrypted)
		if !ok {
			return nil, false, true
		}
		parts = append(parts, inputText(text))
		changed = true
	}
	return parts, changed, false
}

// decodeEncryptedPayload returns the plaintext carried by an
// encrypted_content value. It returns ok=false when unwrapping is disabled or
// the payload does not look like text.
func decodeEncryptedPayload(raw json.RawMessage, unwrapEncrypted bool) (string, bool) {
	if !unwrapEncrypted {
		return "", false
	}
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return "", true
	}

	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		if !looksLikePlaintext(text) {
			return "", false
		}
		return text, true
	}

	var compact bytes.Buffer
	if err := json.Compact(&compact, raw); err != nil {
		return "", false
	}
	encoded := compact.String()
	if !looksLikePlaintext(encoded) {
		return "", false
	}
	return encoded, true
}

// looksLikePlaintext rejects binary/control-character payloads. It cannot
// distinguish every encrypted encoding, which is why unwrapping is also
// switchable with -no-unwrap-encrypted-content.
func looksLikePlaintext(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r == '\n' || r == '\r' || r == '\t' {
			continue
		}
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func inputText(text string) map[string]any {
	return map[string]any{"type": "input_text", "text": text}
}
