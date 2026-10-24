ARG BUILD_FROM
FROM ${BUILD_FROM}

# Labels
LABEL maintainer="rainyvalley"
LABEL org.opencontainers.image.title="HASSCrush — Crush for Home Assistant"
LABEL org.opencontainers.image.description="Charm Crush CLI with web terminal, your own Ollama (or third-party) models, and optional MCP tie-ins"
LABEL org.opencontainers.image.source="https://github.com/rainyvalley/HASCRUSH"
LABEL org.opencontainers.image.licenses="BSD-2-Clause"

# S6_KEEP_ENV=1 must be set at image level: s6-overlay stage0 reads it BEFORE
# any user code runs, and without it the container environment (including the
# Supervisor-injected SUPERVISOR_TOKEN, which the ha CLI reads by literal name)
# is stripped before run.sh starts. run.sh re-exports it too (harmless there)
# and additionally recovers the token from the s6 envdir as a fallback.
ENV \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    S6_KEEP_ENV=1

# System dependencies (ttyd installed separately as a static binary below;
# ca-certificates pins the CA set for curl).
RUN apk add --no-cache \
    bash \
    curl \
    git \
    jq \
    nodejs \
    npm \
    openssh-client \
    libstdc++ \
    ncurses \
    vim \
    nano \
    tmux \
    coreutils \
    findutils \
    grep \
    sed \
    gawk \
    ca-certificates \
    openssl \
    ripgrep \
    p7zip \
    socat \
    docker-cli \
    && update-ca-certificates

# Install ttyd static binary (avoids libwebsockets issues on alpine).
# Supply-chain pin (2026-10-06): sha256 of the 1.7.7 release binaries is
# recorded here and verified at build time — upstream publishes no checksum
# files, so the hashes were captured over a verified TLS fetch on 2026-10-06
# and committed. Updating ttyd = bump the version URL + BOTH hashes together.
ARG BUILD_ARCH
ARG TTYD_SHA256_X86_64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
ARG TTYD_SHA256_AARCH64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
RUN case "${BUILD_ARCH}" in \
        amd64) TTYD_ARCH="x86_64"; TTYD_SHA256="${TTYD_SHA256_X86_64}" ;; \
        aarch64) TTYD_ARCH="aarch64"; TTYD_SHA256="${TTYD_SHA256_AARCH64}" ;; \
        *) echo "unsupported BUILD_ARCH: ${BUILD_ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${TTYD_ARCH}" -o /usr/bin/ttyd && \
    echo "${TTYD_SHA256}  /usr/bin/ttyd" | sha256sum -c - && \
    chmod +x /usr/bin/ttyd

# Extract ttyd's OWN embedded web client page (a self-contained index.html
# with all client JS inlined - ttyd serves no separate assets) to
# /usr/local/share/ttyd-index.html. When the touch_bar option is on, run.sh
# splices the touch-bar script into this copy and hands it back to ttyd via
# its --index option; the page therefore always comes from the SAME pinned
# binary that serves it and cannot drift with a ttyd bump. Extraction runs the
# just-verified binary briefly on a throwaway loopback port; it is
# best-effort: a failure keeps the image bootable, run.sh logs that the touch
# bar is unavailable and serves the plain terminal.
RUN set -eux; \
    ttyd --interface 127.0.0.1 --port 17682 --max-clients 1 sh -c 'while :; do sleep 3600; done' >/dev/null 2>&1 & \
    TTYD_PID=$!; \
    PAGE_OK=0; \
    for _ in $(seq 1 150); do \
      if curl -fsS "http://127.0.0.1:17682/" -o /usr/local/share/ttyd-index.html 2>/dev/null; then PAGE_OK=1; break; fi; \
      sleep 0.2; \
    done; \
    kill "$TTYD_PID" 2>/dev/null || true; \
    wait "$TTYD_PID" 2>/dev/null || true; \
    if [ "$PAGE_OK" = "1" ] && grep -q '</head>' /usr/local/share/ttyd-index.html; then \
      echo "ttyd client page extracted for the touch bar"; \
    else \
      rm -f /usr/local/share/ttyd-index.html; \
      echo "WARNING: ttyd client page extraction failed - the touch bar will be unavailable"; \
    fi

# Install Crush. Pinned to a fixed release (supply-chain, 2026-10-06): the
# version no longer auto-resolves to "latest" — updates are explicit ARG
# bump commits (the auto_update_crush add-on option remains the runtime path
# for newer versions). The tarball is verified against the release's own
# checksums.txt before extraction; a failed/corrupted download FAILS the
# build instead of silently falling back to a different version.
# Asset naming (verified against v0.97.1): crush_<ver>_Linux_<arch>.tar.gz with
# the binary at crush_<ver>_Linux_<arch>/crush inside. The .apk files are alpine
# packages (arch names x86_64/aarch64) — an alternative install path.
ARG CRUSH_VERSION=0.97.1
RUN set -eux; \
    case "${BUILD_ARCH}" in \
        amd64) CRUSH_ARCH="x86_64" ;; \
        aarch64) CRUSH_ARCH="arm64" ;; \
        *) echo "[FATAL] no crush binary published for ${BUILD_ARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/charmbracelet/crush/releases/download/v${CRUSH_VERSION}/crush_${CRUSH_VERSION}_Linux_${CRUSH_ARCH}.tar.gz" \
        -o /tmp/crush.tar.gz; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/charmbracelet/crush/releases/download/v${CRUSH_VERSION}/checksums.txt" \
        -o /tmp/crush.sum; \
    EXPECTED="$(awk -v f="crush_${CRUSH_VERSION}_Linux_${CRUSH_ARCH}.tar.gz" '$2 == f {print $1}' /tmp/crush.sum | head -n 1)"; \
    # NB: exact-second-field match — a plain substring grep would also match the
    # sig line (crush_..._tar.gz.sig) and feed sha256sum two hashes at once.
    [ -n "$EXPECTED" ] || { echo "[FATAL] no checksum entry for the pinned tarball in checksums.txt"; exit 1; }; \
    echo "$EXPECTED  /tmp/crush.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/crush.tar.gz -C /tmp; \
    mv "/tmp/crush_${CRUSH_VERSION}_Linux_${CRUSH_ARCH}/crush" /usr/local/bin/crush; \
    chmod +x /usr/local/bin/crush; rm -rf /tmp/crush.tar.gz /tmp/crush.sum /tmp/crush_*_Linux_*; \
    crush --version < /dev/null | tee /etc/crush-version

# Home Assistant CLI (ha command) - pinned, retried and checksum-verified.
# Upstream publishes only amd64 and aarch64, which are the only arches this
# add-on declares anyway. The sha256 values below were taken from the digest
# GitHub records for each 5.2.0 release asset (releases API "digest" field)
# and matched against a fresh download; upstream ships no checksum file of
# its own. Updating the CLI = bump HA_CLI_VERSION + BOTH hashes together.
ARG HA_CLI_VERSION=5.2.0
ARG HA_CLI_SHA256_AMD64=701be67aee9f1e092254097a40d006b450d1578641a262258b182237987e7479
ARG HA_CLI_SHA256_AARCH64=af8c03ccddb65d223d7b7dab1570197b8a2ff8fc7139c1db054d08a91a4f8073
RUN case "${BUILD_ARCH}" in \
        amd64) HA_SHA256="${HA_CLI_SHA256_AMD64}" ;; \
        aarch64) HA_SHA256="${HA_CLI_SHA256_AARCH64}" ;; \
        *) echo "[FATAL] no ha CLI binary published for ${BUILD_ARCH}"; exit 1 ;; \
    esac && \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/home-assistant/cli/releases/download/${HA_CLI_VERSION}/ha_${BUILD_ARCH}" \
        -o /usr/local/bin/ha && \
    echo "${HA_SHA256}  /usr/local/bin/ha" | sha256sum -c - && \
    chmod +x /usr/local/bin/ha

# Shell and tmux config (COPY works on every builder; heredocs need BuildKit).
# Startup is a separate run.sh so crushrc/CRUSH.md/templates stay readable
# (an inline CMD heredoc needs BuildKit and is unreadable in git diffs).
COPY rootfs/root/.bashrc rootfs/root/.tmux.conf /root/
# run.sh sources lib.sh (pure helpers, see its header) relative to its own
# location, so both land in /usr/local/bin; lib.sh stays 644 - it is sourced,
# never executed. touchbar.js is read (never executed) by run.sh when it
# splices the touch-bar page for ttyd --index.
COPY rootfs/run.sh rootfs/lib.sh /usr/local/bin/
COPY rootfs/touchbar.js /usr/local/share/touchbar.js

# Bash login shells source .profile too; run.sh ships 644 from git, so its
# exec bit is set here instead of in a dedicated RUN layer
RUN echo 'source ~/.bashrc' > /root/.profile && chmod +x /usr/local/bin/run.sh

WORKDIR /homeassistant

# ttyd listens on loopback:7682 behind a socat gate on 7681 that only accepts
# the Supervisor ingress address (see lib.sh), so the probe goes straight to
# ttyd on loopback (with the X-Hass-Source header ttyd requires, else 407) and
# also checks that the gate process is alive.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -sf -H 'X-Hass-Source: core.ingress' http://127.0.0.1:7682/ >/dev/null && pgrep -f '^socat TCP4-LISTEN:7681' >/dev/null || exit 1

CMD ["/usr/local/bin/run.sh"]