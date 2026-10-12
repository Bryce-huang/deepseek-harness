# dsh Docker Image with `ghcr.io/agent-infra/sandbox` as the Runtime Base

**Date:** 2026-10-09 **Status:** Approved (design); implementation pending **Owner:** brycehuang **Replaces:** the prior `node:22-slim` production stage in `Dockerfile` (and the existing `scripts/entrypoint-web.sh`)

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
| Base image | `ghcr.io/agent-infra/sandbox:1.11.0` (default) + `:latest` tracking variant | CI matrix builds both via the `SANDBOX_IMAGE` build arg: `latest`/`<date>-<sha>` tags for the pinned base, `sandbox-latest`/`<date>-<sha>-sandbox-latest` for the tracking base |
| dsh listen port | 8080 | Main service (user's hard requirement) |
| Sandbox `PUBLIC_PORT` | 8090 | Frees 8080 for dsh; admin UI still reachable |
| MCP wiring | dsh `mcp-resources` → `http://127.0.0.1:8079` | Direct MCP hub, no proxy hop |
| HTTP API wiring | dsh `web-fetch-http` → `http://127.0.0.1:8090` | Lets dsh call file/shell/browser/jupyter directly |
| Shared workspace | `/home/gem` (sandbox `WORKSPACE`) | Sandbox already writes there; dsh reads/writes via the HTTP API |
| Pre-baked offline bundles | `agent-team-profile`, `auto-review` | Unchanged from current behavior; entrypoint still pre-populates the web profile |
| Auth | `DSH_WEB_PASSWORD` env var (Basic Auth on dsh) | Unchanged from current behavior; sandbox auth (`SANDBOX_API_KEY`) is independent |
| Telemetry | `DSH_TELEMETRY_DISABLED=1` | Unchanged |
| Process model | One container, two processes, foreground/background | Simpler than s6-overlay; signal propagation is explicit in the entrypoint script |
| App user | uid 6001 / gid 6000 everywhere | The deployment runs workloads as the app user: the sandbox's `run.sh` builds its internal user from `USER_UID`/`USER_GID` (set to 6001/6000), and the entrypoint drops dsh to the same ids via numeric `setpriv` when the container starts as root |

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
# needs root for apt-get, corepack, and writing into /app. The final image
# defaults to the app user uid 6001 / gid 6000 (see the sudo re-elevation
# decision in the risks table); the install runs as root before that.
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

The image's `entrypoint-sandbox.sh` writes a *profile-level* `cordis.patch.yml` (in `${DSH_HOME}/profiles/web/`) whose single `insert` adds an `@deepseek-ai/dsh-mcp-client` row (the package is a root devDependency, so its symlink is already under `/app/node_modules`; the row shape follows `docs/user/guide/mcp-memory.md`):

```yaml
- insert:
    - id: mcp-sandbox
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: sandbox
        transport: streamable-http
        url: 'http://127.0.0.1:8090/mcp'
        # headers: { X-AIO-API-Key: ... } written only when SANDBOX_API_KEY is set
```

The URL defaults to the sandbox's documented public MCP path (`{public}/mcp`, streamable-HTTP) and is overridable at first boot via `DSH_SANDBOX_MCP_URL`. `web-fetch-http` stays disabled: the plugin's Config has no host-allowlist field, `tool-web` is preset-owned on the web profile, and the MCP row alone carries the direct-operation requirement (file/shell/browser/markitdown tools).

### 4. `.dockerignore` (unchanged)

The build context keeps excluding `.git`. The desktop bundle step's `git rev-parse HEAD` dependency is removed instead: `scripts/client-build-environment.ts` runs git only inside `repositoryClientBuildEnvironment`, which `apps/desktop/tsdown.config.ts` calls only when `DSH_CLIENT_VERSION` is unset. The builder stage sets `DSH_CLIENT_VERSION` (default `0.2.1-alpha.1`) and CI passes the real commit through the `DSH_CLIENT_COMMIT_HASH` build arg, so no `.git` files enter the context and `git` leaves the apt install.

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

| Risk | Resolution (smoke-tested 2026-10-09) |
|---|---|
| Sandbox image's ENTRYPOINT doesn't honor `PUBLIC_PORT` env var | **Resolved:** run.sh honors it — "The sandbox is listening on 0.0.0.0:8090" |
| Sandbox image runs as a non-root user, and the dsh install step needs root | **Resolved:** install runs as root in stage 2; the final image defaults to `USER 6001:6000` (app user) |
| `mcp-resources` and `web-fetch-http` bundle names don't match my guesses | **Resolved:** integration uses an `@deepseek-ai/dsh-mcp-client` insert row (shape per `docs/user/guide/mcp-memory.md`); `web-fetch-http` dropped (no host-allowlist config) |
| `web-fetch-http` is currently disabled in the offline patch | **Resolved by dropping it** — the MCP row carries the sandbox integration |
| MCP transport: dsh's row may expect stdio, not HTTP | **Resolved:** `mcp-client` supports `streamable-http`; the sandbox's `/mcp` answered a proper `initialize` POST with 200 ("Sandbox MCP Tools" 2.14.7) |
| Two processes in one container (process supervision) | **Resolved:** entrypoint starts run.sh in the background, exec's dsh as PID 1; `docker stop` tears down both in 0.5 s |
| Sandbox image's `WORKSPACE` and dsh's `DSH_HOME` differ | Kept separate by design: dsh persists under `/dsh-home`, sandbox under `/home/gem`; file access goes through the MCP/HTTP APIs |
| Pre-existing `git rev-parse` build failure | **Resolved:** `DSH_CLIENT_VERSION` env in the builder skips the git path entirely; `.dockerignore` unchanged |
| `docker run --user 6001:6000` (non-root container start) | **Resolved (2026-10-10), sudo re-elevation:** the image pre-creates `gem` (uid 6001 / gid 6000) with a `NOPASSWD:SETENV` sudoers entry and defaults to `USER 6001:6000`; a non-root entrypoint runs `sudo -n -E USER=gem HOME=/home/gem /opt/gem/run.sh` so the vendor boot keeps its root-time setup while the services it spawns run as gem. dsh is PID 1 as uid 6001 in both start modes; root persists only in the vendor's supervisord/nginx master (their trust model, same as the deployment platform's own sandbox images). Both modes smoke-tested 2026-10-10: 8080→401, 8090→200, MCP `initialize` OK |
| dsh workspace under the app user | **Resolved:** the entrypoint cds to `/home/gem` (shared with the sandbox) before exec and pins `TSX_TSCONFIG_PATH=/app/tsconfig.json` plus absolute tsx/CLI paths — the cwd moves every `process.cwd()`-derived workspace root at once without breaking the source-launch module resolution |

## Out of scope

- Multi-arch builds (linux/amd64 vs. arm64). The current workflow doesn't do them, and the sandbox image's supported architectures aren't verified yet.
- Bundling the image with a non-sandbox dsh variant. The user asked for the sandbox-based image; the previous image can be re-derived from git history if needed.
- Auto-configuring the sandbox's `SANDBOX_API_KEY` from dsh. They are independent auth systems; the user sets both via env vars.
- Persisting `/home/gem` (sandbox workspace) — the user mounts it separately.
- Tearing down the image's pre-baked offline bundles if the user disables them. The entrypoint writes the profile once and never overwrites; the user can edit `${DSH_HOME}/profiles/web/cordis.patch.yml` themselves.
