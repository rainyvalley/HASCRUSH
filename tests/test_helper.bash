# Shared plumbing for the lib.sh unit suites (run by `bats tests/`).
# The suites source the REAL rootfs/lib.sh - the same copy run.sh sources in
# the image - and drive it with synthetic $crushrc / $CRUSH_MD fixtures.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/charm-crush/rootfs/lib.sh"

# Sourced at load time: lib.sh's file-scope statements (CR, ENV_PAT) also run
# here - they are part of the unit under test, not fixture noise.
# shellcheck source=charm-crush/rootfs/lib.sh
. "$LIB"

# Fresh temp dir + empty crushrc per test.
setup_tmp() {
  TMP="$(mktemp -d)"
  crushrc="$TMP/crushrc"
}
teardown_tmp() { rm -rf "$TMP"; }