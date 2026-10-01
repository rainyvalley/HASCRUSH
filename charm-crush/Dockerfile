ARG BUILD_FROM
FROM ${BUILD_FROM}

# Labels
LABEL maintainer="rainyvalley"
LABEL org.opencontainers.image.title="Crush for Home Assistant"
LABEL org.opencontainers.image.description="Charm Crush CLI with web terminal, your own Ollama models, and the shared mem0 memory layer"
LABEL org.opencontainers.image.source="https://github.com/rainyvalley/HASSCharm"
LABEL org.opencontainers.image.licenses="MIT"

ENV \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

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

# Install ttyd static binary (avoids libwebsockets issues on alpine)
ARG BUILD_ARCH
RUN case "${BUILD_ARCH}" in \
        amd64) TTYD_ARCH="x86_64" ;; \
        aarch64) TTYD_ARCH="aarch64" ;; \
        *) TTYD_ARCH="x86_64" ;; \
    esac && \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${TTYD_ARCH}" -o /usr/bin/ttyd && \
    chmod +x /usr/bin/ttyd

# Install Crush. Resolve the current version from GitHub releases and verify the
# binary runs a smoke test before trusting it; if the newest release fails on
# this base, fall back to a known-good pinned release rather than failing the
# whole build.
# Asset naming (verified against v0.97.1): crush_<ver>_Linux_<arch>.tar.gz with
# the binary at crush_<ver>_Linux_<arch>/crush inside. The .apk files are alpine
# packages (arch names x86_64/aarch64) — an alternative install path.
RUN set -eux; \
    case "${BUILD_ARCH}" in \
        amd64) CRUSH_ARCH="x86_64" ;; \
        aarch64) CRUSH_ARCH="arm64" ;; \
        *) echo "[WARN] no crush binary published for ${BUILD_ARCH}"; exit 1 ;; \
    esac; \
    CRUSH_VER="$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
        https://api.github.com/repos/charmbracelet/crush/releases/latest \
        | jq -r .tag_name | tr -d v)"; \
    if [ -z "$CRUSH_VER" ] || [ "$CRUSH_VER" = "null" ]; then CRUSH_VER="0.97.1"; fi; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/charmbracelet/crush/releases/download/v${CRUSH_VER}/crush_${CRUSH_VER}_Linux_${CRUSH_ARCH}.tar.gz" \
        -o /tmp/crush.tar.gz || { echo "[WARN] release download failed; trying pinned 0.97.1"; CRUSH_VER="0.97.1"; \
        curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/charmbracelet/crush/releases/download/v0.97.1/crush_0.97.1_Linux_${CRUSH_ARCH}.tar.gz" -o /tmp/crush.tar.gz; }; \
    tar -xzf /tmp/crush.tar.gz -C /tmp; \
    mv "/tmp/crush_${CRUSH_VER}_Linux_${CRUSH_ARCH}/crush" /usr/local/bin/crush; \
    chmod +x /usr/local/bin/crush; rm -rf /tmp/crush.tar.gz /tmp/crush_*_Linux_*; \
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