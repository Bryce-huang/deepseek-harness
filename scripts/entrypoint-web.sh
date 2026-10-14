#!/bin/sh
# Docker entrypoint for the dsh-on-debian image.
#
# dsh is the container's single service (web UI on 8080). This script
# pre-creates the dsh web profile on first boot and exec's the dsh web
# command so it becomes PID 1 and receives signals directly.
#
# The image runs entirely as the deployment's app user, uid 6001 / gid 6000
# (the Dockerfile's USER); nothing here needs elevation.
#
# First-boot profile contents: the offline-friendly optional bundles
# (DSH_OFFLINE_BUNDLES=skip keeps the plain web template). The profile is
# written once; later boots keep user edits.
#
# The cloud-only base rows (DeepSeek account, web search, plugin registry,
# etc.) stay disabled by the web-app's cordis.patch.yml — see
# packages/bundle/web-app/cordis.patch.yml.
#
# Deployment envs consumed by that composition: DSH_TRUSTED_HOSTS names the
# Host/Origin-fence authorities browsers actually use (host LAN IP, proxied
# domain; space-separated, or the image default `*` to accept any Host);
# DSH_WEB_PASSWORD sets a fixed sign-in token so the console-printed launch
# token is not the only way in.

set -eu

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

  echo "dsh-entrypoint: initialized ${PROFILE} profile (offline bundles: ${DSH_OFFLINE_BUNDLES:-install})"
fi

# ── run dsh ─────────────────────────────────────────────────────────────────
# dsh's default cwd is the app user's home so file tools, the shell, and any
# language toolchain share one workspace; the tsx loader and CLI paths are
# absolute because bare-specifier resolution would start from the new cwd
# (/home/app has no node_modules), and the tsconfig pin keeps source-launch
# module resolution tied to the repo root regardless of cwd.
cd /home/app
HOME=/home/app
export HOME
TSX_TSCONFIG_PATH=/app/tsconfig.json
export TSX_TSCONFIG_PATH
exec node --import /app/node_modules/tsx/dist/esm/index.mjs /app/apps/cli/src/bin.ts "$@"
