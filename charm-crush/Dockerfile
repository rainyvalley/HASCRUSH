ARG BUILD_FROM
FROM ${BUILD_FROM}

# Labels
LABEL maintainer="rainyvalley"
LABEL org.opencontainers.image.title="HASSCrush — Crush for Home Assistant"
LABEL org.opencontainers.image.description="Charm Crush CLI with web terminal, your own Ollama (or third-party) models, and optional MCP tie-ins"
LABEL org.opencontainers.image.source="https://github.com/rainyvalley/HASSCharm"
LABEL org.opencontainers.image.licenses="MIT"

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
# gnupg + ca-certificates are needed by the charm apt-repo bootstrap on debian
# bases, and are harmless no-ops on alpine bases which get the static binary).
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
    gnupg \
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
        *) TTYD_ARCH="x86_64"; TTYD_SHA256="${TTYD_SHA256_X86_64}" ;; \
    esac && \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${TTYD_ARCH}" -o /usr/bin/ttyd && \
    echo "${TTYD_SHA256}  /usr/bin/ttyd" | sha256sum -c - && \
    chmod +x /usr/bin/ttyd

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

# Home Assistant CLI (ha command) - pinned and retried; upstream publishes only
# amd64 and aarch64, which are the only arches this add-on declares anyway.
ARG HA_CLI_VERSION=5.2.0
RUN curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/home-assistant/cli/releases/download/${HA_CLI_VERSION}/ha_${BUILD_ARCH}" \
        -o /usr/local/bin/ha && \
    chmod +x /usr/local/bin/ha

# Shell and tmux config (COPY works on every builder; heredocs need BuildKit)
COPY rootfs/root/.bashrc /root/.bashrc
COPY rootfs/root/.tmux.conf /root/.tmux.conf

# Bash login shells source .profile too
RUN echo 'source ~/.bashrc' > /root/.profile

# Local bin on PATH
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /homeassistant

# ttyd answers on 7681 or the add-on isn't serving the panel
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:7681/ || exit 1

# Startup is a separate run.sh so crushrc/CRUSH.md/templates stay readable
# (an inline CMD heredoc needs BuildKit and is unreadable in git diffs).
COPY rootfs/run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh
CMD ["/usr/local/bin/run.sh"]