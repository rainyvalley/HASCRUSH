#!/usr/bin/env bats
# mcp_sanitize: repair of pre-1.0.14 single-line-delete damage + the
# newline-less / indented-head / CRLF matching regressions.

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

@test "mcp_sanitize drops orphaned --args fragments that lost their mcp add head" {
  # what a pre-1.0.14 single-line delete left behind
  printf 'model large glm\n  --args socat TCP:192.0.2.1:1\nprovider add ollama-cloud --type openai-compat\n' > "$crushrc"
  run mcp_sanitize
  ! grep -q -- '--args' "$crushrc"
  grep -qxF 'model large glm' "$crushrc"
  grep -qF 'provider add ollama-cloud' "$crushrc"
  [[ "$output" == *"removed orphaned mcp flag fragment"* ]]
}

@test "mcp_sanitize joins an editor-wrapped token inside an open mcp add chain" {
  # the wrap point carried a continuation backslash (TCP:192. \), so the bare
  # value on the next line is a seamlessly-wrapped token, not a new command
  cat > "$crushrc" <<'EOF'
mcp add mem0 --type http --url "http://m:8300/mcp" \
  --args TCP:192.0.\
2.252:3010
model large glm
EOF
  mcp_sanitize
  diff -u "$crushrc" - <<'EOF'
mcp add mem0 --type http --url "http://m:8300/mcp" \
  --args TCP:192.0.2.252:3010
model large glm
EOF
}

@test "mcp_sanitize keeps mcp-exclusive fragments of an OPEN multi-line entry" {
  printf 'mcp add openscad --type stdio \\\n  --args socat TCP:192.0.2.1:8000 \\\n  --timeout 20\nmodel large glm\n' > "$crushrc"
  mcp_sanitize
  grep -qF -- '--args socat TCP:192.0.2.1:8000' "$crushrc"
  grep -qF -- '--timeout 20' "$crushrc"
  grep -qF 'mcp add openscad' "$crushrc"
}

@test "mcp_sanitize preserves a newline-less final line (the 'fi' read-guard regression)" {
  printf 'model large glm\nfi' > "$crushrc"
  mcp_sanitize
  # rewrite re-emits one line per line, so the trailing \n is normalized;
  # the regression is the LINE surviving
  [[ "$(tail -n 1 "$crushrc")" == 'fi' ]]
}

@test "mcp_sanitize keeps an indented head + fragments (regression: indented head eaten as orphan)" {
  cat > "$crushrc" <<'EOF'
if [ -n "$LOCAL_OLLAMA_URL" ]; then
  mcp add ollama --type ollama --base-url "http://x:11434" \
    --args socat TCP:192.0.2.1:1 \
    --timeout 5
fi
EOF
  mcp_sanitize
  grep -qF '  mcp add ollama --type ollama --base-url "http://x:11434" \' "$crushrc"
  grep -qF '    --args socat TCP:192.0.2.1:1' "$crushrc"
  grep -qF '    --timeout 5' "$crushrc"
  grep -qxF 'fi' "$crushrc"
}

@test "mcp_sanitize repairs a REAL pre-1.0.14 damaged rc (head gone, 1 continuation line orphaned)" {
  printf 'model large glm\n  --args socat TCP:192.0.2.1:8000 \\\n  --timeout 20\nfi\n' > "$crushrc"
  mcp_sanitize
  ! grep -qE -- '--args|--timeout' "$crushrc"
  grep -qxF 'model large glm' "$crushrc"
  grep -qxF 'fi' "$crushrc"
}

@test "mcp_sanitize handles CRLF-persisted rcs" {
  printf 'mcp add mem0 --type http --url "http://m"\r\nmodel large glm\r\n' > "$crushrc"
  mcp_sanitize
  grep -qF 'mcp add mem0' "$crushrc"   # head survives, \r stripped
  grep -qF 'model large glm' "$crushrc"
}