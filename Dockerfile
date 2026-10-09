# ---- Stage 1: Build ----
FROM node:22-slim AS builder

RUN corepack enable && corepack prepare pnpm@11.7.0 --activate

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

# Docker deployment defaults
ENV DSH_ALLOW_ALL_INTERFACES=1
ENV DSH_TELEMETRY_DISABLED=1
ENV NODE_ENV=production

EXPOSE 3080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://localhost:3080/').catch(()=>process.exit(1))"

ENTRYPOINT ["node", "--import", "tsx/esm", "apps/cli/src/bin.ts"]
CMD ["web", "--host", "0.0.0.0", "--port", "3080", "--no-open"]
