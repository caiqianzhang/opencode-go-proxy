#!/usr/bin/env bash
# Install and start the opencode-go-proxy systemd user service.
#
# Reads the API key from the OPENCODE_GO_API_KEY environment variable, or from
# the existing env file if the variable is not set. Never prints the key.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="${REPO_DIR}/deploy/opencode-go-proxy.service"
UNIT_DIR="${HOME}/.config/systemd/user"
ENV_FILE="${HOME}/.config/opencode-go-proxy.env"
BIN_DIR="${HOME}/.local/bin"
BIN_PATH="${BIN_DIR}/opencode-go-proxy"

if [[ ! -x "${REPO_DIR}/opencode-go-proxy" ]]; then
  echo "error: ${REPO_DIR}/opencode-go-proxy not found or not executable" >&2
  echo "build it first: docker run --rm -v \"\$PWD\":/src -w /src golang:1.23-alpine go build -o opencode-go-proxy ." >&2
  exit 1
fi

key="${OPENCODE_GO_API_KEY:-}"
if [[ -z "${key}" && -f "${ENV_FILE}" ]]; then
  key="$(sed -n 's/^OPENCODE_GO_API_KEY=//p' "${ENV_FILE}" | head -1)"
fi
if [[ -z "${key}" ]]; then
  echo "error: set OPENCODE_GO_API_KEY (or pre-create ${ENV_FILE})" >&2
  exit 1
fi

listen="${PROXY_LISTEN:-}"
if [[ -z "${listen}" && -f "${ENV_FILE}" ]]; then
  listen="$(sed -n 's/^PROXY_LISTEN=//p' "${ENV_FILE}" | head -1)"
fi
listen="${listen:-127.0.0.1:8787}"

client_token="${PROXY_CLIENT_TOKEN:-}"
if [[ -z "${client_token}" && -f "${ENV_FILE}" ]]; then
  client_token="$(sed -n 's/^PROXY_CLIENT_TOKEN=//p' "${ENV_FILE}" | head -1)"
fi

umask 077
{
  printf 'OPENCODE_GO_API_KEY=%s\n' "${key}"
  printf 'PROXY_LISTEN=%s\n' "${listen}"
  if [[ -n "${client_token}" ]]; then
    printf 'PROXY_CLIENT_TOKEN=%s\n' "${client_token}"
  fi
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
echo "wrote ${ENV_FILE} (mode 600)"

mkdir -p "${UNIT_DIR}"
install -m 644 "${UNIT_SRC}" "${UNIT_DIR}/opencode-go-proxy.service"
echo "installed ${UNIT_DIR}/opencode-go-proxy.service"

mkdir -p "${BIN_DIR}"
tmp_bin="${BIN_PATH}.new.$$"
install -m 755 "${REPO_DIR}/opencode-go-proxy" "${tmp_bin}"
mv -f "${tmp_bin}" "${BIN_PATH}"
echo "installed ${BIN_PATH}"

systemctl --user daemon-reload
systemctl --user enable opencode-go-proxy.service
systemctl --user restart opencode-go-proxy.service

if command -v loginctl >/dev/null 2>&1; then
  if [[ "$(loginctl show-user "${USER}" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
    echo
    echo "note: user lingering is off, so the service stops when you log out."
    echo "      to keep it running after logout, run: sudo loginctl enable-linger ${USER}"
  fi
fi

echo
systemctl --user --no-pager status opencode-go-proxy.service | head -20
