# Standalone Docker Compose stack

This stack starts two containers:

```
client --HTTPS--> caddy:9876 --HTTP--> proxy:8787 --HTTPS--> OpenCode Go
```

Use it on a fresh host. **Do not start this stack on a host where the configured
host port is already used by another Caddy**, such as the existing `new-api`
deployment. On that host, add the proxy service to the existing Compose project
and a `/codex/*` route to its Caddyfile instead.

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
cp .env.example .env
# Edit COMPOSE_PROJECT_NAME and PROXY_HTTPS_PORT if needed.
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
./start.sh
docker compose ps
docker compose logs -f proxy caddy
```

The proxy is not published directly. Caddy listens on 9876 inside its
container; the host port is `PROXY_HTTPS_PORT`.

To use a different host port, set `PROXY_HTTPS_PORT`:

```bash
PROXY_HTTPS_PORT=7000 docker compose up -d --build
```

The container still listens on 9876 internally; only the host port changes.

`start.sh` checks for the env file and TLS files before calling
`docker compose up -d --build`.

## 4. Configure Codex

```toml
[model_providers.opencode-remote]
name = "OpenCode Go remote"
base_url = "https://<server-ip>:<host-port>/codex/v1"
wire_api = "responses"
experimental_bearer_token = "<same PROXY_CLIENT_TOKEN>"
```

Clients using the self-signed certificate must trust `certs/ca.crt`.

The Compose stack uses static certificates. If you replace them, restart Caddy:

```bash
docker compose restart caddy
```

## Autostart

Both services use `restart: unless-stopped`. With a rootful Docker daemon,
enabling Docker at boot is enough:

```bash
sudo systemctl enable --now docker
./start.sh
```

If you want systemd to manage the whole stack explicitly, use the provided
unit template:

```bash
sudo cp opencode-go-proxy-compose.service /etc/systemd/system/
sudo sed -i "s|/path/to/opencode-go-proxy|$(cd ../.. && pwd)|g" \
  /etc/systemd/system/opencode-go-proxy-compose.service
sudo systemctl daemon-reload
sudo systemctl enable --now opencode-go-proxy-compose
```

This unit is for rootful Docker. For rootless Docker, use a user unit with
`systemctl --user` and enable lingering if the stack must run without a login.

## Trust the certificate

Debian/Ubuntu:

```bash
sudo cp certs/ca.crt /usr/local/share/ca-certificates/opencode-go-proxy.crt
sudo update-ca-certificates
```

Fedora/RHEL:

```bash
sudo cp certs/ca.crt /etc/pki/ca-trust/source/anchors/opencode-go-proxy.crt
sudo update-ca-trust
```

macOS:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain certs/ca.crt
```

Windows PowerShell:

```powershell
certutil -addstore -user Root certs\ca.crt
```

Alternatively, pass the CA to the setup script:

```bash
scripts/setup.sh --mode remote \
  --base-url https://<server-ip>:<host-port>/codex/v1 \
  --ca-cert certs/ca.crt
```

## Stop

```bash
docker compose down
```
