#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${ROOT_DIR}/scripts/setup.sh"
TMP_DIR="$(mktemp -d /tmp/opencode-setup-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export CODEX_HOME="${TMP_DIR}/.codex"
mkdir -p "${CODEX_HOME}"

cat > "${CODEX_HOME}/config.toml" <<'ORIGINAL'
model = "gpt-5"
model_provider = "openai"

[tui]
screen_reader_detection_done = true

[projects."/tmp/example"]
trust_level = "trusted"
ORIGINAL

printf '{"models":[]}\n' > "${CODEX_HOME}/models.json"
cp "${CODEX_HOME}/config.toml" "${TMP_DIR}/original.toml"

bash "${SETUP}" --mode remote \
  --base-url "https://example.test/codex/v1" \
  --token "test-client-token" \
  --skip-test --yes >/tmp/opencode-setup-test.log

grep -q '^model = "deepseek-v4.1-flash"$' "${CODEX_HOME}/config.toml"
grep -q '^model_provider = "opencode-go"$' "${CODEX_HOME}/config.toml"
grep -q '^\[model_providers\.opencode-go\]$' "${CODEX_HOME}/config.toml"
grep -q '^base_url = "https://example.test/codex/v1"$' "${CODEX_HOME}/config.toml"
grep -q '^experimental_bearer_token = "test-client-token"$' "${CODEX_HOME}/config.toml"
grep -q "^model_catalog_json = \"${CODEX_HOME}/models.json\"$" "${CODEX_HOME}/config.toml"
grep -q '^\[tui\]$' "${CODEX_HOME}/config.toml"
grep -q '^\[projects\."/tmp/example"\]$' "${CODEX_HOME}/config.toml"

bash "${SETUP}" --mode remote \
  --base-url "https://example.test/second/v1" \
  --token "second-token" \
  --skip-test --yes >/tmp/opencode-setup-test-second.log

count="$(grep -c '^\[model_providers\.opencode-go\]$' "${CODEX_HOME}/config.toml")"
[ "${count}" = "1" ] || { echo "provider block duplicated: ${count}" >&2; exit 1; }
grep -q '^base_url = "https://example.test/second/v1"$' "${CODEX_HOME}/config.toml"

bash "${SETUP}" --mode restore --yes >/tmp/opencode-setup-test-restore.log
cmp -s "${CODEX_HOME}/config.toml" "${TMP_DIR}/original.toml"

echo "setup.sh tests passed"
