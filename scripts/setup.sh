#!/usr/bin/env bash
# OpenCode Go proxy setup for Codex (Linux / macOS / WSL).
#
# Interactive menu:
#   1 = configure Codex to use the hosted HTTPS proxy
#   2 = configure Codex to use a local proxy service
#   9 = restore the most recent config backup
#
# Non-interactive examples:
#   setup.sh --mode remote --base-url https://<your-proxy-host>:9876/codex/v1 \
#            --token "$PROXY_CLIENT_TOKEN" --yes
#   setup.sh --mode local --api-key "$OPENCODE_GO_API_KEY" --yes
#   setup.sh --mode restore --yes
set -euo pipefail

SCRIPT_VERSION="1.0.0"
MODEL_SLUG="deepseek-v4.1-flash"
PROVIDER_ID="opencode-go"
DEFAULT_REMOTE_BASE_URL="https://<your-proxy-host>:9876/codex/v1"
DEFAULT_LOCAL_BASE_URL="http://127.0.0.1:8787/v1"
BACKUP_DIRNAME="backup-opencode-go-proxy"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
CONFIG_PATH="${CODEX_HOME_DIR}/config.toml"
BACKUP_ROOT="${CODEX_HOME_DIR}/${BACKUP_DIRNAME}"

# Public self-signed certificate for https://<your-proxy-host>:9876.
# Embedded so the curl one-liner can save it without a repo checkout.
IP_CERT_PEM='-----BEGIN CERTIFICATE-----
MIIDMzCCAhugAwIBAgIUIFm3ZKt9rq4FVrz09/Uz7jDkeBIwDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNMTIwLjQ4LjExMi4yNjAeFw0yNjEwMTQwMzMwMzVaFw0z
NjEwMTEwMzMwMzVaMBgxFjAUBgNVBAMMDTEyMC40OC4xMTIuMjYwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQCUqXwiafCK6H83F+2lBAMXM6tJDsMgcoK6
KLhPsnwE93GJatuTrrCt8vyLWiAcza+fI2hNprzg2C0AaVEJ9HxzWoiGRW5bvR2E
ftNyuVmqYc6OJpDro/xsOLVuaCCq9+W7LapTXTYRvIX/XNGmSMac1cnPYVhyFD68
nBraaP2BmEOfVErKGBA6PYz5wU8YEumdoozmURyj47iO0TDkeX308rCihaZ+YBfg
FgQGPzpoNr2cjUsXn/m2a8Uzchrk7tsH18yMlg8j6pei+w77Gz0rHNAUIEQafB8x
HI9sWBtBqXypCOdGiN+ULmXbqvEEomcWpdGuGyYJ7GeWqP5Vyk4VAgMBAAGjdTBz
MB0GA1UdDgQWBBRx95lwfmYSBuZentISHRqcCjFZEjAfBgNVHSMEGDAWgBRx95lw
fmYSBuZentISHRqcCjFZEjAPBgNVHRMBAf8EBTADAQH/MCAGA1UdEQQZMBeHBHgw
cBqHBH8AAAGCCWxvY2FsaG9zdDANBgkqhkiG9w0BAQsFAAOCAQEAka9IG26bK9OQ
x4h98/U3h5yePBxXLepF+gAz1tzAQX7EnEWmaEL08iftlT8txHvLXbEiaryAfmWz
MB2VJHC8U2gjweLNPaKS07zHD5VL1TMABqrIQZZ+KfYvPktyISu/h+VR4+Y+ct4X
yYseMRXhP9mBE0KKZCve5zg9TDZ6egAD60FjKbcpr5PjG8DTVMspq06mSs/gJflZ
V6mPV6qSd7KRpa9IV4MBR1fb6AHclfGNmIyrhSSnlaucP7AhOipfK1o0VNgiDTce
0mRpPadzV32iWVD0kaAWm1PTtJNa/F/Vf/5gUbq6E4SYTods4HG+0W0O0a98OrG3
4ky9txOQjw==
-----END CERTIFICATE-----'

if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'
else
  C_RST=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_DIM=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }
head1(){ printf '\n%s%s%s\n' "$C_B" "$*" "$C_RST"; }

usage() {
  cat <<'USAGE'
Usage: setup.sh [options]

  --mode remote|local|restore
  --base-url URL       Codex provider base URL
  --token TOKEN        client token for remote mode (or PROXY_CLIENT_TOKEN)
  --api-key KEY        OpenCode Go key for local mode (or OPENCODE_GO_API_KEY)
  --catalog PATH       model catalog to set as model_catalog_json
  --yes                do not ask for confirmation
  --skip-test          skip the remote endpoint check
  -h, --help           show this help

With no --mode, an interactive menu is shown.
USAGE
}

read_tty() {
  local __var="$1" __prompt="$2" __ans=''
  if [ -t 0 ]; then
    printf '%s' "$__prompt" >&2
    IFS= read -r __ans || __ans=''
  elif [ -r /dev/tty ]; then
    printf '%s' "$__prompt" >&2
    IFS= read -r __ans < /dev/tty || __ans=''
  else
    printf '%s' "$__prompt" >&2
    IFS= read -r __ans || __ans=''
  fi
  eval "$__var=\$__ans"
}

read_secret_tty() {
  local __var="$1" __prompt="$2" __ans=''
  if [ -t 0 ]; then
    printf '%s' "$__prompt" >&2
    IFS= read -r -s __ans || __ans=''
    printf '\n' >&2
  elif [ -r /dev/tty ]; then
    printf '%s' "$__prompt" >/dev/tty
    IFS= read -r -s __ans < /dev/tty || __ans=''
    printf '\n' >/dev/tty
  else
    die "需要 token，但当前没有终端可输入。请设置 PROXY_CLIENT_TOKEN 或使用 --token。"
  fi
  eval "$__var=\$__ans"
}

find_python() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
        printf '%s' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

resolve_catalog() {
  local requested="$1"
  if [ -n "$requested" ]; then
    [ -f "$requested" ] || die "model catalog not found: $requested"
    (cd "$(dirname "$requested")" && printf '%s/%s' "$PWD" "$(basename "$requested")")
    return 0
  fi
  if [ -f "${CODEX_HOME_DIR}/models.newapi.json" ]; then
    printf '%s' "${CODEX_HOME_DIR}/models.newapi.json"
  elif [ -f "${CODEX_HOME_DIR}/models.json" ]; then
    printf '%s' "${CODEX_HOME_DIR}/models.json"
  fi
}

backup_config() {
  local mode="$1" base_url="$2"
  local stamp dir existed=1
  stamp="$(date '+%Y%m%d-%H%M%S')-$$"
  if [ ! -d "${BACKUP_ROOT}/original" ]; then
    dir="${BACKUP_ROOT}/original"
  else
    dir="${BACKUP_ROOT}/snapshot-${stamp}"
  fi
  mkdir -p "$dir"
  if [ -f "$CONFIG_PATH" ]; then
    cp -p "$CONFIG_PATH" "${dir}/config.toml" || die "备份 config.toml 失败"
  else
    existed=0
  fi
  {
    printf 'script_version=%s\n' "$SCRIPT_VERSION"
    printf 'installed_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'mode=%s\n' "$mode"
    printf 'base_url=%s\n' "$base_url"
    printf 'original_config_existed=%s\n' "$existed"
  } > "${dir}/manifest.txt"
  ok "已备份 Codex 配置 → $dir"
}

update_config() {
  local base_url="$1" token="$2" catalog="$3"
  local python
  python="$(find_python)" || die "需要 Python 3.8+ 来安全更新 TOML 配置。"

  SETUP_CONFIG="$CONFIG_PATH" \
  SETUP_BASE_URL="$base_url" \
  SETUP_TOKEN="$token" \
  SETUP_MODEL="$MODEL_SLUG" \
  SETUP_PROVIDER="$PROVIDER_ID" \
  SETUP_CATALOG="$catalog" \
  "$python" - <<'PY'
import json
import os
import pathlib
import re
import tempfile

config_path = pathlib.Path(os.environ["SETUP_CONFIG"])
base_url = os.environ["SETUP_BASE_URL"]
token = os.environ["SETUP_TOKEN"]
model = os.environ["SETUP_MODEL"]
provider = os.environ["SETUP_PROVIDER"]
catalog = os.environ.get("SETUP_CATALOG", "").strip()

text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""

# Remove the existing provider block, including sub-sections.
target = f"model_providers.{provider}"
kept = []
skip = False
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        header = stripped[1:-1].strip()
        skip = header == target or header.startswith(target + ".")
    if not skip:
        kept.append(line)
text = "\n".join(kept).rstrip() + ("\n" if kept else "")

lines = text.splitlines()
first_section = next((i for i, line in enumerate(lines) if line.lstrip().startswith("[")), len(lines))
head = lines[:first_section]
tail = lines[first_section:]

def replace_top_level(lines, key, value):
    pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
    found = False
    out = []
    for line in lines:
        if pattern.match(line):
            if not found:
                out.append(f"{key} = {json.dumps(value, ensure_ascii=False)}")
                found = True
            continue
        out.append(line)
    if not found:
        insert_at = len(out)
        while insert_at > 0 and out[insert_at - 1].strip() == "":
            insert_at -= 1
        out.insert(insert_at, f"{key} = {json.dumps(value, ensure_ascii=False)}")
    return out

head = replace_top_level(head, "model", model)
head = replace_top_level(head, "model_provider", provider)
if catalog:
    head = replace_top_level(head, "model_catalog_json", catalog)

block = [
    "",
    f"[model_providers.{provider}]",
    'name = "OpenCode Go"',
    f"base_url = {json.dumps(base_url, ensure_ascii=False)}",
    'wire_api = "responses"',
    f"experimental_bearer_token = {json.dumps(token, ensure_ascii=False)}",
]

new_text = "\n".join(head + tail + block).rstrip() + "\n"

try:
    import tomllib
    parsed = tomllib.loads(new_text)
    assert parsed.get("model") == model
    assert parsed.get("model_provider") == provider
    assert provider in parsed.get("model_providers", {})
    if catalog:
        assert parsed.get("model_catalog_json") == catalog
except ModuleNotFoundError:
    pass
except Exception as exc:
    raise SystemExit(f"generated config.toml failed validation: {exc}")

config_path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp_name = tempfile.mkstemp(prefix=".config.toml.", dir=str(config_path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(new_text)
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, config_path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY
  ok "已更新 $CONFIG_PATH"
  if grep -Eq '^[[:space:]]*profile[[:space:]]*=' "$CONFIG_PATH" 2>/dev/null; then
    warn "检测到顶层 profile，可能覆盖 model/model_provider；请检查 profile 内容。"
  fi
  if ! grep -q '^[[:space:]]*model_catalog_json[[:space:]]*=' "$CONFIG_PATH" 2>/dev/null; then
    warn "未设置 model_catalog_json；若 Codex 显示 fallback/Unknown model，请用 --catalog 指定模型目录。"
  fi
}

check_remote() {
  local base_url="$1" token="$2"
  command -v curl >/dev/null 2>&1 || { warn "未找到 curl，跳过远端连通性检查"; return 0; }
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -X POST "${base_url}/responses" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d '{}' 2>/dev/null || true)"
  case "$code" in
    401|403) die "远端拒绝了这个 client token（HTTP $code）。" ;;
    000|'') warn "远端连通性检查失败；请确认网络和 IP 自签证书已受信任。" ;;
    2*) ok "远端鉴权通过（HTTP $code）" ;;
    4*|5*) ok "远端鉴权通过（HTTP $code，空探测请求被上游拒绝属正常）" ;;
    *) warn "远端返回了未预期的 HTTP $code" ;;
  esac
}

trust_hint() {
  local base_url="$1" cert_src cert_dst
  case "$base_url" in
    https://<your-proxy-host>:9876/*) ;;
    *) return 0 ;;
  esac
  cert_src="${REPO_DIR}/deploy/remote/ip-ca.crt"
  cert_dst="${HOME}/.config/opencode-go-proxy/ip-ca.crt"
  if [ -f "$cert_src" ]; then
    mkdir -p "$(dirname "$cert_dst")"
    cp "$cert_src" "$cert_dst"
    chmod 644 "$cert_dst"
    info "${C_DIM}IP 证书已保存到 ${cert_dst}${C_RST}"
  elif [ -n "$IP_CERT_PEM" ]; then
    mkdir -p "$(dirname "$cert_dst")"
    printf '%s\n' "$IP_CERT_PEM" > "$cert_dst"
    chmod 644 "$cert_dst"
    info "${C_DIM}IP 证书已保存到 ${cert_dst}${C_RST}"
  fi
  if command -v curl >/dev/null 2>&1; then
    if ! curl -sS -o /dev/null --max-time 10 https://<your-proxy-host>:9876/ >/dev/null 2>&1; then
      warn "当前系统还未信任 <your-proxy-host> 的自签证书。"
      info "  Debian/Ubuntu: sudo cp ${cert_dst} /usr/local/share/ca-certificates/opencode-go-proxy-ip.crt && sudo update-ca-certificates"
      info "  macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${cert_dst}"
      info "  Windows: 使用 scripts/setup.ps1，会安装到当前用户的 Root 证书商店。"
    fi
  fi
}

restore_config() {
  [ -d "$BACKUP_ROOT" ] || die "没有找到备份目录：$BACKUP_ROOT"
  local list chosen
  list="$(
    if [ -d "${BACKUP_ROOT}/original" ]; then
      printf 'original\n'
    fi
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'snapshot-*' \
      -exec basename {} \; 2>/dev/null | sort -r
  )"
  [ -n "$list" ] || die "没有可恢复的备份。"

  chosen="$(printf '%s\n' "$list" | head -1)"
  local count
  count="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  if [ "$ASSUME_YES" -eq 0 ] && [ "$count" -gt 1 ]; then
    head1 "选择要恢复的备份"
    local i=1
    while IFS= read -r name; do
      info "  $i. $name"
      i=$((i + 1))
    done <<< "$list"
    local answer
    read_tty answer "输入序号（默认 1）: "
    answer="${answer:-1}"
    [[ "$answer" =~ ^[0-9]+$ ]] || die "无效序号。"
    local idx=$((answer - 1))
    [ "$idx" -ge 0 ] && [ "$idx" -lt "$count" ] || die "序号超出范围。"
    chosen="$(printf '%s\n' "$list" | sed -n "$((idx + 1))p")"
  fi

  local dir="${BACKUP_ROOT}/${chosen}"
  local existed=1
  if [ -f "${dir}/manifest.txt" ]; then
    existed="$(sed -n 's/^original_config_existed=//p' "${dir}/manifest.txt" | head -1)"
  fi
  if [ "$ASSUME_YES" -eq 0 ]; then
    local answer
    read_tty answer "确认恢复 ${chosen}？输入 y 继续: "
    case "$answer" in y|Y|yes|YES) ;; *) info "已取消。"; exit 0 ;; esac
  fi

  if [ "$existed" = "0" ]; then
    rm -f "$CONFIG_PATH"
    ok "已删除安装时新建的 config.toml"
  else
    [ -f "${dir}/config.toml" ] || die "备份损坏：缺少 ${dir}/config.toml"
    cp -p "${dir}/config.toml" "$CONFIG_PATH"
    ok "已恢复 ${CONFIG_PATH}"
  fi
  info "备份保留在 ${dir}，确认无误后可自行删除。"
}

MODE=""
BASE_URL=""
TOKEN="${PROXY_CLIENT_TOKEN:-}"
API_KEY="${OPENCODE_GO_API_KEY:-}"
CATALOG=""
ASSUME_YES=0
SKIP_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --catalog) CATALOG="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --skip-test) SKIP_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

if [ -z "$MODE" ]; then
  head1 "OpenCode Go × Codex 配置"
  info "  1. 使用远端 120 代理（推荐）"
  info "  2. 使用本机代理服务"
  info "  9. 恢复最近一次备份"
  read_tty MODE "输入 1 / 2 / 9: "
  case "$MODE" in
    1) MODE=remote ;;
    2) MODE=local ;;
    9) MODE=restore ;;
    *) die "无效选择。" ;;
  esac
fi

case "$MODE" in
  restore)
    restore_config
    exit 0
    ;;
  remote)
    BASE_URL="${BASE_URL:-$DEFAULT_REMOTE_BASE_URL}"
    if [ -z "$TOKEN" ]; then
      read_secret_tty TOKEN "请输入 remote client token: "
    fi
    [ -n "$TOKEN" ] || die "remote token 不能为空。"
    [ "$SKIP_TEST" -eq 0 ] && check_remote "$BASE_URL" "$TOKEN"
    CATALOG="$(resolve_catalog "$CATALOG")"
    backup_config remote "$BASE_URL"
    update_config "$BASE_URL" "$TOKEN" "$CATALOG"
    trust_hint "$BASE_URL"
    head1 "完成"
    info "  model          = $MODEL_SLUG"
    info "  model_provider = $PROVIDER_ID"
    info "  base_url       = $BASE_URL"
    info ""
    warn "请完全退出并重启 Codex，配置才会生效。"
    ;;
  local)
    BASE_URL="${BASE_URL:-$DEFAULT_LOCAL_BASE_URL}"
    if [ -z "$API_KEY" ]; then
      read_secret_tty API_KEY "请输入 OpenCode Go API key: "
    fi
    [ -n "$API_KEY" ] || die "API key 不能为空。"
    command -v systemctl >/dev/null 2>&1 || die "local 模式依赖 systemd；macOS/Windows 请使用 remote 模式。"

    if [ ! -x "${REPO_DIR}/opencode-go-proxy" ]; then
      if command -v docker >/dev/null 2>&1; then
        info "构建本地二进制（Docker）..."
        docker run --rm -v "${REPO_DIR}":/src -w /src golang:1.23-alpine \
          sh -c 'go build -trimpath -ldflags "-s -w" -o opencode-go-proxy .'
      elif command -v go >/dev/null 2>&1; then
        info "构建本地二进制（Go）..."
        (cd "$REPO_DIR" && go build -trimpath -ldflags '-s -w' -o opencode-go-proxy .)
      else
        die "没有可用的二进制，也没有 docker/go。请先构建 ${REPO_DIR}/opencode-go-proxy。"
      fi
    fi

    OPENCODE_GO_API_KEY="$API_KEY" PROXY_LISTEN="127.0.0.1:8787" \
      bash "${REPO_DIR}/deploy/install.sh"

    CATALOG="$(resolve_catalog "$CATALOG")"
    backup_config local "$BASE_URL"
    update_config "$BASE_URL" "proxy-managed" "$CATALOG"
    head1 "完成"
    info "  本地代理：http://127.0.0.1:8787"
    info "  Codex 配置：$BASE_URL"
    warn "请完全退出并重启 Codex，配置才会生效。"
    ;;
  *)
    die "未知 mode：$MODE（可选 remote/local/restore）"
    ;;
esac
