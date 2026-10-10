#!/usr/bin/env bats
# safe_url / safe_text / val_check: the charsets that guard every value the
# boot writes into the bash-executed crushrc (code execution = as root).

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

@test "safe_url passes http/https URLs with URL-safe chars" {
  for u in \
    "http://192.168.1.10:11434/v1" \
    "https://ollama.com/v1" \
    "https://host.example/user/p%20ath?q" \
    "http://localhost/mcp?tok.123abc"; do
    safe_url "$u"
  done
}

@test "safe_url rejects non-http(s) schemes and shell-dangerous chars" {
  for u in \
    "ftp://host/file" \
    "javascript:alert(1)" \
    "/data/options.json" \
    "http://h/a&b" \
    "http://h/a=b" \
    "http://h/\`id\`" \
    'http://h/$(id)' \
    'http://h/a"b' \
    'http://h/a$b' \
    'http://h/a\b' \
    'http://h/a b' \
    "http://h/a'b"; do
    if safe_url "$u"; then fail "accepted: $u"; fi
  done
}

@test "safe_text passes command/args/model-id style values" {
  for v in \
    "qwen3-vl:4b-instruct" \
    "TCP:192.0.2.252:3010" \
    "socat" \
    "STDIO" \
    "GLM 5.3 Flash" \
    "ollama-cloud/glm-5.3-flash"; do
    safe_text "$v"
  done
}

@test "safe_text rejects shell metachars (parens, backticks, quotes, semicolons, \$)" {
  for v in \
    'v$(id)' \
    'v`id`' \
    "v'x" \
    'v"x' \
    'v;x' \
    'v|x' \
    'v&x' \
    'v{ ' \
    'v>x'; do
    if safe_text "$v"; then fail "accepted: $v"; fi
  done
}

@test "val_check: empty value passes regardless of validator" {
  run val_check "" safe_url "ignored"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "val_check: non-empty passing value passes silently" {
  run val_check "http://x:11434" safe_url "ignored"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "val_check: non-empty failing value warns and returns 1" {
  run val_check "ftp://x" safe_url "crush_config_url failed charset validation - ignored"
  [ "$status" -eq 1 ]
  [[ "$output" == *"crush_config_url failed charset validation"* ]]
}