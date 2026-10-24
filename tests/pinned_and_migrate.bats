#!/usr/bin/env bats
# Pinned hashes, no-downgrade check, and the one-time data move.

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUN="$REPO/charm-crush/rootfs/run.sh"

@test "is_sha256 accepts 64 hex only" {
  is_sha256 "$(printf 'a%.0s' {1..64})"
  is_sha256 "$(printf 'A%.0s' {1..64})"
  ! is_sha256 "$(printf 'a%.0s' {1..63})"
  ! is_sha256 "$(printf 'g%.0s' {1..64})"
  ! is_sha256 ""
}

@test "sha256_matches: right hash passes, wrong, empty and malformed fail" {
  printf 'hello\n' > "$TMP/f"
  good=$(sha256sum "$TMP/f" | cut -d' ' -f1)
  sha256_matches "$TMP/f" "$good"
  sha256_matches "$TMP/f" "$(printf '%s' "$good" | tr a-f A-F)"
  ! sha256_matches "$TMP/f" "$(printf '0%.0s' {1..64})"
  ! sha256_matches "$TMP/f" ""
  ! sha256_matches "$TMP/f" "${good:0:63}"
}

@test "version_gt: newer passes; equal, older, junk and empty refuse" {
  version_gt 0.98.0 0.97.1
  version_gt 1.10.0 1.9.9
  version_gt 0.97.2 0.97
  ! version_gt 0.97.1 0.97.1
  ! version_gt 0.96.9 0.97.1
  ! version_gt 0.97 0.97.0
  ! version_gt "" 0.97.1
  ! version_gt 0.98.0 ""
  ! version_gt 0.98.0-rc1 0.97.1
}

@test "run.sh gates the central config on the pin and on https" {
  grep -q 'sha256_matches /tmp/crushrc.new "\$CONFIG_SHA"' "$RUN"
  grep -q 'crush_config_allow_http' "$RUN"
  # the hash check comes before the content check and before the file is moved into place
  h=$(grep -n 'sha256_matches /tmp/crushrc.new' "$RUN" | head -1 | cut -d: -f1)
  g=$(grep -n "grep -qE '(provider|model) (add|large|small)" "$RUN" | head -1 | cut -d: -f1)
  m=$(grep -n 'mv -f "\$crushrc.new" "\$crushrc"' "$RUN" | head -1 | cut -d: -f1)
  [ "$h" -lt "$g" ]; [ "$g" -lt "$m" ]
}

@test "run.sh auto-update needs a pin, refuses downgrades and no longer asks GitHub for 'latest'" {
  grep -q 'version_gt "\$NEW_VER" "\$BUILT_NUM"' "$RUN"
  grep -q 'sha256_matches /tmp/crush.upd "\$UPD_SHA"' "$RUN"
  ! grep -q 'releases/latest' "$RUN"
}

@test "manifest has the four new options with schema entries" {
  c="$REPO/charm-crush/config.yaml"
  grep -q '^  crush_config_sha256: str?$' "$c"
  grep -q '^  crush_config_allow_http: bool$' "$c"
  grep -q '^  crush_update_version: str?$' "$c"
  grep -q '^  crush_update_sha256: str?$' "$c"
}

# ── persist_migrate ──────────────────────────────────────────────────────
mk_old() {
  OLD="$TMP/ha/.crushdata"; NEW="$TMP/cfg/crushdata"; MARK="$NEW/.migrated"
  mkdir -p "$OLD/config/crush" "$OLD/data"
  echo "rc-old" > "$OLD/config/crush/crushrc"
  echo "KEYLINE" > "$OLD/config/crush/ollama.env"
  echo "db" > "$OLD/data/crush.db"
  echo "CRUSH-OLD" > "$OLD/CRUSH.md"
}

@test "persist_migrate copies the old folder, leaves it in place, logs it, writes the marker" {
  mk_old
  run persist_migrate "$OLD" "$NEW" "$MARK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"data migrated"* ]]
  [[ "$output" == *"left in place"* ]]
  [ "$(cat "$NEW/config/crush/crushrc")" = rc-old ]
  [ "$(cat "$NEW/data/crush.db")" = db ]
  [ -f "$OLD/config/crush/crushrc" ]
  [ -f "$MARK" ]
}

@test "persist_migrate runs once: later changes are not overwritten from the old copy" {
  mk_old
  persist_migrate "$OLD" "$NEW" "$MARK" >/dev/null
  echo "rc-new" > "$NEW/config/crush/crushrc"
  echo "rc-old-2" > "$OLD/config/crush/crushrc"
  run persist_migrate "$OLD" "$NEW" "$MARK"
  [ -z "$output" ]
  [ "$(cat "$NEW/config/crush/crushrc")" = rc-new ]
}

@test "persist_migrate never overwrites files already in the new folder" {
  mk_old
  mkdir -p "$NEW/config/crush"; echo "rc-existing" > "$NEW/config/crush/crushrc"
  persist_migrate "$OLD" "$NEW" "$MARK" >/dev/null
  [ "$(cat "$NEW/config/crush/crushrc")" = rc-existing ]
  [ "$(cat "$NEW/CRUSH.md")" = CRUSH-OLD ]
}

@test "persist_migrate with no old folder does nothing and writes no marker" {
  NEW="$TMP/cfg/crushdata"
  run persist_migrate "$TMP/nope" "$NEW" "$NEW/.m"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ ! -e "$NEW/.m" ]
}

@test "run.sh persists under /config/crushdata and calls the migration first" {
  grep -q '^PERSIST_DIR=/config/crushdata' "$RUN"
  p=$(grep -n 'persist_migrate "\$OLD_PERSIST_DIR"' "$RUN" | cut -d: -f1)
  e=$(grep -n '^ENV_FILE=' "$RUN" | cut -d: -f1)
  [ "$p" -lt "$e" ]
  ! grep -q 'PERSIST_DIR=/homeassistant' "$RUN"
  grep -q 'source-file -q /config/crushdata/tmux.conf' "$REPO/charm-crush/rootfs/root/.tmux.conf"
}
