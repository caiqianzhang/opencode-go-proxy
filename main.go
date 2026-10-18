// Command opencode-go-proxy is a local reverse proxy that lets Codex talk to
// the OpenCode Go inference endpoint.
//
// OpenCode Go rejects any request that does not carry a stable
// x-opencode-session header. Codex does not send that header, but it does send
// its own thread and session identifiers, so this proxy maps one onto the
// other and forwards everything else untouched.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// sessionHeader is the header OpenCode Go requires on every request.
const sessionHeader = "x-opencode-session"

// codexSessionHeaders lists the Codex headers used to derive the OpenCode
// session, in order of preference. thread-id is stable for the lifetime of a
// Codex conversation, which is exactly the granularity OpenCode wants.
var codexSessionHeaders = []string{"thread-id", "session-id", "x-client-request-id"}

// codexOnlyHeaders are Codex-specific headers that have no meaning upstream.
// Forwarding them risks confusing the OpenCode gateway, so they are removed.
var codexOnlyHeaders = []string{
	"thread-id",
	"session-id",
	"x-client-request-id",
	"x-codex-beta-features",
	"x-codex-window-id",
	"x-codex-turn-metadata",
	"x-codex-parent-thread-id",
}

// Config describes how the proxy reaches and authenticates against upstream.
type Config struct {
	// Upstream is the OpenCode Go base URL, without a trailing /v1. Codex
	// request paths are appended to it, so
	// "https://opencode.ai/inference/go/openai" plus "/v1/responses" becomes
	// "https://opencode.ai/inference/go/openai/v1/responses".
	Upstream *url.URL

	// APIToken, when set, replaces the inbound Authorization header.
	APIToken string

	// SessionPrefix is prepended to the derived session ID unless it is
	// already present. Defaults to "sess-".
	SessionPrefix string

	// Logger receives one line per request. Defaults to log.Default().
	Logger *log.Logger

	// DumpDir, when set, receives a copy of every raw request body. It is a
	// debugging aid for inspecting what Codex actually sends; leave it empty
	// in normal operation because bodies may contain sensitive content.
	DumpDir string

	// MaxBodyBytes caps request bodies that are buffered for transformation.
	// Larger bodies pass through untouched. Zero means the default (64 MiB);
	// a negative value disables the limit.
	MaxBodyBytes int64

	// DisableEncryptedContentUnwrap leaves agent_message items untouched when
	// their payload is real ciphertext rather than plaintext.
	DisableEncryptedContentUnwrap bool

	// ClientToken, when set, requires inbound requests to carry
	// "Authorization: Bearer <ClientToken>". This is for exposing the proxy
	// beyond loopback without leaving it open to everyone.
	ClientToken string
}

// NewProxy builds the HTTP handler. It validates the configuration eagerly so
// misconfiguration surfaces at startup instead of on the first request.
func NewProxy(cfg Config) (http.Handler, error) {
	if cfg.Upstream == nil {
		return nil, fmt.Errorf("upstream URL is required")
	}
	if cfg.SessionPrefix == "" {
		cfg.SessionPrefix = "sess-"
	}
	if cfg.Logger == nil {
		cfg.Logger = log.Default()
	}
	if cfg.MaxBodyBytes == 0 {
		cfg.MaxBodyBytes = 64 << 20
	}

	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(cfg.Upstream)
			if host := cfg.Upstream.Host; host != "" {
				r.Out.Host = host
			}

			for _, header := range codexOnlyHeaders {
				r.Out.Header.Del(header)
			}
			if cfg.APIToken != "" {
				r.Out.Header.Set("Authorization", "Bearer "+cfg.APIToken)
			}
			session := sessionFor(r.In.Header, cfg.SessionPrefix)
			r.Out.Header.Set(sessionHeader, session)

			// Log only non-sensitive routing facts. The Authorization
			// header and request body are deliberately never recorded.
			cfg.Logger.Printf("%s %s session=%s", r.In.Method, r.In.URL.Path, session)
		},
		Transport: newTransformTransport(newTransport(), cfg),
		// -1 disables buffering so SSE chunks reach Codex as soon as the
		// upstream produces them.
		FlushInterval: -1,
		ErrorLog:      cfg.Logger,
	}

	handler := http.Handler(proxy)
	if cfg.DumpDir != "" {
		dumper, err := newDumper(cfg.DumpDir)
		if err != nil {
			return nil, err
		}
		handler = dumper.wrap(handler)
	}
	if cfg.ClientToken != "" {
		handler = requireBearer(cfg.ClientToken, handler)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.Handle("/", handler)
	return mux, nil
}

// newTransport returns a transport tuned for long-lived streaming responses.
// In particular it sets no response header timeout, because a reasoning model
// may think for a long time before the first byte arrives.
func newTransport() *http.Transport {
	return &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		// Keep the wire format byte-for-byte identical to what the upstream
		// sent; re-compressing would also break SSE framing expectations.
		DisableCompression: true,
		TLSClientConfig:    &tls.Config{MinVersion: tls.VersionTLS12},
	}
}

// transformTransport rewrites multi-agent messages before handing the request
// to the real transport. Doing it here (instead of in ReverseProxy.Rewrite)
// lets us return a clear error if the body cannot be read.
type transformTransport struct {
	base          http.RoundTripper
	maxBodyBytes  int64
	disableUnwrap bool
	logger        *log.Logger
}

func newTransformTransport(base http.RoundTripper, cfg Config) *transformTransport {
	return &transformTransport{
		base:          base,
		maxBodyBytes:  cfg.MaxBodyBytes,
		disableUnwrap: cfg.DisableEncryptedContentUnwrap,
		logger:        cfg.Logger,
	}
}

func (t *transformTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if !t.shouldTransform(req) {
		return t.base.RoundTrip(req)
	}

	original := req.Body
	var reader io.Reader = original
	if t.maxBodyBytes > 0 {
		reader = io.LimitReader(original, t.maxBodyBytes+1)
	}
	body, err := io.ReadAll(reader)
	if err != nil {
		_ = original.Close()
		return nil, fmt.Errorf("read request body: %w", err)
	}

	if t.maxBodyBytes > 0 && int64(len(body)) > t.maxBodyBytes {
		// Preserve the bytes already read and let the rest stream through.
		req.Body = io.NopCloser(io.MultiReader(bytes.NewReader(body), original))
		t.logger.Printf("warning: request body exceeds %d bytes; forwarding without rewrite", t.maxBodyBytes)
		return t.base.RoundTrip(req)
	}
	_ = original.Close()

	rewritten, stats := rewriteAgentMessages(body, !t.disableUnwrap)
	if stats.Changed > 0 {
		body = rewritten
		t.logger.Printf("transformed %d multi-agent item(s)", stats.Changed)
	}
	if stats.Skipped > 0 {
		t.logger.Printf("warning: skipped %d encrypted item(s); payload is not plaintext or unwrap is disabled", stats.Skipped)
	}

	req.Body = io.NopCloser(bytes.NewReader(body))
	req.ContentLength = int64(len(body))
	req.Header.Set("Content-Length", strconv.Itoa(len(body)))
	return t.base.RoundTrip(req)
}

func (t *transformTransport) shouldTransform(req *http.Request) bool {
	if req.Body == nil || req.Body == http.NoBody || req.ContentLength == 0 {
		return false
	}
	if enc := req.Header.Get("Content-Encoding"); enc != "" && !strings.EqualFold(enc, "identity") {
		return false
	}
	if ct := req.Header.Get("Content-Type"); ct != "" && !strings.Contains(strings.ToLower(ct), "json") {
		return false
	}
	if t.maxBodyBytes > 0 && req.ContentLength > t.maxBodyBytes {
		t.logger.Printf("warning: request body exceeds %d bytes; forwarding without rewrite", t.maxBodyBytes)
		return false
	}
	return true
}

// requireBearer adds a simple inbound authentication check. It is optional and
// only intended for deployments where the proxy is reachable beyond loopback.
func requireBearer(token string, next http.Handler) http.Handler {
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(strings.TrimSpace(r.Header.Get("Authorization")))
		if subtle.ConstantTimeCompare(got, want) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// isLoopbackHost reports whether a listen host is limited to the local
// machine. Empty hosts and wildcard addresses are deliberately not loopback.
func isLoopbackHost(host string) bool {
	host = strings.TrimSpace(host)
	host = strings.TrimPrefix(host, "[")
	host = strings.TrimSuffix(host, "]")
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// listenNetwork selects tcp4/tcp6 for literal addresses so "0.0.0.0" really
// means IPv4-only and "[::]" really means IPv6-only. Hostnames keep the
// dual-stack "tcp" behavior.
func listenNetwork(host string) string {
	host = strings.TrimSpace(host)
	host = strings.TrimPrefix(host, "[")
	host = strings.TrimSuffix(host, "]")
	ip := net.ParseIP(host)
	switch {
	case ip == nil:
		return "tcp"
	case ip.To4() != nil:
		return "tcp4"
	default:
		return "tcp6"
	}
}

// sessionFor picks the OpenCode session ID for a request, preferring the
// stablest Codex identifier available and falling back to a fresh UUID.
func sessionFor(header http.Header, prefix string) string {
	for _, name := range codexSessionHeaders {
		if value := strings.TrimSpace(header.Get(name)); value != "" {
			if strings.HasPrefix(value, prefix) {
				return value
			}
			return prefix + value
		}
	}
	return prefix + newUUID()
}

// newUUID returns a random RFC 4122 version 4 UUID.
func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand failing is unrecoverable in practice; a timestamp keeps
		// the proxy usable rather than dropping the request.
		return fmt.Sprintf("%d-0000-4000-8000-000000000000", time.Now().UnixNano())
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80

	var buf [36]byte
	hex.Encode(buf[0:8], b[0:4])
	buf[8] = '-'
	hex.Encode(buf[9:13], b[4:6])
	buf[13] = '-'
	hex.Encode(buf[14:18], b[6:8])
	buf[18] = '-'
	hex.Encode(buf[19:23], b[8:10])
	buf[23] = '-'
	hex.Encode(buf[24:36], b[10:16])
	return string(buf[:])
}

func main() {
	var (
		listenAddr    = flag.String("listen", envOr("PROXY_LISTEN", "127.0.0.1:8787"), "address to listen on (use 0.0.0.0:8787 to expose it)")
		upstreamURL   = flag.String("upstream", envOr("OPENCODE_GO_BASE_URL", "https://opencode.ai/inference/go/openai"), "OpenCode Go base URL without /v1")
		token         = flag.String("token", os.Getenv("OPENCODE_GO_API_KEY"), "OpenCode Go API key (prefer OPENCODE_GO_API_KEY; -token is visible in the process list)")
		sessionPrefix = flag.String("session-prefix", envOr("PROXY_SESSION_PREFIX", "sess-"), "prefix applied to derived session IDs")
		dumpDir       = flag.String("dump-dir", envOr("PROXY_DUMP_DIR", ""), "if set, write each request body here for debugging (contains sensitive data)")
		maxBodyBytes  = flag.Int64("max-body-bytes", envInt64("PROXY_MAX_BODY_BYTES", 64<<20), "maximum request body size to buffer for rewriting; larger bodies pass through")
		noUnwrap      = flag.Bool("no-unwrap-encrypted-content", envBool("PROXY_NO_UNWRAP_ENCRYPTED_CONTENT", false), "leave encrypted_content items untouched (use when the parent sends real ciphertext)")
		clientToken   = flag.String("client-token", os.Getenv("PROXY_CLIENT_TOKEN"), "if set, require inbound Authorization: Bearer <token>")
	)
	flag.Parse()

	if strings.TrimSpace(*token) == "" {
		*token = strings.TrimSpace(os.Getenv("OPENCODE_GO_API_KEY"))
	}
	if *token == "" {
		log.Println("warning: no API token configured; the inbound Authorization header will be forwarded as-is")
	}

	upstream, err := url.Parse(*upstreamURL)
	if err != nil {
		log.Fatalf("invalid upstream URL %q: %v", *upstreamURL, err)
	}
	if upstream.Scheme != "http" && upstream.Scheme != "https" {
		log.Fatalf("invalid upstream URL %q: scheme must be http or https", *upstreamURL)
	}
	host, _, err := net.SplitHostPort(*listenAddr)
	if err != nil {
		log.Fatalf("invalid listen address %q: %v", *listenAddr, err)
	}
	if !isLoopbackHost(host) {
		log.Printf("warning: listening on non-loopback address %q; anyone who can reach this port can use the configured upstream key", *listenAddr)
		if *clientToken == "" {
			log.Printf("warning: no -client-token configured; add one before exposing this proxy to a network")
		}
	}

	handler, err := NewProxy(Config{
		Upstream:                      upstream,
		APIToken:                      *token,
		SessionPrefix:                 *sessionPrefix,
		DumpDir:                       *dumpDir,
		MaxBodyBytes:                  *maxBodyBytes,
		DisableEncryptedContentUnwrap: *noUnwrap,
		ClientToken:                   *clientToken,
	})
	if err != nil {
		log.Fatalf("build proxy: %v", err)
	}

	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 20 * time.Second,
		// No WriteTimeout: streaming turns can run for many minutes.
	}

	listener, err := net.Listen(listenNetwork(host), *listenAddr)
	if err != nil {
		log.Fatalf("listen on %s: %v", *listenAddr, err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("listening on http://%s -> %s", listener.Addr(), upstream)
	if *dumpDir != "" {
		log.Printf("warning: dumping request bodies to %s; they may contain sensitive content", *dumpDir)
	}
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server stopped: %v", err)
	}
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		log.Printf("warning: ignoring invalid %s=%q", key, value)
		return fallback
	}
	return parsed
}

func envInt64(key string, fallback int64) int64 {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		log.Printf("warning: ignoring invalid %s=%q", key, value)
		return fallback
	}
	return parsed
}
