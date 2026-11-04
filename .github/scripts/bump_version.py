#!/usr/bin/env python3
"""Increment the add-on patch version and add the changelog section it needs.

Home Assistant only offers an add-on update when charm-crush/config.yaml's
`version` changes, and the changelog gate requires a `## [<version>]` section
for whatever that version is. Both workflows that produce a new build
(version-bump.yml for code pushes, update-pins.yml for pinned releases) call
this so the two edits can never drift apart.

Prints the new version on stdout; an optional argument becomes an extra
changelog bullet.
"""

import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG = os.path.join(ROOT, "charm-crush", "config.yaml")
CHANGELOG = os.path.join(ROOT, "charm-crush", "CHANGELOG.md")


def main():
    note = " ".join(sys.argv[1:]).strip()
    sha = os.environ.get("GIT_SHA") or subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()

    text = open(CONFIG, encoding="utf-8").read()
    m = re.search(r'^version: "(\d+)\.(\d+)\.(\d+)"$', text, re.M)
    if not m:
        sys.exit("config.yaml has no semver version: line")
    major, minor, patch = (int(g) for g in m.groups())
    new = "%d.%d.%d" % (major, minor, patch + 1)
    text = text[:m.start()] + 'version: "%s"' % new + text[m.end():]
    open(CONFIG, "w", encoding="utf-8").write(text)

    changelog = open(CHANGELOG, encoding="utf-8").read()
    marker = "## [Unreleased]\n"
    if marker not in changelog:
        sys.exit('CHANGELOG.md has no "## [Unreleased]" section')
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    body = "- Automatic version bump for build `%s`." % sha
    if note:
        body += "\n- %s" % note
    section = "%s\n## [%s] - %s\n\n### Build\n\n%s\n" % (marker, new, day, body)
    open(CHANGELOG, "w", encoding="utf-8").write(changelog.replace(marker, section, 1))

    print(new)


if __name__ == "__main__":
    main()
