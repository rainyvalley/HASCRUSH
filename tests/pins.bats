#!/usr/bin/env bats
# The pinned downloads (Crush, ttyd, HA CLI, Alpine base) are refreshed by
# update-pins.yml. These pin the wiring so a future edit cannot silently drop
# one of the pins from the sweep.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
W="$REPO/.github/workflows/update-pins.yml"
S="$REPO/.github/scripts/update_pins.py"

@test "update-pins runs weekly and on demand, and validates what it pushes" {
  [ -f "$W" ]
  grep -qF 'schedule:' "$W"
  grep -qF 'workflow_dispatch' "$W"
  grep -qF 'update_pins.py' "$W"
  grep -qF 'bump_version.py' "$W"
  # a workflow-token push triggers nothing, so CI is dispatched explicitly
  grep -qF 'gh workflow run ci.yml' "$W"
}

@test "the pin updater covers crush, ttyd, the ha CLI and the alpine base" {
  [ -f "$S" ]
  grep -qF 'charmbracelet/crush' "$S"
  grep -qF 'tsl0922/ttyd' "$S"
  grep -qF 'home-assistant/cli' "$S"
  grep -qF 'amd64-base' "$S"
  grep -qF 'aarch64-base' "$S"
}

@test "the version bump is shared by both build workflows" {
  grep -qF 'bump_version.py' "$REPO/.github/workflows/version-bump.yml"
  grep -qF 'bump_version.py' "$W"
}
