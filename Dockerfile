# ---- Stage 1: Build ----
FROM node:22-slim AS builder

# Install build toolchain for native module compilation (cc, make, python for node-gyp)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential python3 make \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@11.7.0 --activate

WORKDIR /app

# Copy everything for build
COPY . .

# Install dependencies and build
RUN pnpm install --frozen-lockfile \
    && pnpm run build:native-system \
    && pnpm run build:lib:host \
    && pnpm run build:lib:client \
    && pnpm run build:web

# ---- Stage 2: Production ----
FROM node:22-slim AS production

RUN corepack enable && corepack prepare pnpm@11.7.0 --activate

WORKDIR /app

# Copy the entire built tree (source + lib + node_modules)
# We keep the full tree because the source-launch CLI needs tsx,
# and pnpm workspace resolution requires the full structure.
COPY --from=builder /app /app

# Offline-first entrypoint: the CLI image ships every optional bundle
# (agent-team-profile, auto-review, ptc-runtime-python) as a runtime
# dependency, so its symlinks live under /app/node_modules before
# the first boot. The script below adds them to the active profile's
# dsh.profile.bundles list without contacting the registry, then
# exec's the dsh web command. The cloud-only base rows (DeepSeek
# account, web search, plugin registry, etc.) are disabled by the
# web-app's cordis.patch.yml — see packages/bundle/web-app/cordis.patch.yml.
COPY scripts/entrypoint-web.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# Docker deployment defaults
ENV DSH_ALLOW_ALL_INTERFACES=1
ENV DSH_TELEMETRY_DISABLED=1
ENV DSH_HOME=/dsh-home
ENV NODE_ENV=production

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/').catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["web", "--host", "0.0.0.0", "--port", "8080", "--no-open"]
