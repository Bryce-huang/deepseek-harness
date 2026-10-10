# Runtime base selection: the pinned sandbox release by default; CI also
# builds the tracking variant with
# --build-arg SANDBOX_IMAGE=ghcr.io/agent-infra/sandbox:latest.
ARG SANDBOX_IMAGE=ghcr.io/agent-infra/sandbox:1.11.0

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

# ---- Stage 2: Production on the agent-infra sandbox ----
# The published sandbox image (ENTRYPOINT /opt/gem/run.sh, default PUBLIC_PORT
# 8080) carries the browser, VNC, code-server, jupyter, shell/file MCP stack.
# dsh becomes the container's main service on 8080; the sandbox's public
# listener moves to 8090. Its MCP endpoint is then
# http://127.0.0.1:8090/mcp (streamable-HTTP), reached by the profile patch
# the entrypoint writes on first boot.
FROM ${SANDBOX_IMAGE}

# Root for the install steps below: corepack needs a writable install root,
# and /app must be creatable. The sandbox's own run.sh handles its user
# switching internally.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@11.7.0 --activate

WORKDIR /app

# Copy the entire built tree (source + lib + node_modules)
# We keep the full tree because the source-launch CLI needs tsx,
# and pnpm workspace resolution requires the full structure.
COPY --from=builder /app /app

# Offline-first entrypoint: starts the sandbox, waits for its API, pre-creates
# the web profile (offline optional bundles plus the sandbox MCP row), and
# exec's the dsh web command. See scripts/entrypoint-sandbox.sh.
COPY scripts/entrypoint-sandbox.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# dsh owns 8080; the sandbox's public listener moves to 8090. The remaining
# sandbox ports keep their image defaults (MCP hub 8079, gem 8088, code-server
# 8200, VNC 5900).
#
# USER_UID/USER_GID retarget the sandbox's internal user creation from the
# image default (1000/1000) to the deployment's app user: run.sh creates its
# user from these envs and chowns /home/gem, so every sandbox service runs
# uid 6001 / gid 6000, and the entrypoint drops dsh to the same ids.
ENV PUBLIC_PORT=8090 \
    USER_UID=6001 \
    USER_GID=6000 \
    DSH_ALLOW_ALL_INTERFACES=1 \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_HOME=/dsh-home \
    NODE_ENV=production \
    DSH_SANDBOX_MCP_URL=http://127.0.0.1:8090/mcp

# dsh's persistent state (profiles, sessions) lives here, owned by the app
# user; numeric ids need no passwd entry at build time.
RUN mkdir -p /dsh-home && chown 6001:6000 /dsh-home

EXPOSE 8080 8090

# dsh binds 8080 only after the sandbox stack is up, so the start period
# covers the sandbox boot too (its own WAIT_PORTS gate plus service starts).
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/').catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["web", "--host", "0.0.0.0", "--port", "8080", "--no-open"]
