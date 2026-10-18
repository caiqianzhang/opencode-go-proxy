#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f opencode-go-proxy.env ]; then
  echo "missing opencode-go-proxy.env; copy opencode-go-proxy.env.example first" >&2
  exit 1
fi
if [ ! -f certs/fullchain.pem ] || [ ! -f certs/privkey.pem ]; then
  echo "missing TLS files under certs/; run scripts/gen-self-signed-cert.sh first" >&2
  exit 1
fi

exec docker compose up -d --build
