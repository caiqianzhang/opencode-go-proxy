FROM scratch

# The proxy is a static Go binary. The CA bundle is required for outbound TLS
# to the OpenCode Go endpoint.
COPY ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY opencode-go-proxy /opencode-go-proxy

ENTRYPOINT ["/opencode-go-proxy"]
