#!/usr/bin/env bats
# mcp_token_var (rootfs/lib.sh): the env var carrying an mcp_servers entry's
# token must be a valid identifier for every name run.sh accepts.

load 'test_helper'

@test "plain names keep the documented MCP_TOKEN_<name> form" {
  [ "$(mcp_token_var mem0)" = "MCP_TOKEN_mem0" ]
  [ "$(mcp_token_var my_server)" = "MCP_TOKEN_my_server" ]
}

@test "a hyphenated name maps to a valid identifier" {
  [ "$(mcp_token_var home-assistant)" = "MCP_TOKEN_home_assistant" ]
}

@test "export under set -e succeeds for a hyphenated name (boot no longer aborts)" {
  run bash -c 'set -e; . "$1"; v=$(mcp_token_var home-assistant); export "$v=tok"; printf "%s" "$MCP_TOKEN_home_assistant"' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "tok" ]
}

@test "the rc reference expands to the whole token, not a truncated name" {
  v=$(mcp_token_var home-assistant)
  export "$v=tok"
  line=$(printf '"Bearer $%s"' "$v")
  [ "$(eval "printf '%s' $line")" = "Bearer tok" ]
}

# ── collision detection: '-' and '_' both map to '_' ─────────────────────

@test "distinct names map to distinct variables and both claim" {
  mcp_token_claims_reset
  mcp_token_claim mem0
  mcp_token_claim home-assistant
}

@test "a-b and a_b collide on one variable: the second claim is rejected loudly" {
  mcp_token_claims_reset
  mcp_token_claim a-b
  run mcp_token_claim a_b
  [ "$status" -eq 1 ]
  [[ "$output" == *"MCP_TOKEN_a_b"* ]]
  [[ "$output" == *"'a_b'"* && "$output" == *"'a-b'"* ]]
}

@test "the collision is detected in either order" {
  mcp_token_claims_reset
  mcp_token_claim a_b
  ! mcp_token_claim a-b 2>/dev/null
}

@test "the same name claimed twice is not a collision" {
  mcp_token_claims_reset
  mcp_token_claim a-b
  mcp_token_claim a-b
}

@test "a reset forgets earlier claims" {
  mcp_token_claims_reset
  mcp_token_claim a-b
  mcp_token_claims_reset
  mcp_token_claim a_b
}
