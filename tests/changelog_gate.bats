#!/usr/bin/env bats
# .github/scripts/check_changelog.sh: the CHANGELOG must carry [Unreleased]
# and a section for the config.yaml version. Local files only.

ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
GATE="$ROOT/.github/scripts/check_changelog.sh"

setup() {
  TMP="$(mktemp -d)"
  printf 'name: x\nversion: "1.2.3"\n' > "$TMP/config.yaml"
}
teardown() { rm -rf "$TMP"; }

@test "the real changelog passes against the real config.yaml" {
  cd "$ROOT"
  run "$GATE"
  [ "$status" -eq 0 ]
}

@test "passes with Unreleased and a dated section for the version" {
  printf '## [Unreleased]\n\n## [1.2.3] - 2026-01-02\n\n## [1.2.2] - 2026-01-01\n' > "$TMP/CHANGELOG.md"
  run "$GATE" "$TMP/config.yaml" "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ]
}

@test "fails when the config version has no section" {
  printf '## [Unreleased]\n\n## [1.2.2] - 2026-01-01\n' > "$TMP/CHANGELOG.md"
  run "$GATE" "$TMP/config.yaml" "$TMP/CHANGELOG.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *'## [1.2.3]'* ]]
}

@test "fails when Unreleased is missing" {
  printf '## [1.2.3] - 2026-01-02\n' > "$TMP/CHANGELOG.md"
  run "$GATE" "$TMP/config.yaml" "$TMP/CHANGELOG.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Unreleased'* ]]
}

@test "a similar version does not satisfy the gate (1.2.30 vs 1.2.3)" {
  printf '## [Unreleased]\n\n## [1.2.30] - 2026-01-02\n' > "$TMP/CHANGELOG.md"
  run "$GATE" "$TMP/config.yaml" "$TMP/CHANGELOG.md"
  [ "$status" -eq 1 ]
}
