package main

import "encoding/json"

// byteSpan is a half-open byte range in a JSON document.
type byteSpan struct {
	start int
	end   int
}

// findObjectMember finds a member of the top-level JSON object and returns the
// byte range of its value. It is intentionally narrow: the proxy only needs
// the top-level "input" array, and keeping the scanner small makes it easy to
// reason about.
func findObjectMember(data []byte, key string) (byteSpan, bool) {
	s := &jsonScanner{data: data}
	s.skipSpace()
	if !s.consume('{') {
		return byteSpan{}, false
	}

	for {
		s.skipSpace()
		if s.peek() == '}' {
			return byteSpan{}, false
		}

		keyStart := s.i
		if !s.skipString() {
			return byteSpan{}, false
		}
		var name string
		if err := json.Unmarshal(data[keyStart:s.i], &name); err != nil {
			return byteSpan{}, false
		}

		s.skipSpace()
		if !s.consume(':') {
			return byteSpan{}, false
		}
		s.skipSpace()
		start := s.i
		if !s.skipValue() {
			return byteSpan{}, false
		}
		end := s.i
		if name == key {
			return byteSpan{start: start, end: end}, true
		}

		s.skipSpace()
		if s.consume(',') {
			continue
		}
		return byteSpan{}, false
	}
}

// arrayItemSpans returns the byte ranges of every element in a JSON array.
func arrayItemSpans(data []byte, array byteSpan) ([]byteSpan, bool) {
	s := &jsonScanner{data: data, i: array.start}
	s.skipSpace()
	if !s.consume('[') {
		return nil, false
	}

	var spans []byteSpan
	s.skipSpace()
	if s.consume(']') {
		return spans, true
	}

	for {
		s.skipSpace()
		start := s.i
		if !s.skipValue() {
			return nil, false
		}
		spans = append(spans, byteSpan{start: start, end: s.i})

		s.skipSpace()
		if s.consume(',') {
			continue
		}
		if s.consume(']') {
			return spans, true
		}
		return nil, false
	}
}

type jsonScanner struct {
	data []byte
	i    int
}

func (s *jsonScanner) peek() byte {
	if s.i >= len(s.data) {
		return 0
	}
	return s.data[s.i]
}

func (s *jsonScanner) skipSpace() {
	for s.i < len(s.data) {
		switch s.data[s.i] {
		case ' ', '\n', '\r', '\t':
			s.i++
		default:
			return
		}
	}
}

func (s *jsonScanner) consume(ch byte) bool {
	if s.peek() != ch {
		return false
	}
	s.i++
	return true
}

func (s *jsonScanner) skipValue() bool {
	switch s.peek() {
	case '"':
		return s.skipString()
	case '{':
		return s.skipObject()
	case '[':
		return s.skipArray()
	case 0:
		return false
	default:
		return s.skipPrimitive()
	}
}

func (s *jsonScanner) skipString() bool {
	if !s.consume('"') {
		return false
	}
	for s.i < len(s.data) {
		switch s.data[s.i] {
		case '\\':
			s.i += 2
		case '"':
			s.i++
			return true
		default:
			s.i++
		}
	}
	return false
}

func (s *jsonScanner) skipObject() bool {
	if !s.consume('{') {
		return false
	}
	s.skipSpace()
	if s.consume('}') {
		return true
	}
	for {
		s.skipSpace()
		if !s.skipString() {
			return false
		}
		s.skipSpace()
		if !s.consume(':') {
			return false
		}
		s.skipSpace()
		if !s.skipValue() {
			return false
		}
		s.skipSpace()
		if s.consume(',') {
			continue
		}
		return s.consume('}')
	}
}

func (s *jsonScanner) skipArray() bool {
	if !s.consume('[') {
		return false
	}
	s.skipSpace()
	if s.consume(']') {
		return true
	}
	for {
		s.skipSpace()
		if !s.skipValue() {
			return false
		}
		s.skipSpace()
		if s.consume(',') {
			continue
		}
		return s.consume(']')
	}
}

func (s *jsonScanner) skipPrimitive() bool {
	start := s.i
	for s.i < len(s.data) {
		switch s.data[s.i] {
		case ' ', '\n', '\r', '\t', ',', '}', ']':
			return s.i > start
		default:
			s.i++
		}
	}
	return s.i > start
}
