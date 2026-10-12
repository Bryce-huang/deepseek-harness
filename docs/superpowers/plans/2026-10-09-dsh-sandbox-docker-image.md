# dsh-on-sandbox Docker Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the dsh Docker image on `ghcr.io/agent-infra/sandbox:1.11.0` so dsh (port 8080, main service) directly operates the sandbox's services (file/shell/browser/markitdown) through an MCP connection, with the sandbox's own admin UI moved to port 8090.

**Architecture:** One container, two processes. A new entrypoint script starts the sandbox's original `/opt/gem/run.sh` in the background with `PUBLIC_PORT=8090`, waits for its HTTP API, pre-creates the dsh web profile whose `cordis.patch.yml` inserts an `@deepseek-ai/dsh-mcp-client` row pointing at the sandbox's streamable-HTTP MCP endpoint (`http://127.0.0.1:8090/mcp`), then exec's dsh web on 8080 in the foreground. The builder stage fixes the long-standing `git rev-parse HEAD` CI failure by setting `DSH_CLIENT_VERSION` (verified: `apps/desktop/tsdown.config.ts` only calls git when that env var is unset).

**Tech Stack:** Docker multi-stage build, POSIX sh, Cordis patch layers (`cordis.patch.yml`), GitHub Actions docker/build-push-action.

**Spec:** `docs/superpowers/specs/2026-10-09-dsh-sandbox-docker-image-design.md`

**Deviations from the spec (verified during planning):**
1. **Git fix via env var, not `.dockerignore` allowlist.** `scripts/client-build-environment.ts:54` runs `git rev-parse HEAD` only inside `repositoryClientBuildEnvironment`, which `apps/desktop/tsdown.config.ts:26-28` calls only when `DSH_CLIENT_VERSION` is unset. Setting the env var removes the git dependency entirely — no `.git` allowlist needed, and `git` leaves the apt install.
2. **No `web-fetch-http` re-enable.** The spec's `allowedHosts` field does not exist in that plugin's Config (`packages/web/web-fetch-http/src/index.ts:32-49` — only size/timeout limits). Re-enabling it would give unrestricted fetch, contradicting the offline-first patch, and `tool-web` is preset-owned on the web profile anyway. The MCP row alone satisfies "dsh 直接操作 sandbox 的服务" (file/shell/browser/markitdown tools ride MCP).
3. **MCP URL is the documented public endpoint** `http://127.0.0.1:8090/mcp` (sandbox docs: "Endpoint: Included in `/mcp`", streamable-HTTP), overridable via `DSH_SANDBOX_MCP_URL` at first boot. The internal hub port 8079 has an undocumented path; the public `/mcp` path is the stable contract.

---

### Task 1: Fix the builder's git dependency with DSH_CLIENT_VERSION

**Files:**
- Modify: `Dockerfile:1-11` (builder stage header)

- [x] **Step 1: Edit the builder stage**

Replace lines 1-11 of `Dockerfile`:

```dockerfile
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
```

(Keep the existing `COPY . .` and the `RUN pnpm install ...` block below unchanged.)

Changes: drop `git` from apt-get (only needed for rev-parse, now bypassed); add the two ARGs and ENV.

- [x] **Step 2: Verify the build context has no .git and the env path is taken**

Run: `grep -c git Dockerfile`
Expected: `0` (no git references left in the builder install)

Run: `sed -n '26,28p' apps/desktop/tsdown.config.ts`
Expected output confirms the guard:
```ts
const clientEnvironment = resolveClientBuildEnvironment(process.env.DSH_CLIENT_VERSION === undefined
  ? repositoryClientBuildEnvironment(REPOSITORY_ROOT, process.env)
  : process.env)
```

- [x] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "fix(docker): satisfy client build metadata via env instead of git"
```

---

### Task 2: Move the production stage onto the sandbox base

**Files:**
- Modify: `Dockerfile` (production stage, currently lines 25-60)

- [x] **Step 1: Replace the whole production stage**

Replace everything from `# ---- Stage 2: Production ----` to the end of file with:

```dockerfile
# ---- Stage 2: Production on the agent-infra sandbox ----
# The published sandbox image (ENTRYPOINT /opt/gem/run.sh, default PUBLIC_PORT
# 8080) carries the browser, VNC, code-server, jupyter, shell/file MCP stack.
# dsh becomes the container's main service on 8080; the sandbox's public
# listener moves to 8090. Its MCP endpoint is then
# http://127.0.0.1:8090/mcp (streamable-HTTP), reached by the profile patch
# the entrypoint writes on first boot.
FROM ghcr.io/agent-infra/sandbox:1.11.0

# Root for the install steps below: apt (git is gone, but corepack needs a
# writable install root) and writing /app. The sandbox's own run.sh handles
# its user switching internally.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@11.7.0 --activate

WORKDIR /app

# Copy the entire built tree (source + lib + node_modules).
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
ENV PUBLIC_PORT=8090 \
    DSH_ALLOW_ALL_INTERFACES=1 \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_HOME=/dsh-home \
    NODE_ENV=production \
    DSH_SANDBOX_MCP_URL=http://127.0.0.1:8090/mcp

EXPOSE 8080 8090

# dsh binds 8080 only after the sandbox stack is up, so the start period
# covers the sandbox boot too (its own WAIT_PORTS gate plus service starts).
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/').catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["web", "--host", "0.0.0.0", "--port", "8080", "--no-open"]
```

Notes baked into this stage:
- `DSH_SANDBOX_MCP_URL` default matches the documented endpoint; the entrypoint reads it when writing the profile patch.
- Health-check start period raised to 120s for the sandbox boot.
- No `git` install in production (nothing needs it).

- [x] **Step 2: Syntax-sanity check**

Run: `docker build --check .` (BuildKit lint; if the local Docker lacks `--check`, skip with a note)
Expected: no errors (warnings about legacy syntax acceptable)

- [x] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat(docker): base the runtime image on agent-infra/sandbox 1.11.0"
```

---

### Task 3: Create scripts/entrypoint-sandbox.sh

**Files:**
- Create: `scripts/entrypoint-sandbox.sh`

- [x] **Step 1: Write the entrypoint**

```sh
#!/bin/sh
# Docker entrypoint for the dsh-on-sandbox image.
#
# The container runs two processes: the agent-infra sandbox stack
# (/opt/gem/run.sh, the published image's own entrypoint, here in the
# background with PUBLIC_PORT=8090) and the dsh web command (foreground,
# port 8080). This script starts the sandbox, waits until its HTTP API
# answers, pre-creates the dsh web profile on first boot, and exec's dsh so
# signals reach it directly; a trap forwards SIGTERM/SIGINT to the sandbox.
#
# First-boot profile contents:
# - the offline-friendly optional bundles (same list the standalone image
#   shipped; DSH_OFFLINE_BUNDLES=skip keeps the plain web template),
# - an @deepseek-ai/dsh-mcp-client row connecting to the sandbox's MCP
#   endpoint (DSH_SANDBOX_MCP_URL, default http://127.0.0.1:8090/mcp),
#   authenticated with X-AIO-API-Key when SANDBOX_API_KEY is set.
# The profile is written once; later boots keep user edits. Changing the
# MCP URL or key after first boot means editing (or removing)
# $DSH_HOME/profiles/web and rebooting the container.
#
# The cloud-only base rows (DeepSeek account, web search, plugin registry,
# etc.) stay disabled by the web-app's cordis.patch.yml — see
# packages/bundle/web-app/cordis.patch.yml.

set -eu

SANDBOX_ENTRYPOINT=/opt/gem/run.sh
SANDBOX_PUBLIC_PORT="${PUBLIC_PORT:-8090}"

# ── start the sandbox stack in the background ────────────────────────────────
# run.sh inherits this process's environment: PUBLIC_PORT=8090 from the
# Dockerfile, plus any SANDBOX_*/WORKSPACE overrides the user passed.
"$SANDBOX_ENTRYPOINT" &
SANDBOX_PID=$!

# ── wait for the sandbox's HTTP API ─────────────────────────────────────────
# Any HTTP response counts as ready: with SANDBOX_API_KEY set the probe gets
# 401, which still proves the listener is up. The port interpolates from the
# shell, so the node child needs no exported state.
SANDBOX_READY=0
i=1
while [ "$i" -le 120 ]; do
  if node -e "fetch('http://127.0.0.1:${SANDBOX_PUBLIC_PORT}/v1/sandbox').then(() => process.exit(0)).catch(() => process.exit(1))" 2>/dev/null; then
    SANDBOX_READY=1
    break
  fi
  if ! kill -0 "$SANDBOX_PID" 2>/dev/null; then
    echo "dsh-entrypoint: sandbox process exited before becoming ready" >&2
    exit 1
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$SANDBOX_READY" -ne 1 ]; then
  echo "dsh-entrypoint: sandbox did not become ready within 120 s" >&2
  kill -TERM "$SANDBOX_PID" 2>/dev/null || true
  exit 1
fi
echo "dsh-entrypoint: sandbox ready on port ${SANDBOX_PUBLIC_PORT}"

# ── first-boot profile creation ─────────────────────────────────────────────
PROFILE="web"
PROFILE_DIR="${DSH_HOME}/profiles/${PROFILE}"
mkdir -p "${PROFILE_DIR}"

if [ ! -f "${PROFILE_DIR}/package.json" ]; then
  # The optional bundles that declare dsh.bundle.patch: Agent Teams profile
  # and Auto review. ptc-runtime-python is a runtime substitute for
  # dsh-base's ptc-runtime row, not a bundle, so it is not listed; it ships
  # in /app/node_modules for anyone switching the active PTC runtime.
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

  # pnpm-workspace.yaml is required for the profile's pnpm operations
  # (install, plugin add) to resolve packages through the workspace's
  # hoisted node_modules.
  cat > "${PROFILE_DIR}/pnpm-workspace.yaml" <<EOF
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false
EOF

  # The sandbox MCP row. dsh-mcp-client is symlinked into /app/node_modules
  # by the build's pnpm install (root devDependency), so the loader resolves
  # it offline. The API-key header is written only when the sandbox asks for
  # one, so default boots carry no credentials.
  MCP_URL="${DSH_SANDBOX_MCP_URL:-http://127.0.0.1:8090/mcp}"
  if [ -n "${SANDBOX_API_KEY:-}" ]; then
    MCP_HEADERS="        headers:
          X-AIO-API-Key: '${SANDBOX_API_KEY}'"
  else
    MCP_HEADERS=""
  fi

  cat > "${PROFILE_DIR}/cordis.patch.yml" <<EOF
# Written once by the image entrypoint on first boot (see
# scripts/entrypoint-sandbox.sh). Edits persist across reboots.
- insert:
    - id: mcp-sandbox
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: sandbox
        transport: streamable-http
        url: '${MCP_URL}'
${MCP_HEADERS}
EOF

  echo "dsh-entrypoint: initialized ${PROFILE} profile with sandbox MCP row (${MCP_URL})"
fi

# ── signal propagation ──────────────────────────────────────────────────────
# dsh runs as this script's replacement (exec), so TERM/INT reach it
# directly; the trap fires first only in the pre-exec window. The sandbox
# keeps running under dsh as an orphan child of PID 1's reaper once we exec.
trap 'kill -TERM "$SANDBOX_PID" 2>/dev/null || true' TERM INT

exec node --import tsx/esm apps/cli/src/bin.ts "$@"
```

- [x] **Step 2: Make it executable and syntax-check**

Run: `chmod +x scripts/entrypoint-sandbox.sh && sh -n scripts/entrypoint-sandbox.sh`
Expected: no output (clean syntax)

Run: `command -v shellcheck >/dev/null && shellcheck scripts/entrypoint-sandbox.sh || echo "shellcheck unavailable"`
Expected: no findings, or "shellcheck unavailable"

- [x] **Step 3: Commit**

```bash
git add scripts/entrypoint-sandbox.sh
git commit -m "feat(docker): sandbox-supervising entrypoint with MCP profile wiring"
```

---

### Task 4: Remove the superseded entrypoint-web.sh

**Files:**
- Delete: `scripts/entrypoint-web.sh`

- [x] **Step 1: Confirm nothing else references it**

Run: `grep -rn "entrypoint-web" --include="*" . 2>/dev/null | grep -v node_modules | grep -v ".git/"`
Expected: only `Dockerfile` (already updated in Task 2 to copy `entrypoint-sandbox.sh`) — no other references.

- [x] **Step 2: Delete and commit**

```bash
git rm scripts/entrypoint-web.sh
git commit -m "chore(docker): drop the standalone-web entrypoint superseded by the sandbox image"
```

---

### Task 5: Pass the real commit hash through CI

**Files:**
- Modify: `.github/workflows/docker-build.yml` (Build and push step)

- [x] **Step 1: Add build-args to the build-push step**

In `.github/workflows/docker-build.yml`, change:

```yaml
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.version.outputs.tag }}
            ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

to:

```yaml
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.version.outputs.tag }}
            ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          build-args: |
            DSH_CLIENT_COMMIT_HASH=${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [x] **Step 2: Validate the workflow YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/docker-build.yml'))" && echo OK`
Expected: `OK`

- [x] **Step 3: Commit**

```bash
git add .github/workflows/docker-build.yml
git commit -m "ci(docker): embed the build commit in client build metadata"
```

---

### Task 6: Local build and smoke test

**Files:** none (verification only)

- [x] **Step 1: Build the image**

Run: `docker build -t dsh-sandbox:dev .`
Expected: both stages succeed; the builder completes `pnpm run build:lib:host` without any `git rev-parse` error.

If the build fails at `corepack prepare` in the production stage (sandbox image's Node not shipping corepack), fall back to:
```dockerfile
RUN npm install -g pnpm@11.7.0
```
in place of the corepack line, and re-run.

- [x] **Step 2: Run the container**

Run:
```bash
docker run -d --name dsh-sandbox-smoke \
  --security-opt seccomp=unconfined --shm-size=2gb \
  -p 8080:8080 -p 8090:8090 dsh-sandbox:dev
```
Expected: container starts; `docker logs dsh-sandbox-smoke` shows `dsh-entrypoint: sandbox ready on port 8090` then `dsh-entrypoint: initialized web profile ...` then dsh's URL line.

- [x] **Step 3: Probe both services**

Run: `curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/`
Expected: `200` (or `401` when `DSH_WEB_PASSWORD` is set — re-test with `-e DSH_WEB_PASSWORD=x` and `curl -u :x` if so)

Run: `curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8090/v1/sandbox`
Expected: `200`

- [x] **Step 4: Verify the MCP endpoint and profile patch**

Run: `docker exec dsh-sandbox-smoke cat /dsh-home/profiles/web/cordis.patch.yml`
Expected: the `mcp-sandbox` insert row with `url: 'http://127.0.0.1:8090/mcp'`.

Run: `docker exec dsh-sandbox-smoke node -e "fetch('http://127.0.0.1:8090/mcp').then(r=>console.log('status',r.status)).catch(e=>console.log('err',e.message))"`
Expected: an HTTP status (any code — the endpoint answers; a streamable-HTTP MCP server typically 40x's a bare GET). If it errors with connection refused, inspect the sandbox's routing (`docker exec dsh-sandbox-smoke sh -c 'command -v ss >/dev/null && ss -ltnp || netstat -ltnp'`) and record the finding.

- [x] **Step 5: Verify teardown**

Run: `docker stop -t 15 dsh-sandbox-smoke && docker rm dsh-sandbox-smoke`
Expected: stops within the grace period (exit 0, no timeout kill message).

- [x] **Step 6: Record smoke results**

Append findings (especially any Step 4 endpoint correction) to this plan file as a "Smoke results" note under this task, and adjust `DSH_SANDBOX_MCP_URL` in `Dockerfile` + the entrypoint default if the documented path proved wrong. Commit any adjustment:

```bash
git add Dockerfile scripts/entrypoint-sandbox.sh
git commit -m "fix(docker): correct the sandbox MCP endpoint after smoke test"
```

---

### Task 7: Update the spec to match verified reality and push

**Files:**
- Modify: `docs/superpowers/specs/2026-10-09-dsh-sandbox-docker-image-design.md`

- [x] **Step 1: Amend the spec's provisional parts**

Edit the spec:
- Replace the `.dockerignore` allowlist section (section 4) with a note that the git dependency was removed via `DSH_CLIENT_VERSION` and `.dockerignore` is unchanged.
- Replace the "Sandbox integration rows" section (section 3) with the verified `mcp-sandbox` insert row and drop the `web-fetch-http` re-enable (reason: no host-allowlist config exists; MCP carries the integration).
- Refresh the Risks table rows that the smoke test resolved.

- [x] **Step 2: Commit and push the branch**

```bash
git add docs/superpowers/specs/2026-10-09-dsh-sandbox-docker-image-design.md docs/superpowers/plans/2026-10-09-dsh-sandbox-docker-image.md
git commit -m "docs: align the sandbox image spec and plan with verified behavior"
git push origin master
```

Pushing master triggers `.github/workflows/docker-build.yml`, which builds and pushes `brycehuang/deepseek-harness` (unique date+SHA tag plus `latest`) using the Docker Hub credentials already stored in repo secrets.

- [x] **Step 3: Confirm the CI image published**

Run: `gh run watch $(gh run list --workflow=docker-build.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status`
Expected: the workflow completes successfully.

---

## Verification summary

| Claim | Evidence task |
|---|---|
| Builder no longer needs `.git` | Task 1 + Task 6 Step 1 |
| Production image is sandbox 1.11.0 with dsh layered on | Task 2 + Task 6 Step 2 |
| Sandbox runs on 8090, dsh on 8080 | Task 6 Step 3 |
| Model gets sandbox tools over MCP | Task 6 Step 4 (endpoint + profile patch) |
| Clean shutdown of both processes | Task 6 Step 5 |
| CI publishes the image | Task 5 + Task 7 Step 3 |

---

## Smoke results (2026-10-09, local arm64)

- Builder: `build:lib:host` passed with **no git involvement** (`DSH_CLIENT_VERSION` env path confirmed; 0 git errors in the build log).
- One local-only fix folded into the Dockerfile: `npm_config_fetch_timeout=600000 npm_config_fetch_retries=5` on the install line — the `@openai/codex` platform tarball repeatedly stalled past pnpm's default fetch timeout on a slow link. No effect on CI.
- Sandbox stack: boots via `/opt/gem/run.sh`, honors `PUBLIC_PORT=8090` ("The sandbox is listening on 0.0.0.0:8090"), full supervisord tree RUNNING (browser MCP server, VNC, websocat, openbox).
- Entrypoint: "sandbox ready on port 8090" ~5 s after boot; profile patch written exactly as designed.
- dsh: binds 8080 as PID 1; bare `/` answers **401 (shipped per-boot token auth — the plan's "200" expectation was wrong)**; with `?token=…` it answers 303 (cookie-set redirect). One benign warning: `account-controller` pending on the offline-disabled `deepseekAccount`.
- MCP: bare GET → 406 (protocol headers required); proper `initialize` POST → **200, serverInfo "Sandbox MCP Tools" 2.14.7**, tools/prompts/resources capabilities.
- Teardown: `docker stop` completes in **0.49 s** — both processes exit with the container.
- `DSH_SANDBOX_MCP_URL` default (`http://127.0.0.1:8090/mcp`) verified correct; no adjustment needed.

## Smoke results (2026-10-10, non-root default start)

The image now defaults to `USER 6001:6000` (app user) and supports both start modes via sudo re-elevation — the pattern the deployment platform's own sandbox images use, replacing the earlier "start as root only" limitation:

- Default (`docker run`, entrypoint as 6001): the image's `gem ALL=(ALL) NOPASSWD:SETENV:ALL` sudoers entry lets the entrypoint run `sudo -n -E USER=gem HOME=/home/gem /opt/gem/run.sh`; the vendor boot keeps its root-time setup, spawns services as gem, and dsh execs directly — **PID 1 is dsh under uid 6001(gem)**.
- Root (`docker run --user 0`): boot runs directly as root; dsh drops via setpriv — PID 1 is dsh under uid 6001 as before.
- Both modes: 8080 → 401 (per-boot token auth), 8090 `/v1/sandbox` → 200, MCP `initialize` → 200; profile/MCP row written once on first boot.
- Root persists only in the vendor's supervisord and nginx master under either mode (the vendor's own trust model — its boot writes the same NOPASSWD sudoers grant for gem when started as root).

## Pivot (2026-10-12): Debian base, single amd64 image, CI-side verification

The sandbox-based all-in-one image is retired (`scripts/entrypoint-sandbox.sh` deleted; workflow matrix removed). The published image is now `debian:bookworm-slim` + a common dev toolchain (git, python3, latest Go, latest LTS JDK via Adoptium, Node.js 24 LTS via NodeSource), single service on 8080, app user 6001/6000 with no elevation anywhere. Builds and smoke verification (sign-in flow, toolchain versions) run exclusively in GitHub Actions on linux/amd64.
