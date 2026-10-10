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
# Everything runs as the deployment's app user, uid 6001 / gid 6000. A
# root-started container drops dsh to those ids (numeric setpriv) and runs
# the sandbox boot directly; a container started --user 6001:6000 exec's dsh
# directly and re-elevates the sandbox boot through the image's passwordless
# sudoers entry, since the boot's setup needs root. The services that boot
# spawns run as the app user either way.
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
# Dockerfile, plus any SANDBOX_*/WORKSPACE overrides the user passed. A
# non-root start goes through sudo (NOPASSWD:SETENV from the Dockerfile):
# the boot's setup needs root, USER/HOME stay pinned to the app user
# because sudo would otherwise retarget them at root.
if [ "$(id -u)" = "0" ]; then
  "$SANDBOX_ENTRYPOINT" &
else
  sudo -n -E USER=gem HOME=/home/gem "$SANDBOX_ENTRYPOINT" &
fi
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

# Hand dsh's state tree to the app user: the profile files above were written
# by whichever uid started the container, and dsh rewrites them at runtime.
if [ "$(id -u)" = "0" ]; then
  chown -R "${USER_UID:-6001}:${USER_GID:-6000}" "${DSH_HOME}"
fi

# ── signal propagation ──────────────────────────────────────────────────────
# dsh runs as this script's replacement (exec), so TERM/INT reach it
# directly; the trap covers only the pre-exec startup window. After exec,
# dsh is PID 1 and the sandbox dies with the container when it exits.
trap 'kill -TERM "$SANDBOX_PID" 2>/dev/null || true' TERM INT

# ── run dsh under the app user (uid 6001 / gid 6000) ────────────────────────
# The sandbox's run.sh has already created that uid from USER_UID/USER_GID
# and chowned /home/gem. dsh shares the sandbox workspace as its default
# cwd so dsh's file tools, the browser, and the shell all see the same
# files; the tsx loader and CLI paths are absolute because bare-specifier
# resolution would start from the new cwd (/home/gem has no node_modules).
if [ -d /home/gem ]; then
  cd /home/gem
  HOME=/home/gem
  export HOME
  # tsx discovers its tsconfig (the source-launch paths map) from the cwd;
  # pin it to the repo root so the cd cannot change module resolution.
  TSX_TSCONFIG_PATH=/app/tsconfig.json
  export TSX_TSCONFIG_PATH
fi

if [ "$(id -u)" = "0" ]; then
  exec setpriv --reuid="${USER_UID:-6001}" --regid="${USER_GID:-6000}" --clear-groups \
    node --import /app/node_modules/tsx/dist/esm/index.mjs /app/apps/cli/src/bin.ts "$@"
fi
exec node --import /app/node_modules/tsx/dist/esm/index.mjs /app/apps/cli/src/bin.ts "$@"
