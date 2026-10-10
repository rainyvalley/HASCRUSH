#!/usr/bin/env bats
# inject_limits: CRUSH.md marker/heading logic. LIMITS_BODY here is a small
# stand-in; only the markers steer the logic (run.sh defines the real body).

load 'test_helper'
setup() {
  setup_tmp
  LIMITS_START='<!-- hasscrush-limits-start -->'
  LIMITS_END='<!-- hasscrush-limits-end -->'
  LIMITS_BODY="$LIMITS_START
## Hard Limits (stand-in body)
no retries
$LIMITS_END"
}
teardown() { teardown_tmp; }

@test "inject_limits appends the block to a marker-less, heading-less CRUSH.md" {
  CRUSH_MD="$TMP/CRUSH.md"
  printf '# Crush - Home Assistant Add-on\nplain intro\n' > "$CRUSH_MD"
  inject_limits
  grep -qF "$LIMITS_START" "$CRUSH_MD"
  grep -qF "$LIMITS_END" "$CRUSH_MD"
  grep -qF 'plain intro' "$CRUSH_MD"
  [[ "$(tail -1 "$CRUSH_MD")" == "$LIMITS_END" ]]
}

@test "inject_limits inserts the block BEFORE the user's first '##' heading" {
  CRUSH_MD="$TMP/CRUSH.md"
  printf 'user intro\n## My notes\ncustom content\n' > "$CRUSH_MD"
  inject_limits
  # intro first, block in the middle, user content after
  [[ "$(sed -n '1p' "$CRUSH_MD")" == 'user intro' ]]
  grep -qF "$LIMITS_START" "$CRUSH_MD"
  [[ "$(grep -n '^## My notes$' "$CRUSH_MD" | cut -d: -f1)" -gt "$(grep -nF "$LIMITS_START" "$CRUSH_MD" | cut -d: -f1)" ]]
  [[ "$(tail -1 "$CRUSH_MD")" == 'custom content' ]]
}

@test "inject_limits is a no-op when BOTH markers are present (user edits kept)" {
  CRUSH_MD="$TMP/CRUSH.md"
  printf "$LIMITS_START
user-edited guardrails
$LIMITS_END\n" > "$CRUSH_MD"
  before="$(cat "$CRUSH_MD")"
  inject_limits
  [[ "$(cat "$CRUSH_MD")" == "$before" ]]
}

@test "inject_limits re-injects when only the START marker is present (truncation/planting trap)" {
  CRUSH_MD="$TMP/CRUSH.md"
  printf "$LIMITS_START\ndangling block, end marker lost\n" > "$CRUSH_MD"
  inject_limits
  grep -qF "$LIMITS_END" "$CRUSH_MD"
}