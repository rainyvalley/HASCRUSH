#!/usr/bin/env python3
"""Refresh every version pin in the add-on (run by update-pins.yml).

Pins live in two files and are checked into git so a build never depends on a
moving "latest":

  charm-crush/Dockerfile  Crush (release tag), ttyd (release tag + the two
                          binary sha256 sums) and the Home Assistant CLI
                          (release tag + the two asset digests).
  charm-crush/build.yaml  The Home Assistant Alpine base images, bumped only
                          when BOTH architectures publish the same new
                          major.minor tag.

The ttyd and ha binaries are verified at build time; this script only moves the
pinned values, and prints one "name old -> new" line per change. Nothing newer
means no output and no writes. Uses only the standard library; GITHUB_TOKEN (or
GH_TOKEN) is used for the API when present.
"""

import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCKERFILE = os.path.join(ROOT, "charm-crush", "Dockerfile")
BUILD_YAML = os.path.join(ROOT, "charm-crush", "build.yaml")
TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""


def _open(url, headers):
    req = urllib.request.Request(url, headers=headers)
    return urllib.request.urlopen(req, timeout=60)


def api(path):
    headers = {"Accept": "application/vnd.github+json",
               "User-Agent": "hasscrush-update-pins"}
    if TOKEN:
        headers["Authorization"] = "Bearer " + TOKEN
    with _open("https://api.github.com" + path, headers) as r:
        return json.load(r)


def fetch(url):
    with _open(url, {"User-Agent": "hasscrush-update-pins"}) as r:
        return r.read().decode("utf-8", "replace")


def latest(repo):
    return api("/repos/%s/releases/latest" % repo)


def numeric(value):
    return tuple(int(p) for p in re.findall(r"\d+", value)[:3]) or (0,)


def is_newer(candidate, current):
    return numeric(candidate) > numeric(current)


def ghcr_tags(image):
    """Tag list for a public ghcr.io image (anonymous pull token)."""
    with _open("https://ghcr.io/token?service=ghcr.io&scope=repository:%s:pull" % image,
               {"User-Agent": "hasscrush-update-pins"}) as r:
        token = json.load(r)["token"]
    headers = {"Authorization": "Bearer " + token,
               "User-Agent": "hasscrush-update-pins"}
    with _open("https://ghcr.io/v2/%s/tags/list" % image, headers) as r:
        return json.load(r).get("tags", [])


def main():
    docker = open(DOCKERFILE, encoding="utf-8").read()
    build = open(BUILD_YAML, encoding="utf-8").read()
    changes = []

    # ── Crush: the release tag; the tarball checksum is verified at build ──
    rel = latest("charmbracelet/crush")
    tag = (rel.get("tag_name") or "").lstrip("v")
    m = re.search(r"^ARG CRUSH_VERSION=(\S+)$", docker, re.M)
    if m and tag and is_newer(tag, m.group(1)):
        docker = docker[:m.start(1)] + tag + docker[m.end(1):]
        changes.append("crush %s -> %s" % (m.group(1), tag))

    # ── ttyd: release tag + both binary sha256 sums (upstream SHA256SUMS) ──
    rel = latest("tsl0922/ttyd")
    tag = rel.get("tag_name") or ""
    sums = next((a for a in rel.get("assets", []) if a["name"] == "SHA256SUMS"), None)
    m = re.search(r"releases/download/(\d+\.\d+\.\d+)/ttyd\.", docker)
    if tag and sums and m and is_newer(tag, m.group(1)):
        text = fetch(sums["browser_download_url"])
        sums_by_name = {}
        for line in text.splitlines():
            parts = line.split()
            if len(parts) == 2:
                sums_by_name[parts[1].lstrip("*")] = parts[0]
        want = {"TTYD_SHA256_X86_64": "ttyd.x86_64",
                "TTYD_SHA256_AARCH64": "ttyd.aarch64"}
        if all(sums_by_name.get(asset) for asset in want.values()):
            docker = (docker[:m.start(1)] + tag + docker[m.end(1):])
            for arg, asset in want.items():
                am = re.search(r"^ARG %s=(\S+)$" % arg, docker, re.M)
                if am:
                    docker = docker[:am.start(1)] + sums_by_name[asset] + docker[am.end(1):]
            changes.append("ttyd %s -> %s" % (m.group(1), tag))

    # ── Home Assistant CLI: release tag + digest of each asset ─────────────
    rel = latest("home-assistant/cli")
    tag = rel.get("tag_name") or ""
    digests = {}
    for asset in rel.get("assets", []):
        digest = (asset.get("digest") or "").split(":", 1)
        if len(digest) == 2 and digest[0] == "sha256":
            digests[asset["name"]] = digest[1]
    m = re.search(r"^ARG HA_CLI_VERSION=(\S+)$", docker, re.M)
    if tag and m and is_newer(tag, m.group(1)) and \
            digests.get("ha_amd64") and digests.get("ha_aarch64"):
        docker = docker[:m.start(1)] + tag + docker[m.end(1):]
        for arg, asset in (("HA_CLI_SHA256_AMD64", "ha_amd64"),
                           ("HA_CLI_SHA256_AARCH64", "ha_aarch64")):
            am = re.search(r"^ARG %s=(\S+)$" % arg, docker, re.M)
            if am:
                docker = docker[:am.start(1)] + digests[asset] + docker[am.end(1):]
        changes.append("ha CLI %s -> %s" % (m.group(1), tag))

    # ── Alpine base images: the newest tag BOTH architectures publish ──────
    try:
        amd = set(t for t in ghcr_tags("home-assistant/amd64-base")
                  if re.fullmatch(r"\d+\.\d+", t))
        arm = set(t for t in ghcr_tags("home-assistant/aarch64-base")
                  if re.fullmatch(r"\d+\.\d+", t))
        common = sorted(amd & arm, key=numeric)
        m = re.search(r"(ghcr\.io/home-assistant/amd64-base:)(\S+)", build)
        if common and m and is_newer(common[-1], m.group(2)):
            old = m.group(2)
            build = build.replace("ghcr.io/home-assistant/amd64-base:" + old,
                                  "ghcr.io/home-assistant/amd64-base:" + common[-1])
            build = build.replace("ghcr.io/home-assistant/aarch64-base:" + old,
                                  "ghcr.io/home-assistant/aarch64-base:" + common[-1])
            changes.append("alpine base %s -> %s" % (old, common[-1]))
    except Exception as exc:  # a ghcr hiccup must not fail the run
        print("warning: could not read the base image tags: %s" % exc, file=sys.stderr)

    if not changes:
        return 0
    with open(DOCKERFILE, "w", encoding="utf-8") as fh:
        fh.write(docker)
    with open(BUILD_YAML, "w", encoding="utf-8") as fh:
        fh.write(build)
    print("\n".join(changes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
