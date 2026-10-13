#!/usr/bin/env bash
# Changelog gate: charm-crush/CHANGELOG.md (shown in the add-on's Changelog
# tab) must carry an "## [Unreleased]" section and a "## [<version>]" section
# for the version in charm-crush/config.yaml. Local only: no network.
# Usage: check_changelog.sh [config.yaml] [CHANGELOG.md]
set -u
config=${1:-charm-crush/config.yaml}
changelog=${2:-charm-crush/CHANGELOG.md}

[ -f "$config" ] || { echo "::error::$config not found"; exit 1; }
[ -f "$changelog" ] || { echo "::error::$changelog not found"; exit 1; }

version=$(sed -n 's/^version: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\} *$/\1/p' "$config" | head -n1)
[ -n "$version" ] || { echo "::error::$config has no version: line"; exit 1; }

rc=0
if ! grep -qxF '## [Unreleased]' "$changelog"; then
  echo "::error::${changelog} has no \"## [Unreleased]\" section"
  rc=1
fi
if ! grep -qE "^## \[${version//./\\.}\]( - [0-9]{4}-[0-9]{2}-[0-9]{2})?\$" "$changelog"; then
  echo "::error::${changelog} has no \"## [${version}]\" section for the config.yaml version; add the release notes in the same change as the version bump"
  rc=1
fi
[ "$rc" = 0 ] && echo "changelog OK (version ${version}, Unreleased present)"
exit "$rc"
