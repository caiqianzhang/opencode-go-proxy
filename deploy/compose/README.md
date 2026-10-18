# Standalone Docker Compose stack

This stack starts two containers:

```
client --HTTPS--> caddy:9876 --HTTP--> proxy:8787 --HTTPS--> OpenCode Go
```

Use it on a fresh host. **Do not start this stack on a host where port 9876 is
already used by another Caddy**, such as the existing `new-api` deployment. On
that host, add the proxy service to the existing Compose project and a
`/codex/*` route to its Caddyfile instead.

## 1. Generate a certificate

For an IP-based self-signed certificate:

```bash
cd deploy/compose
../../scripts/gen-self-signed-cert.sh --ip <server-ip>
```

For a DNS name, add `--dns <hostname>`. The script writes:

```
certs/fullchain.pem
certs/privkey.pem
certs/ca.crt
```

`ca.crt` is the certificate clients must trust. Never commit `privkey.pem`.

## 2. Configure secrets

```bash
cp opencode-go-proxy.env.example opencode-go-proxy.env
chmod 600 opencode-go-proxy.env
```

Set:

```text
OPENCODE_GO_API_KEY=<upstream key>
PROXY_CLIENT_TOKEN=<long random token>
```

## 3. Start

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f proxy caddy
```

The proxy is not published directly; only Caddy listens on 9876.

To use a different host port, set `PROXY_HTTPS_PORT`:

```bash
PROXY_HTTPS_PORT=7000 docker compose up -d --build
```

The container still listens on 9876 internally; only the host port changes.

## 4. Configure Codex

```toml
[model_providers.opencode-remote]
name = "OpenCode Go remote"
base_url = "https://<server-ip>:9876/codex/v1"
wire_api = "responses"
experimental_bearer_token = "<same PROXY_CLIENT_TOKEN>"
```

Clients using the self-signed certificate must trust `certs/ca.crt`.

## Stop

```bash
docker compose down
```
