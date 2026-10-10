#!/usr/bin/env bats
# mcp_remove: regression for the multi-line / newline-less / indented-head
# delete traps (see the function's comments in rootfs/lib.sh).

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

@test "mcp_remove drops a single-line entry and keeps the rest" {
  printf '# header\nmcp add mem0 --type http --url "http://x"\nmodel large glm\n' > "$crushrc"
  mcp_remove mem0
  ! grep -qF 'mem0' "$crushrc"
  grep -qF '# header' "$crushrc"
  grep -qxF 'model large glm' "$crushrc"
}

@test "mcp_remove removes a backslash-continued multi-line entry in full (no orphan continuations)" {
  printf 'provider add ollama-cloud --type openai-compat --base-url "u"\n' \
    > "$crushrc"
  printf 'mcp add openscad --type stdio \\\n  --args socat TCP:192.0.2.1:8000 \\\n  --timeout 20\n' >> "$crushrc"
  printf 'model large glm\n' >> "$crushrc"
  mcp_remove openscad
  ! grep -qE 'openscad|--args|--timeout|TCP:192' "$crushrc"
  grep -qF 'provider add ollama-cloud' "$crushrc"
  grep -qxF 'model large glm' "$crushrc"
}

@test "mcp_remove only removes the named server (other entries untouched, idempotent)" {
  printf 'mcp add mem0 --type http --url "http://m"\nmcp add other --type http --url "http://o"\nmcp add mem0 --type http --url "http://m"\n' > "$crushrc"
  mcp_remove mem0
  mcp_remove mem0   # second pass: no error, no change
  [[ "$(grep -cF 'mcp add mem0' "$crushrc")" -eq 0 ]]
  [[ "$(grep -cF 'mcp add other' "$crushrc")" -eq 1 ]]
}

@test "mcp_remove keeps a newline-less final line (the 'fi' read-guard regression)" {
  # pre-1.0.26 the while-read dropped a final line with no trailing newline,
  # eating the central template's closing `fi`
  printf 'mcp add mem0 --type http --url "http://m"\nmodel large glm\nfi' > "$crushrc"
  mcp_remove mem0
  # the final line must survive at all (pre-1.0.26 it was dropped); the
  # rewrite re-emits lines one per line, so the trailing \n is normalized
  [[ "$(tail -n 1 "$crushrc")" == 'fi' ]]
  grep -qxF 'model large glm' "$crushrc"
}

@test "mcp_remove removes a newline-less final entry line entirely" {
  printf 'model large glm\nmcp add mem0 --type http --url "http://m"' > "$crushrc"
  mcp_remove mem0
  [[ "$(cat "$crushrc")" == 'model large glm' ]]
  ! grep -qF 'mem0' "$crushrc"
}

@test "mcp_remove removes an indented (template) entry and preserves neighbors' indentation" {
  cat > "$crushrc" <<'EOF'
if [ -n "$LOCAL_OLLAMA_URL" ]; then
  mcp add ollama --type ollama \
    --base-url "http://x:11434" \
    --args socat TCP:10.0.0.1:1 \
    --timeout 5
  provider add ollama-local --type ollama --base-url "http://x:11434"
fi
EOF
  mcp_remove ollama
  ! grep -qE 'mcp add|--args|--timeout|--base-url' "$crushrc"
  # the OTHER indented entry keeps its leading spaces - a raw-line match
  # used to eat or miss indented entries
  grep -qxF '  provider add ollama-local --type ollama --base-url "http://x:11434"' "$crushrc"
  grep -qxF 'fi' "$crushrc"
}

@test "mcp_remove tolerates CRLF-persisted entries" {
  printf 'mcp add mem0 --type http --url "http://m"\r\nmodel large glm\r\n' > "$crushrc"
  mcp_remove mem0
  ! grep -qF 'mem0' "$crushrc"
  grep -qF 'model large glm' "$crushrc"
}