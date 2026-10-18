#!/usr/bin/env bash
# OpenCode Go proxy setup for Codex (Linux / macOS / WSL).
#
# Interactive menu:
#   1 = configure Codex to use the hosted HTTPS proxy
#   2 = configure Codex to use a local proxy service
#   9 = restore the most recent config backup
#
# Non-interactive examples:
#   setup.sh --mode remote --base-url https://your-proxy-host:<port>/codex/v1 \
#            --token "$PROXY_CLIENT_TOKEN" --yes
#   setup.sh --mode local --api-key "$OPENCODE_GO_API_KEY" --yes
#   setup.sh --mode restore --yes
set -euo pipefail

SCRIPT_VERSION="1.0.0"
MODEL_SLUG="deepseek-v4.1-flash"
PROVIDER_ID="opencode-go"
DEFAULT_REMOTE_BASE_URL=""
DEFAULT_LOCAL_BASE_URL="http://127.0.0.1:8787/v1"
BACKUP_DIRNAME="backup-opencode-go-proxy"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
CONFIG_PATH="${CODEX_HOME_DIR}/config.toml"
BACKUP_ROOT="${CODEX_HOME_DIR}/${BACKUP_DIRNAME}"
CATALOG_TARGET="${CODEX_HOME_DIR}/models.opencode-go.json"
CATALOG_TARGET_EXISTED=0

# Small catalog for a fresh CODEX_HOME. It contains only the model metadata
# Codex needs (including multi_agent_version=v2), not the full Codex prompt.
BUNDLED_CATALOG_JSON='{
  "models": [
    {
      "slug": "deepseek-v4.1-flash",
      "prefer_websockets": false,
      "support_verbosity": true,
      "default_verbosity": "low",
      "apply_patch_tool_type": "freeform",
      "web_search_tool_type": "text",
      "input_modalities": ["text", "image"],
      "supports_image_detail_original": true,
      "truncation_policy": {"mode": "tokens", "limit": 10000},
      "supports_parallel_tool_calls": true,
      "tool_mode": null,
      "multi_agent_version": "v2",
      "use_responses_lite": false,
      "include_skills_usage_instructions": false,
      "auto_review_model_override": null,
      "context_window": 1048576,
      "max_context_window": 1048576,
      "effective_context_window_percent": 95,
      "auto_compact_token_limit": null,
      "comp_hash": "3000",
      "reasoning_summary_format": "experimental",
      "default_reasoning_summary": "none",
      "display_name": "deepseek-v4.1-flash",
      "description": "Local New API model (metadata: default)",
      "default_reasoning_level": "high",
      "supported_reasoning_levels": [
        {"effort": "low", "description": "Fast responses with lighter reasoning"},
        {"effort": "high", "description": "Extra high reasoning depth for complex problems"},
        {"effort": "max", "description": "Maximum reasoning depth for the hardest problems"}
      ],
      "shell_type": "shell_command",
      "visibility": "list",
      "minimal_client_version": "0.144.0",
      "supported_in_api": true,
      "availability_nux": null,
      "upgrade": null,
      "priority": 1,
      "experimental_supported_tools": [],
      "supports_search_tool": true,
      "default_service_tier": null,
      "supports_reasoning_summaries": true,
      "model_messages": {
        "instructions_template": "You are Codex, an AI coding agent. Follow the user instructions and use the provided tools carefully."
      }
    }
  ]
}'

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
  --ca-cert PATH       CA certificate to save for a self-signed HTTPS endpoint
  --install-catalog    install/refresh the bundled minimal catalog
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

prepare_catalog() {
  if [ -f "$CATALOG_TARGET" ]; then
    CATALOG_TARGET_EXISTED=1
  else
    CATALOG_TARGET_EXISTED=0
  fi
}

resolve_catalog() {
  local requested="$1" bundled="$CATALOG_TARGET"
  local local_asset="${REPO_DIR}/assets/models.deepseek-v4.1-flash.json" payload=""
  if [ -n "$requested" ]; then
    [ -f "$requested" ] || die "model catalog not found: $requested"
    (cd "$(dirname "$requested")" && printf '%s/%s' "$PWD" "$(basename "$requested")")
    return 0
  fi
  if [ "$INSTALL_BUNDLED_CATALOG" -eq 0 ]; then
    if [ -f "${CODEX_HOME_DIR}/models.newapi.json" ]; then
      printf '%s' "${CODEX_HOME_DIR}/models.newapi.json"
      return 0
    elif [ -f "${CODEX_HOME_DIR}/models.json" ]; then
      printf '%s' "${CODEX_HOME_DIR}/models.json"
      return 0
    elif [ -f "$bundled" ]; then
      printf '%s' "$bundled"
      return 0
    fi
  fi

  if [ -f "$local_asset" ]; then
    payload="$(cat "$local_asset")"
  else
    payload="$BUNDLED_CATALOG_JSON"
  fi
  if [ -n "$payload" ]; then
    mkdir -p "$CODEX_HOME_DIR"
    if [ -f "$bundled" ]; then
      cp -p "$bundled" "${bundled}.bak-$(date '+%Y%m%d-%H%M%S')"
    fi
    printf '%s\n' "$payload" > "$bundled"
    chmod 600 "$bundled"
    printf '%s' "$bundled"
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
  if [ "$CATALOG_TARGET_EXISTED" = "1" ] && [ -f "$CATALOG_TARGET" ]; then
    cp -p "$CATALOG_TARGET" "${dir}/catalog.json" || die "备份模型目录失败"
  fi
  {
    printf 'script_version=%s\n' "$SCRIPT_VERSION"
    printf 'installed_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'mode=%s\n' "$mode"
    printf 'base_url=%s\n' "$base_url"
    printf 'original_config_existed=%s\n' "$existed"
    printf 'catalog_target_existed=%s\n' "$CATALOG_TARGET_EXISTED"
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
    404|405) die "远端路径可能错误（HTTP $code）；请检查 base_url 是否包含正确的 /codex/v1 前缀。" ;;
    000|'') die "远端连接失败；请检查网络、TLS 证书（自签证书用 --ca-cert）或使用 --skip-test 跳过检查。" ;;
    2*) ok "远端鉴权通过（HTTP $code）" ;;
    4*|5*) ok "远端鉴权通过（HTTP $code，空探测请求被上游拒绝属正常）" ;;
    *) warn "远端返回了未预期的 HTTP $code" ;;
  esac
}

handle_ca_cert() {
  [ -n "$CA_CERT" ] || return 0
  [ -f "$CA_CERT" ] || die "CA certificate not found: $CA_CERT"
  local cert_dst="${HOME}/.config/opencode-go-proxy/ca.crt"
  mkdir -p "$(dirname "$cert_dst")"
  cp -p "$CA_CERT" "$cert_dst"
  chmod 644 "$cert_dst"
  info "${C_DIM}CA 证书已保存到 ${cert_dst}${C_RST}"
  info "  Debian/Ubuntu: sudo cp ${cert_dst} /usr/local/share/ca-certificates/opencode-go-proxy.crt && sudo update-ca-certificates"
  info "  Fedora/RHEL: sudo cp ${cert_dst} /etc/pki/ca-trust/source/anchors/opencode-go-proxy.crt && sudo update-ca-trust"
  info "  macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${cert_dst}"
  info "  Windows: 使用 scripts/setup.ps1 --ca-cert <证书路径>"
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
    head1 "选择要恢复的备份（original = 首次安装前）"
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
  local catalog_existed=""
  if [ -f "${dir}/manifest.txt" ]; then
    existed="$(sed -n 's/^original_config_existed=//p' "${dir}/manifest.txt" | head -1)"
    catalog_existed="$(sed -n 's/^catalog_target_existed=//p' "${dir}/manifest.txt" | head -1)"
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
  if [ -n "$catalog_existed" ]; then
    if [ "$catalog_existed" = "1" ] && [ -f "${dir}/catalog.json" ]; then
      mkdir -p "$(dirname "$CATALOG_TARGET")"
      cp -p "${dir}/catalog.json" "$CATALOG_TARGET"
      ok "已恢复 ${CATALOG_TARGET}"
    elif [ "$catalog_existed" = "0" ]; then
      rm -f "$CATALOG_TARGET"
      ok "已移除安装时创建的 ${CATALOG_TARGET}"
    fi
  fi
  info "备份保留在 ${dir}，确认无误后可自行删除。"
}

MODE=""
BASE_URL=""
TOKEN="${PROXY_CLIENT_TOKEN:-}"
API_KEY="${OPENCODE_GO_API_KEY:-}"
TOKEN_FROM_ARG=0
API_KEY_FROM_ARG=0
CATALOG=""
CA_CERT="${PROXY_CA_CERT:-}"
INSTALL_BUNDLED_CATALOG=0
ASSUME_YES=0
SKIP_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; TOKEN_FROM_ARG=1; shift 2 ;;
    --api-key) API_KEY="${2:-}"; API_KEY_FROM_ARG=1; shift 2 ;;
    --catalog) CATALOG="${2:-}"; shift 2 ;;
    --ca-cert) CA_CERT="${2:-}"; shift 2 ;;
    --install-catalog) INSTALL_BUNDLED_CATALOG=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --skip-test) SKIP_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

if [ -z "$MODE" ]; then
  head1 "OpenCode Go × Codex 配置"
  info "  1. 使用远端代理（推荐）"
  info "  2. 使用本机二进制代理（可选，非 Docker）"
  info "  9. 恢复首次安装前备份（original）"
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
    if [ -z "$BASE_URL" ]; then
      read_tty BASE_URL "请输入远端 proxy base URL（例如 https://your-host:<port>/codex/v1）: "
    fi
    [ -n "$BASE_URL" ] || die "remote base URL 不能为空。"
    if [ -z "$TOKEN" ]; then
      read_secret_tty TOKEN "请输入 remote client token: "
    fi
    [ -n "$TOKEN" ] || die "remote token 不能为空。"
    if [ "$TOKEN_FROM_ARG" -eq 1 ]; then
      warn "--token 会出现在进程列表中，建议改用 PROXY_CLIENT_TOKEN 环境变量。"
    fi
    handle_ca_cert
    [ "$SKIP_TEST" -eq 0 ] && check_remote "$BASE_URL" "$TOKEN"
    prepare_catalog
    CATALOG="$(resolve_catalog "$CATALOG")"
    backup_config remote "$BASE_URL"
    update_config "$BASE_URL" "$TOKEN" "$CATALOG"
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
    if [ "$API_KEY_FROM_ARG" -eq 1 ]; then
      warn "--api-key 会出现在进程列表中，建议改用 OPENCODE_GO_API_KEY 环境变量。"
    fi
    command -v systemctl >/dev/null 2>&1 || die "local 模式依赖 systemd；macOS/Windows 请使用 remote 模式。"

    if [ ! -x "${REPO_DIR}/opencode-go-proxy" ]; then
      if command -v docker >/dev/null 2>&1; then
        info "构建本地二进制（Docker）..."
        docker run --rm -v "${REPO_DIR}":/src -w /src golang:1.26-alpine \
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

    prepare_catalog
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
