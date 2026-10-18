#!/usr/bin/env bash
# Generate a self-signed TLS certificate with IP and optional DNS SANs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/deploy/compose/certs"
IP=""
DNS=""
DAYS=3650
FORCE=0

usage() {
  cat <<'USAGE'
Usage: gen-self-signed-cert.sh [options]

  --ip IP          IP address for subjectAltName (auto-detected if omitted)
  --dns NAME       optional DNS name for subjectAltName
  --out-dir DIR    output directory (default: deploy/compose/certs)
  --days N         validity in days (default: 3650)
  --force          overwrite existing files
  -h, --help       show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ip) IP="${2:-}"; shift 2 ;;
    --dns) DNS="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

if [ -z "$IP" ]; then
  if command -v ip >/dev/null 2>&1; then
    IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  if [ -z "$IP" ] && command -v hostname >/dev/null 2>&1; then
    IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$IP" ] && command -v ipconfig >/dev/null 2>&1; then
    IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
  fi
  IP="${IP:-127.0.0.1}"
fi

mkdir -p "$OUT_DIR"
for file in fullchain.pem privkey.pem ca.crt; do
  if [ -e "${OUT_DIR}/${file}" ] && [ "$FORCE" -ne 1 ]; then
    echo "refusing to overwrite ${OUT_DIR}/${file}; use --force" >&2
    exit 1
  fi
done

cn="$IP"
[ -n "$DNS" ] && cn="$DNS"

tmp_cfg="$(mktemp /tmp/opencode-cert.XXXXXX.cnf)"
trap 'rm -f "$tmp_cfg"' EXIT

{
  echo '[req]'
  echo 'prompt = no'
  echo 'distinguished_name = dn'
  echo 'x509_extensions = v3'
  echo '[dn]'
  echo "CN = ${cn}"
  echo '[v3]'
  echo 'subjectAltName = @alt'
  echo 'basicConstraints = critical,CA:TRUE'
  echo 'keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign'
  echo 'extendedKeyUsage = serverAuth'
  echo '[alt]'
  echo "IP.1 = ${IP}"
  echo 'IP.2 = 127.0.0.1'
  echo 'DNS.1 = localhost'
  if [ -n "$DNS" ]; then
    echo "DNS.2 = ${DNS}"
  fi
} > "$tmp_cfg"

openssl req -x509 -newkey rsa:4096 -nodes -sha256 \
  -days "$DAYS" \
  -keyout "${OUT_DIR}/privkey.pem" \
  -out "${OUT_DIR}/fullchain.pem" \
  -config "$tmp_cfg" \
  -extensions v3 >/dev/null 2>&1

cp "${OUT_DIR}/fullchain.pem" "${OUT_DIR}/ca.crt"
chmod 600 "${OUT_DIR}/privkey.pem"
chmod 644 "${OUT_DIR}/fullchain.pem" "${OUT_DIR}/ca.crt"

echo "generated:"
echo "  ${OUT_DIR}/fullchain.pem"
echo "  ${OUT_DIR}/privkey.pem"
echo "  ${OUT_DIR}/ca.crt"
echo
openssl x509 -in "${OUT_DIR}/fullchain.pem" -noout -subject -dates -ext subjectAltName
echo
echo "Trust ca.crt on clients. Keep privkey.pem private."
