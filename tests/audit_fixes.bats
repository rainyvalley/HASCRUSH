#!/usr/bin/env bats
# Regression tests for the 2026-10 audit fixes (lib.sh helpers + manifest).

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# ── env file: values and names ───────────────────────────────────────────
envclean() { printf '%s\n' "$1" > "$TMP/raw"; BAD=$(env_file_clean "$TMP/raw" "$TMP/kept"); }

@test "env file keeps values with =, comma, ?, spaces in double quotes and single-quoted JSON" {
  envclean "OLLAMA_API_KEY=abc=def
CRUSH_CONFIG_URL=http://h.invalid/x?a=b
CRUSH_X=\"a b\"
THIRD_PARTY_API_KEY=a,b
MCP_SERVERS='[{\"name\":\"a\",\"url\":\"http://h.invalid/mcp\"}]'"
  [ -z "$BAD" ]
  [ "$(wc -l < "$TMP/kept")" -eq 5 ]
}

@test "env file skips LD_PRELOAD, BASH_ENV, PATH, IFS, SUPERVISOR_TOKEN, HA_URL by name" {
  envclean "LD_PRELOAD=/x/y.so
BASH_ENV=/x/y.sh
PATH=/x/bin
export IFS=x
SUPERVISOR_TOKEN=abc
HA_URL=http://h.invalid
OLLAMA_API_KEY=ok"
  [ "$(cat "$TMP/kept")" = "OLLAMA_API_KEY=ok" ]
  [[ "$BAD" == *"LD_PRELOAD=<masked>"* ]]
  [[ "$BAD" == *"BASH_ENV=<masked>"* ]]
  [[ "$BAD" == *"PATH=<masked>"* ]]
  [[ "$BAD" == *"SUPERVISOR_TOKEN=<masked>"* ]]
}

@test "env file: a name that only starts with 'export' is not treated as export" {
  envclean "exportPATH=/x"
  [ ! -s "$TMP/kept" ]
}

@test "env file: rejected values and bare pasted keys never reach the report" {
  envclean "OLLAMA_API_KEY=sk-secretvalue;id
justapastedsecretkey1234567890"
  [ ! -s "$TMP/kept" ]
  [[ "$BAD" != *secretvalue* ]]
  [[ "$BAD" != *justapasted* ]]
  [[ "$BAD" == *"no \"=\""* ]]
}

@test "env file: code in a single-quoted-looking or unquoted value stays rejected" {
  envclean "CRUSH_A='x'\$(id)
CRUSH_B=a;id
CRUSH_C=\`id\`
CRUSH_D='it's'
CRUSH_E=a&b"
  [ ! -s "$TMP/kept" ]
}

@test "env file: kept file sources cleanly and a single-quoted value stays literal" {
  envclean "MCP_SERVERS='[{\"n\":\"\$(id)\"}]'"
  . "$TMP/kept"
  [ "$MCP_SERVERS" = '[{"n":"$(id)"}]' ]
}

# ── redact_url ───────────────────────────────────────────────────────────
@test "redact_url drops userinfo, query and fragment" {
  [ "$(redact_url 'https://u:p@host.example.com:8443/a/b?key=v#f')" = 'https://host.example.com:8443/a/b?<hidden>' ]
  [ "$(redact_url 'http://h.invalid/x/y')" = 'http://h.invalid/x/y' ]
  [ "$(redact_url 'http://tok@h.invalid')" = 'http://h.invalid' ]
}

# ── curl_guard ───────────────────────────────────────────────────────────
@test "curl_guard: https stays https on redirects; http may go to http or https; max 2 hops" {
  curl_guard https://h.invalid/x
  [[ " ${CURL_GUARD[*]} " == *" --proto-redir =https "* ]]
  [[ " ${CURL_GUARD[*]} " == *" --max-redirs 2 "* ]]
  curl_guard http://h.invalid/x
  [[ " ${CURL_GUARD[*]} " == *" --proto-redir =http,https "* ]]
}

@test "run.sh sends X-Disti-Token only on fetches that do not follow redirects" {
  # DISTI_LOC is empty when a token is set; both secret fetches use it
  grep -q 'DISTI_LOC=()' "$REPO/charm-crush/rootfs/run.sh"
  [ "$(grep -c 'DISTI_LOC\[@\]' "$REPO/charm-crush/rootfs/run.sh")" -eq 2 ]
  ! grep -E 'curl -fsSL[^|]*DISTI_CURL' "$REPO/charm-crush/rootfs/run.sh"
}

# ── mcp stdio args ───────────────────────────────────────────────────────
@test "mcp_arg_fragment quotes each arg so a space stays one argument" {
  [ "$(mcp_arg_fragment 'x y')" = ' --args "x y"' ]
  [ "$(mcp_arg_fragment 'TCP:h.invalid:1')" = ' --args "TCP:h.invalid:1"' ]
}

@test "mcp_arg_fragment rejects empty and unsafe args" {
  run mcp_arg_fragment ''
  [ "$status" -ne 0 ]
  run mcp_arg_fragment 'a$(id)'
  [ "$status" -ne 0 ]
  run mcp_arg_fragment 'a"b'
  [ "$status" -ne 0 ]
}

# ── reasoning effort: daily slot only ────────────────────────────────────
@test "apply_reasoning_effort large leaves the small slot alone" {
  cat > "$crushrc" <<'RC'
model large ollama-cloud/m --reasoning-effort high
model small ollama-cloud/m --reasoning-effort high
RC
  apply_reasoning_effort large max
  grep -qx 'model large ollama-cloud/m --reasoning-effort max' "$crushrc"
  grep -qx 'model small ollama-cloud/m --reasoning-effort high' "$crushrc"
  apply_reasoning_effort large low
  [ "$(grep -c -- '--reasoning-effort' "$crushrc")" -eq 2 ]
  grep -qx 'model large ollama-cloud/m --reasoning-effort low' "$crushrc"
}

# ── discovery toggle ─────────────────────────────────────────────────────
fallback_rc() {
  cat > "$crushrc" <<'RC'
# Built-in fallback crushrc (add-on).
provider add ollama-cloud --type openai-compat --base-url "https://ollama.com/v1" --api-key "$OLLAMA_API_KEY" --discover-models true
provider add ollama-local --type ollama --base-url "$LOCAL_OLLAMA_URL" --discover-models true
RC
}

@test "discover_models_apply false then true restores true" {
  fallback_rc
  discover_models_apply false
  [ "$(grep -c -- '--discover-models false' "$crushrc")" -eq 2 ]
  discover_models_apply true
  [ "$(grep -c -- '--discover-models true' "$crushrc")" -eq 2 ]
  ! grep -q -- '--discover-models false' "$crushrc"
}

@test "discover_models_apply true adds the flag to a legacy rc that has none" {
  cat > "$crushrc" <<'RC'
# Built-in fallback crushrc (add-on).
provider add ollama-cloud --type openai-compat --base-url "https://ollama.com/v1" --api-key "$OLLAMA_API_KEY"
RC
  discover_models_apply true
  grep -q -- '--api-key "$OLLAMA_API_KEY" --discover-models true$' "$crushrc"
}

# ── manifest / image ─────────────────────────────────────────────────────
@test "secret options use the password type" {
  for k in third_party_api_key disti_token ollama_api_key; do
    grep -qE "^  $k: password\?$" "$REPO/charm-crush/config.yaml"
  done
}

@test "healthcheck gate test cannot match its own command line" {
  # `pgrep -f 'TCP4-LISTEN:7681'` matched the healthcheck's own sh -c; the
  # pattern must be anchored at the start of the socat command line
  grep -q "pgrep -f '^socat TCP4-LISTEN:7681'" "$REPO/charm-crush/Dockerfile"
}

@test "local_ollama_url is read from options.json and validated before use" {
  grep -q "jq -r '.local_ollama_url" "$REPO/charm-crush/rootfs/run.sh"
  grep -q 'safe_url "local_ollama_url\|val_check "$LOCAL_OLLAMA_URL" safe_url' "$REPO/charm-crush/rootfs/run.sh"
}

@test "run.sh removes an mcp server's old line only after validation" {
  # no mcp_remove between the entry parse and the write points
  first=$(grep -n 'mcp_remove "\$MCP_NAME"' "$REPO/charm-crush/rootfs/run.sh" | head -1 | cut -d: -f1)
  validated=$(grep -n 'neither url nor command set' "$REPO/charm-crush/rootfs/run.sh" | head -1 | cut -d: -f1)
  [ "$first" -gt "$validated" ]
}

# ── model ids are one word ───────────────────────────────────────────────
@test "safe_model_id rejects spaces and flag injection, keeps real ids" {
  safe_model_id 'ollama-cloud/gemma4:31b'
  safe_model_id 'openai-compat-3p/meta-llama/llama-3.1-8b:free'
  ! safe_model_id 'x --base-url http://h.invalid'
  ! safe_model_id ''
}

@test "apply_model_slot refuses an id with a space and leaves the slot alone" {
  printf 'model large ollama-cloud/a\n' > "$crushrc"
  apply_model_slot large 'b --base-url http://h.invalid' 2>/dev/null
  grep -qx 'model large ollama-cloud/a' "$crushrc"
}
