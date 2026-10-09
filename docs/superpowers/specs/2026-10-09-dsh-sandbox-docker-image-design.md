# dsh Docker Image with `ghcr.io/agent-infra/sandbox` as the Runtime Base

**Date:** 2026-10-09
**Status:** Approved (design); implementation pending
**Owner:** brycehuang
**Replaces:** the prior `node:22-slim` production stage in `Dockerfile` (and the existing `scripts/entrypoint-web.sh`)

## Context

`dsh` ships a Docker image that runs its web profile. Until now, the production stage is a vanilla `node:22-slim` image: dsh is the only process in the container, bound to port 8080.

The user wants the runtime image to be `ghcr.io/agent-infra/sandbox:1.11.0` — an "all-in-one" container that exposes a sandboxed browser, VNC, VSCode, Jupyter, shell, file operations, and an MCP hub. The goal is for dsh to *operate* the sandbox's services directly: read/write its workspace, execute shell commands, drive its browser, run Jupyter cells, and expose its MCP servers to the model.

The architectural split is:

- **dsh on 8080** — main service, the user's only required port
- **sandbox on 8090** — administrative UI (VNC, code-server, `/docs`), reachable but secondary
- **MCP hub on 8079** — internal; dsh connects to it directly via streamable-HTTP
- **sandbox HTTP API on 8090** — internal; dsh calls it via `web-fetch-http` for file/shell/browser/jupyter

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Container                                                  │
│  ┌─────────────────────────┐  ┌─────────────────────────┐ │
│  │ dsh web                 │  │ agent-infra/sandbox     │ │
│  │   port 8080 (main UI)   │  │   PUBLIC_PORT=8090      │ │
│  │   DSH_ALLOW_ALL_IFACES  │  │   MCP_HUB_PORT=8079     │ │
│  │   DSH_WEB_PASSWORD=…    │  │   GEM_SERVER_PORT=8088  │ │
│  │                         │  │   VNC_PORT=5900         │ │
│  │ mcp-resources row ──────┼──┼─► http://127.0.0.1:8079│ │
│  │ web-fetch-http row ─────┼──┼─► http://127.0.0.1:8090│ │
│  │                         │  │   /v1/file, /v1/shell,  │ │
│  │                         │  │   /v1/browser, etc.    │ │
│  └─────────────────────────┘  └─────────────────────────┘ │
│ Both share /home/gem (sandbox WORKSPACE).                 │
└──────────────────────────────────────────────────────────┘
                       │
                       ▼
            Exposed host ports
            8080  → dsh web UI (main entry)
            8090  → sandbox web admin (VNC, code-server, /docs)
            5900  → sandbox VNC viewer (optional)
```

Both processes run in one container. They share `localhost` and the sandbox's `WORKSPACE` directory (`/home/gem` by default). The entrypoint script starts the sandbox in the background, waits for it to be reachable, then exec's dsh in the foreground so that signals (`docker stop`, Ctrl+C) reach dsh and the entrypoint propagates shutdown to the sandbox.

## Decisions

| Decision | Value | Why |
|---|---|---|
| Base image | `ghcr.io/agent-infra/sandbox:1.11.0` | Pinned, reproducible, no need to track `latest` |
| dsh listen port | 8080 | Main service (user's hard requirement) |
| Sandbox `PUBLIC_PORT` | 8090 | Frees 8080 for dsh; admin UI still reachable |
| MCP wiring | dsh `mcp-resources` → `http://127.0.0.1:8079` | Direct MCP hub, no proxy hop |
| HTTP API wiring | dsh `web-fetch-http` → `http://127.0.0.1:8090` | Lets dsh call file/shell/browser/jupyter directly |
| Shared workspace | `/home/gem` (sandbox `WORKSPACE`) | Sandbox already writes there; dsh reads/writes via the HTTP API |
| Pre-baked offline bundles | `agent-team-profile`, `auto-review` | Unchanged from current behavior; entrypoint still pre-populates the web profile |
| Auth | `DSH_WEB_PASSWORD` env var (Basic Auth on dsh) | Unchanged from current behavior; sandbox auth (`SANDBOX_API_KEY`) is independent |
| Telemetry | `DSH_TELEMETRY_DISABLED=1` | Unchanged |
| Process model | One container, two processes, foreground/background | Simpler than s6-overlay; signal propagation is explicit in the entrypoint script |

## Components

### 1. `Dockerfile` (modified)

Multi-stage build. Stage 1 builds dsh from source on `node:22-slim`; stage 2 is the sandbox image with dsh layered on top.

```dockerfile
# ---- Stage 1: build dsh ----
FROM node:22-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential python3 make git \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@11.7.0 --activate

WORKDIR /app
COPY . .
RUN pnpm install --frozen-lockfile \
    && pnpm run build:native-system \
    && pnpm run build:lib:host \
    && pnpm run build:lib:client \
    && pnpm run build:web

# ---- Stage 2: dsh on top of sandbox ----
FROM ghcr.io/agent-infra/sandbox:1.11.0

# The published sandbox image runs as a non-root user; the dsh install step
# needs root for apt-get, corepack, and writing into /app. Switch back to the
# sandbox user at the end if the image documents one; otherwise root is
# acceptable for this self-contained deployment.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@11.7.0 --activate
WORKDIR /app
COPY --from=builder /app /app
COPY scripts/entrypoint-sandbox.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# dsh on 8080 (main); sandbox on 8090 (admin UI); MCP hub on 8079 stays internal
ENV PUBLIC_PORT=8090 \
    MCP_HUB_PORT=8079 \
    GEM_SERVER_PORT=8088 \
    CODE_SERVER_PORT=8200 \
    DSH_ALLOW_ALL_INTERFACES=1 \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_HOME=/dsh-home \
    NODE_ENV=production

EXPOSE 8080 8090

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/').catch(()=>process.exit(1))"

# No CMD — the entrypoint script drives both processes itself. Users can
# still override CMD if they need to launch a non-web dsh subcommand, but
# the default is the web profile.
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["web", "--host", "0.0.0.0", "--port", "8080", "--no-open"]
```

### 2. `scripts/entrypoint-sandbox.sh` (new; replaces `scripts/entrypoint-web.sh`)

```sh
#!/bin/sh
# Docker entrypoint for the dsh-on-sandbox image.
#
# Starts the agent-infra/sandbox service in the background, waits for
# its admin API to answer, pre-creates the dsh web profile (with the
# offline-bundle list and the sandbox-aware MCP/HTTP integration), and
# exec's the dsh web command in the foreground.
#
# On SIGTERM/SIGINT, propagates the signal to the sandbox PID so
# `docker stop` cleanly tears down both processes.

set -eu

# The published image's entrypoint is /opt/gem/run.sh. It honors
# PUBLIC_PORT, MCP_HUB_PORT, and the other env vars baked into the
# Dockerfile, so we can start it under the same env and rely on it
# binding 8090 for the admin API.
SANDBOX_ENTRYPOINT=/opt/gem/run.sh
SANDBOX_PID_FILE=/tmp/dsh-sandbox.pid

# Start the sandbox in the background. The env vars PUBLIC_PORT=8090,
# MCP_HUB_PORT=8079, etc. are inherited from the Dockerfile.
"$SANDBOX_ENTRYPOINT" &
SANDBOX_PID=$!
echo "$SANDBOX_PID" > "$SANDBOX_PID_FILE"

# Wait for the sandbox's admin API to answer on 8090. The sandbox
# image's WAIT_PORTS=8091 means it waits for the gem server before
# starting its admin server; allow up to 60 s for the full stack.
SANDBOX_READY=0
for _ in $(seq 1 60); do
  if node -e "fetch('http://127.0.0.1:8090/v1/sandbox').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    SANDBOX_READY=1
    break
  fi
  # If the sandbox died, give up immediately
  if ! kill -0 "$SANDBOX_PID" 2>/dev/null; then
    echo "dsh-entrypoint: sandbox process exited before becoming ready" >&2
    exit 1
  fi
  sleep 1
done
if [ "$SANDBOX_READY" -ne 1 ]; then
  echo "dsh-entrypoint: sandbox did not become ready within 60 s" >&2
  kill -TERM "$SANDBOX_PID" 2>/dev/null || true
  exit 1
fi

# Pre-create the dsh web profile (offline bundles + sandbox integration)
PROFILE="web"
PROFILE_DIR="${DSH_HOME}/profiles/${PROFILE}"
mkdir -p "${PROFILE_DIR}"

if [ ! -f "${PROFILE_DIR}/package.json" ]; then
  # Ship the same offline-friendly bundle list as the standalone image
  # (dsh-base + dsh-web-app plus agent-team-profile and auto-review).
  # The cordis patch layer below re-enables web-fetch-http and adds an
  # mcp-resources row pointing at the sandbox's MCP hub. The exact
  # bundle names will be confirmed during implementation by grepping
  # packages/bundle/ and packages/mcp/.
  if [ "${DSH_OFFLINE_BUNDLES:-install}" = "install" ]; then
    BUNDLES='[
      "@deepseek-ai/dsh-base",
      "@deepseek-ai/dsh-web-app",
      "@deepseek-ai/dsh-experimental-agent-team-profile",
      "@deepseek-ai/dsh-experimental-auto-review"
    ]'
  else
    BUNDLES='[
      "@deepseek-ai/dsh-base",
      "@deepseek-ai/dsh-web-app"
    ]'
  fi

  cat > "${PROFILE_DIR}/package.json" <<EOF
{
  "name": "dsh-profile-${PROFILE}",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": ${BUNDLES}
    }
  }
}
EOF

  cat > "${PROFILE_DIR}/pnpm-workspace.yaml" <<EOF
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false
EOF

  # Sandbox-aware patch layer. The shape here is provisional; the
  # implementation will replace it with the actual schema of the
  # mcp-resources and web-fetch-http rows.
  cat > "${PROFILE_DIR}/cordis.patch.yml" <<'EOF'
[]
EOF
fi

# Signal propagation: forward SIGTERM/SIGINT to the sandbox PID so
# `docker stop` cleanly tears down both processes.
trap 'kill -TERM "$SANDBOX_PID" 2>/dev/null || true; wait "$SANDBOX_PID" 2>/dev/null || true' TERM INT

exec node --import tsx/esm apps/cli/src/bin.ts "$@"
```

The full implementation will polish this script and replace the empty `cordis.patch.yml` with the real schema for the MCP and HTTP rows (verified against `packages/mcp/` and `packages/web/`).

### 3. Sandbox integration rows in dsh

The dsh web-app's `cordis.patch.yml` (in `packages/bundle/web-app/cordis.patch.yml`) currently disables several cloud-only rows. The image's `entrypoint-sandbox.sh` writes a *profile-level* `cordis.patch.yml` (in `${DSH_HOME}/profiles/web/`) that:

- **Re-enables `web-fetch-http`** (currently disabled in the web-app's offline-deployment patch) — scoped to `127.0.0.1:8090` only via `allowedHosts`.
- **Adds an `mcp-resources` row** (or its actual shipped name) pointing at the sandbox's MCP hub at `127.0.0.1:8079` via streamable-HTTP transport.

The exact bundle names will be confirmed during implementation by grepping `packages/bundle/` and `packages/mcp/`.

### 4. `.dockerignore` (modified)

Add `.git/HEAD` and `.git/refs/heads/*` to the allowlist so the desktop bundle step's `git rev-parse HEAD` succeeds inside the builder stage. The rest of the build context stays the same.

```
node_modules
.git
.claude
.agents
benchmarks
.LEGACY
docs/**
!docs/persistence-schema.json
website/node_modules
website/public
website/.vitepress
website/tests
snapshots/**
!snapshots/session/session-query-spill
!snapshots/session/web-search-endpoint-guidance
!snapshots/session/loopback-fixture-server.mjs
!snapshots/session/loopback-fixture-server.spec.ts
```

### 5. `scripts/entrypoint-web.sh` (removed)

The new `scripts/entrypoint-sandbox.sh` supersedes it. The old file is removed in the same commit. There is no longer a non-sandbox image variant in this repository; if the user wants one, it can be restored from git history.

## Data flow

1. User starts the container: `docker run -p 8080:8080 -p 8090:8090 brycehuang/deepseek-harness:<tag>`.
2. The entrypoint script starts the sandbox process in the background, inheriting the Dockerfile's `PUBLIC_PORT=8090` env var.
3. The script polls `http://127.0.0.1:8090/v1/sandbox` until it returns 2xx.
4. The script writes the dsh web profile (with the offline-bundle list and sandbox integration rows) under `${DSH_HOME}/profiles/web/`.
5. The script exec's `dsh web` in the foreground, binding 8080.
6. The user visits `http://localhost:8080`. dsh's UI loads; behind the scenes, the model can now call:
   - Sandbox MCP tools (browser, file, shell, markitdown) via `mcp-resources` at `127.0.0.1:8079`.
   - Sandbox HTTP APIs (file read/write, shell exec, browser screenshot, jupyter execute) via `web-fetch-http` scoped to `127.0.0.1:8090`.
7. On `docker stop`, dsh gets SIGTERM, the entrypoint's trap propagates SIGTERM to the sandbox PID, both processes exit, the container stops.

## Error handling

| Failure | Behavior |
|---|---|
| Sandbox fails to start within 60s | Script logs and exits 1 (container fails) |
| Sandbox `/v1/sandbox` returns 5xx during poll | Script retries up to 60 times (1s interval), then exits 1 |
| dsh web fails to bind 8080 | dsh exits non-zero; the entrypoint's `exec` propagates; the container stops |
| dsh web's `mcp-resources` row can't reach 127.0.0.1:8079 | dsh logs a warning at fiber activation; the row fails to load. The web UI still works for non-sandbox tools. |
| dsh web's `web-fetch-http` row can't reach 127.0.0.1:8090 | Same as above: warn + fail-loud at activation |
| `docker stop` sends SIGTERM | The entrypoint's trap forwards it to the sandbox PID, then `exec` propagates to dsh |

## Testing

- **Build verification:** CI workflow (`.github/workflows/docker-build.yml`) builds the image and pushes it. The `git rev-parse HEAD` step inside the builder must succeed (allowlist fix above).
- **Smoke test (local):** `docker run --rm -p 8080:8080 -p 8090:8090 brycehuang/deepseek-harness:dev`. Visit `http://localhost:8080` — dsh UI loads, Basic Auth prompt appears if `DSH_WEB_PASSWORD` is set. Visit `http://localhost:8090/v1/sandbox` — sandbox admin responds.
- **Integration test (local):** In the running container, dsh's MCP integration should be able to list the sandbox's MCP tools (`browser`, `file`, `shell`, `markitdown`). The `web-fetch-http` row should be able to `GET http://127.0.0.1:8090/v1/sandbox` and return a 2xx response.
- **End-to-end (manual):** From the dsh web UI, ask the model to "list files in the workspace" — it should call the sandbox's `/v1/file/list` (or the file MCP tool) and return results.
- **Teardown test:** `docker stop` should shut down both processes within the 10s default grace period.

## Verification

1. Build the image locally: `docker build -t dsh-sandbox:dev .` — should succeed without `git rev-parse` errors.
2. Run the container: `docker run --rm -p 8080:8080 -p 8090:8090 dsh-sandbox:dev` — both dsh and sandbox should come up.
3. From the host, `curl http://localhost:8080/` should return the dsh web app (200, or 401 if `DSH_WEB_PASSWORD` is set).
4. From the host, `curl http://localhost:8090/v1/sandbox` should return the sandbox's environment info (or 401 if `SANDBOX_API_KEY` is set).
5. Inside the container (`docker exec`), `curl http://127.0.0.1:8079` should reach the sandbox's MCP hub (or whatever the MCP hub's health endpoint is — to be confirmed during implementation).
6. From the dsh web UI, run a model task that uses a sandbox tool (e.g., "list files in the workspace"). The model should report success without ever contacting the public internet.

## Files modified / created

| File | Action |
|---|---|
| `Dockerfile` | Modify: change production stage FROM to `ghcr.io/agent-infra/sandbox:1.11.0`; add PUBLIC_PORT, MCP_HUB_PORT, etc env vars; copy `entrypoint-sandbox.sh`; expose 8090 in addition to 8080 |
| `scripts/entrypoint-sandbox.sh` | Create: starts sandbox, waits for readiness, pre-creates dsh web profile with offline bundles and sandbox integration rows, exec's dsh web |
| `scripts/entrypoint-web.sh` | Delete: superseded by `entrypoint-sandbox.sh` |
| `.dockerignore` | Modify: allowlist `.git/HEAD` and `.git/refs/heads/*` so the desktop bundle step's `git rev-parse HEAD` succeeds |
| `.github/workflows/docker-build.yml` | Modify (or keep): no structural change expected; the build context and Dockerfile path are unchanged |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Sandbox image's ENTRYPOINT doesn't honor `PUBLIC_PORT` env var | Test during implementation; if it doesn't, override the entrypoint with a shell that sets up a `socat` forwarder from 8080 to 8090 (or, conversely, from 8090 to 8080 and have dsh listen on 8081) |
| Sandbox image runs as a non-root user, and the dsh install step needs root | `USER root` for `apt-get`, `corepack`, and writing into `/app`. If the sandbox user cannot write to `/app`, keep root for the entrypoint. The published image's `WORKSPACE` (`/home/gem`) is unrelated and unaffected. |
| `mcp-resources` and `web-fetch-http` bundle names don't match my guesses | Implementation will grep `packages/bundle/` and `packages/mcp/` to find the actual names and config schemas |
| `web-fetch-http` is currently disabled in the offline patch | The profile-level patch re-enables it scoped to `127.0.0.1:8090` only; the offline-deployment patch's disable is for the *web-app* default, and the profile-level patch is layered on top |
| MCP transport: dsh's `mcp-resources` row may expect stdio, not HTTP | Implementation will read the row's config schema; if it doesn't support HTTP, we wrap the sandbox's MCP hub in a small stdio shim (a Node script in the image) |
| Two processes in one container (process supervision) | The entrypoint script handles signal propagation explicitly; both processes die on `docker stop`. This is simpler than s6-overlay for a two-process container. |
| Sandbox image's `WORKSPACE` and dsh's `DSH_HOME` differ | Sandbox uses `/home/gem`; dsh uses `/dsh-home`. We keep them separate; dsh calls into the sandbox's HTTP API for file ops and never touches `/home/gem` directly. The user mounts `/dsh-home` for dsh's persistence and `/home/gem` (or the sandbox's volume) for the sandbox's persistence separately. |
| Pre-existing `git rev-parse` build failure | Fixed by the `.dockerignore` allowlist change in step 4 above. |

## Out of scope

- Multi-arch builds (linux/amd64 vs. arm64). The current workflow doesn't do them, and the sandbox image's supported architectures aren't verified yet.
- Bundling the image with a non-sandbox dsh variant. The user asked for the sandbox-based image; the previous image can be re-derived from git history if needed.
- Auto-configuring the sandbox's `SANDBOX_API_KEY` from dsh. They are independent auth systems; the user sets both via env vars.
- Persisting `/home/gem` (sandbox workspace) — the user mounts it separately.
- Tearing down the image's pre-baked offline bundles if the user disables them. The entrypoint writes the profile once and never overwrites; the user can edit `${DSH_HOME}/profiles/web/cordis.patch.yml` themselves.
