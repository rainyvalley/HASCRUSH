#!/usr/bin/env bats
# apparmor.txt: the Supervisor renames the profile to "<repohash>_charm-crush",
# so peer= rules must match a SUFFIX, not a prefix.

ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
AA="$ROOT/charm-crush/apparmor.txt"

@test "no peer rule uses the prefix glob charm-crush*" {
  ! grep -E '^[[:space:]]*(signal|ptrace).*peer=charm-crush\*' "$AA"
}

@test "signal and ptrace rules use the suffix glob *charm-crush" {
  [ "$(grep -cE '^[[:space:]]*(signal|ptrace).*peer=\*charm-crush,' "$AA")" -eq 3 ]
}

@test "run.sh: no stale manager-role wording and no SC1007 form" {
  ! grep -q 'manager role' "$ROOT/charm-crush/rootfs/run.sh"
  ! grep -qE 'CDPATH= cd' "$ROOT/charm-crush/rootfs/run.sh"
}

@test "run.sh: crushrc install stages in the destination dir (atomic rename)" {
  grep -q 'mv -f "\$crushrc.new" "\$crushrc"' "$ROOT/charm-crush/rootfs/run.sh"
  ! grep -q 'same-dir move' "$ROOT/charm-crush/rootfs/run.sh"
}
