# Remote deployment

This directory documents the deployment used for
`https://<your-proxy-host>:9876/codex/v1`.

The proxy runs as a Docker container on the existing `new-api` Docker network,
behind the existing Caddy instance. Caddy terminates TLS and routes
`/codex/*` to the proxy; all other paths keep going to `new-api`.

## Build

The binary must be a static Linux amd64 build. Build it locally, then copy the
binary, this Dockerfile, and the host CA bundle into one directory on the
server:

```bash
docker run --rm -v "$PWD":/src -w /src golang:1.23-alpine \
  sh -c 'go build -trimpath -ldflags "-s -w" -o opencode-go-proxy .'

ssh <ssh-host> 'mkdir -p /root/opencode-go-proxy'
scp opencode-go-proxy <ssh-host>:/root/opencode-go-proxy/
scp deploy/remote/Dockerfile <ssh-host>:/root/opencode-go-proxy/
ssh <ssh-host> \
  'cp /etc/ssl/certs/ca-certificates.crt /root/opencode-go-proxy/'
```

Create `/root/opencode-go-proxy/opencode-go-proxy.env` with mode 600:

```text
OPENCODE_GO_API_KEY=<upstream key>
PROXY_LISTEN=0.0.0.0:8787
PROXY_CLIENT_TOKEN=<long random token>
```

Build and run:

```bash
ssh <ssh-host> '
  cd /root/opencode-go-proxy &&
  docker build -t opencode-go-proxy:local . &&
  docker run -d \
    --name opencode-go-proxy \
    --restart unless-stopped \
    --network new-api_new-api-network \
    --env-file /root/opencode-go-proxy/opencode-go-proxy.env \
    --security-opt no-new-privileges:true \
    --memory 128m \
    --pids-limit 256 \
    opencode-go-proxy:local
'
```

## Caddy route

In the existing Caddyfile, keep the current `new-api` gateway and add a
`/codex/*` handler:

```caddyfile
(codex_gateway) {
    handle_path /codex/* {
        reverse_proxy opencode-go-proxy:8787 {
            flush_interval -1
        }
    }
    handle {
        reverse_proxy new-api:3000 {
            flush_interval -1
        }
    }
}
```

Apply `gateway_headers` and `codex_gateway` to the `:9876` site blocks, then:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Client configuration

```toml
[model_providers.opencode-remote]
name = "OpenCode Go remote"
base_url = "https://<your-proxy-host>:9876/codex/v1"
wire_api = "responses"
experimental_bearer_token = "<same PROXY_CLIENT_TOKEN>"
```

The IP certificate is self-signed and covers `<your-proxy-host>`. Clients must
trust it. The public certificate on this host covers
`<your-domain>`, not `<ssh-host>`.

Never commit the env file or the client token.
