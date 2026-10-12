# ---- Stage 1: Build ----
FROM node:22-slim AS builder

# Install build toolchain for native module compilation (cc, make, python for
# node-gyp).
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential python3 make \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@11.7.0 --activate

# The desktop tsdown step embeds client build metadata and runs `git rev-parse`
# when DSH_CLIENT_VERSION is unset (scripts/client-build-environment.ts). The
# build context excludes .git, so pin the version env instead; CI passes the
# real commit hash through the DSH_CLIENT_COMMIT_HASH build arg.
ARG DSH_CLIENT_COMMIT_HASH=
ARG DSH_CLIENT_VERSION=0.2.1-alpha.1
ENV DSH_CLIENT_COMMIT_HASH=${DSH_CLIENT_COMMIT_HASH} \
    DSH_CLIENT_VERSION=${DSH_CLIENT_VERSION}

WORKDIR /app

# Copy everything for build
COPY . .

# Install dependencies and build. The fetch timeout/retry envs keep large
# platform tarballs (@openai/codex is the usual one) from aborting the whole
# install on a slow link.
RUN npm_config_fetch_timeout=600000 npm_config_fetch_retries=5 \
    pnpm install --frozen-lockfile \
    && pnpm run build:native-system \
    && pnpm run build:lib:host \
    && pnpm run build:lib:client \
    && pnpm run build:web

# ---- Stage 2: Production on a standard Debian with a common dev toolchain ----
# Plain debian:bookworm-slim plus the toolchain an agent needs at runtime —
# git, python, the latest Go, the latest LTS JDK, Node.js LTS. No browser/VNC
# stack: dsh is the single service on 8080.
FROM debian:bookworm-slim

USER root
ARG TARGETARCH

# Base packages: git/python from the distro, plus common CLI helpers.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils git \
      python3 python3-pip python3-venv \
      build-essential openssh-client ripgrep jq unzip \
    && rm -rf /var/lib/apt/lists/*

# Node.js LTS (24.x) from NodeSource; corepack provides pnpm for the dsh
# profile's package operations. COREPACK_HOME puts the prepared pnpm where
# the app user can read it (the default cache lands under /root).
ENV COREPACK_HOME=/usr/local/share/corepack
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@11.7.0 --activate

# Latest stable Go from the official distribution (resolved at build time).
RUN GO_VERSION="$(curl -fsSL 'https://go.dev/dl/?mode=json' \
      | grep -o '"version": "go[0-9]*\.[0-9]*\(\.[0-9]*\)\?"' | head -1 | cut -d'"' -f4 | sed 's/^go//')" \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
      | tar -C /usr/local -xz

# Latest LTS JDK (Temurin 25) from the Adoptium API; the symlink absorbs the
# full version in the extracted directory name.
RUN case "${TARGETARCH}" in \
      amd64) JDK_ARCH=x64 ;; \
      arm64) JDK_ARCH=aarch64 ;; \
      *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://api.adoptium.net/v3/binary/latest/25/ga/linux/${JDK_ARCH}/jdk/hotspot/normal/eclipse" \
      | tar -C /opt -xz \
    && ln -s /opt/jdk-* /opt/jdk

ENV PATH=/opt/jdk/bin:/usr/local/go/bin:${PATH} \
    JAVA_HOME=/opt/jdk

# The deployment's app user (uid 6001 / gid 6000), the image's only runtime
# identity — no elevation anywhere: dsh needs no root-time setup.
RUN groupadd --gid 6000 apps \
    && useradd --uid 6001 --gid apps --shell /bin/bash --create-home --no-log-init app

WORKDIR /app

# Copy the entire built tree (source + lib + node_modules)
# We keep the full tree because the source-launch CLI needs tsx,
# and pnpm workspace resolution requires the full structure.
COPY --from=builder /app /app

# Offline-first entrypoint: pre-creates the web profile (offline optional
# bundles) and exec's the dsh web command. See scripts/entrypoint-web.sh.
COPY scripts/entrypoint-web.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

ENV DSH_ALLOW_ALL_INTERFACES=1 \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_HOME=/dsh-home \
    NODE_ENV=production

# dsh's persistent state (profiles, sessions) lives here, owned by the app
# user; numeric ids need no passwd entry at build time.
RUN mkdir -p /dsh-home && chown 6001:6000 /dsh-home

USER 6001:6000

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/').catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["web", "--host", "0.0.0.0", "--port", "8080", "--no-open"]
