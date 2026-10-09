#!/bin/sh
# Docker entrypoint for the dsh web profile.
#
# The web profile is auto-initialized on first use under
# $DSH_HOME/profiles/web. The shipped template lists only dsh-base and
# dsh-web-app. The Docker image additionally bakes the offline-friendly
# optional bundles (Agent Teams profile, Auto review) into
# /app/node_modules as runtime dependencies of the CLI, so a fresh
# container can enable them by adding the package names to the
# profile's dsh.profile.bundles list. The loader resolves bundle names
# against the CLI's hoisted node_modules — the workspace symlinks are
# in place from the build's `pnpm install --frozen-lockfile` step —
# so no network round trip is required to install them.
#
# On first boot, this entrypoint pre-creates the profile manifest with
# the offline-friendly bundle list, then exec's the dsh web command.
# The cloud-only base rows (DeepSeek account, web search, plugin
# registry, etc.) are disabled by the web-app's cordis.patch.yml — see
# packages/bundle/web-app/cordis.patch.yml. ptc-runtime-python also
# ships in /app/node_modules but is a runtime substitute for the
# dsh-base `ptc-runtime` row, not a bundle; switching the active PTC
# runtime is the user's choice through the PTC runtime configuration.
#
# Set DSH_OFFLINE_BUNDLES=skip to keep the shipped web template (just
# dsh-base + dsh-web-app) and switch on the optional bundles through
# the Plugins page.

set -eu

PROFILE="web"
PROFILE_DIR="${DSH_HOME}/profiles/${PROFILE}"
# The optional bundles that declare dsh.bundle.patch: Agent Teams
# profile (replaces the standard subagent delegation with team-based
# coordination) and Auto review (per-tool LLM authorization review
# for the Auto permission preset). ptc-runtime-python is a runtime
# substitute for dsh-base's ptc-runtime row, not a bundle, so it is
# not listed here; it ships in /app/node_modules and is available
# to anyone who switches the active PTC runtime in their profile.
OFFLINE_BUNDLES='[
      "@deepseek-ai/dsh-experimental-agent-team-profile",
      "@deepseek-ai/dsh-experimental-auto-review"
    ]'

# Shipped web template (the user can downgrade to it by setting
# DSH_OFFLINE_BUNDLES=skip and deleting $PROFILE_DIR).
SHIPPED_BUNDLES='[
      "@deepseek-ai/dsh-base",
      "@deepseek-ai/dsh-web-app"
    ]'

mkdir -p "${PROFILE_DIR}"

if [ ! -f "${PROFILE_DIR}/package.json" ]; then
  if [ "${DSH_OFFLINE_BUNDLES:-install}" = "install" ]; then
    BUNDLES="${OFFLINE_BUNDLES}"
  else
    BUNDLES="${SHIPPED_BUNDLES}"
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
  # hoisted node_modules — the loader reads dsh.profile.bundles by
  # name and expects to find them at the hoisted root.
  cat > "${PROFILE_DIR}/pnpm-workspace.yaml" <<EOF
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false
EOF

  # Empty user patch layer (the file must exist so the loader can
  # include it as a patch layer; an empty array is a valid patch).
  echo '[]' > "${PROFILE_DIR}/cordis.patch.yml"

  echo "dsh-entrypoint: initialized ${PROFILE} profile with offline bundles"
fi

exec node --import tsx/esm apps/cli/src/bin.ts "$@"
