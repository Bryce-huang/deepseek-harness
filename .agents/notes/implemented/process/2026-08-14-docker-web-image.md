# Agent Note: Container image for the dsh web profile

Status: implemented

English | [中文](2026-08-14-docker-web-image.zh.md)

## Problem

The repository had no container story. Its serving surface — the `dsh web` browser UI — binds an HTTP port (default 3080, `--host`/`--port` flags), so it is the one entrypoint that maps onto a container port, while the ACP and SDK JSON-RPC servers remain stdio transports outside this scope.

## Decision

A multi-stage `Dockerfile` at the repository root builds from source so each image corresponds to the triggering git commit. The builder stage runs `pnpm install --frozen-lockfile` and `pnpm run build`; the runtime stage copies the whole workspace (full node_modules plus built `lib/` and `apps/web/dist/`). Both stages use the full `node:24` image (not slim) because the harness's shell and subprocess capabilities execute system commands inside the container. The entrypoint is `dsh web --patch docker/web-all-interfaces.cordis.yml`: the CLI rejects `--host 0.0.0.0` as a footgun for interactive use, so all-interfaces binding on port 8080 is the deliberate deployment decision that overlay makes, with container exposure governed by port publishing. `DSH_HOME=/data` with a declared volume moves the `~/.dsh` persistence tree (sessions, settings, credentials) onto a mount. LLM access stays environmental: `DEEPSEEK_API_KEY` and `DEEPSEEK_BASE_URL` are injected at `docker run`, and protocol changes ride a mounted profile patch layer rather than image content.

`docker-build.yml` publishes to GHCR with the built-in `GITHUB_TOKEN` (no registry secrets). Master pushes publish `latest` plus `sha-<short>`; `v*` and `dsh-v*` tags publish the tag name. The repository name is lowercased because GHCR requires lowercase image paths. Builds are amd64 with the GitHub Actions cache, matching the wehermes workflow structure this workflow was modeled on.

## Alternatives considered

**Install the published npm package instead of building from source.** A smaller, faster image, but it tracks the npm release line rather than the commit, so push-triggered builds can republish identical content.

**Prune with `pnpm deploy` or a `--prod` reinstall.** Both rejected. pnpm materializes its `.pnpm` copies of workspace packages at install time, before `lib/` and `apps/web/dist/` exist, so a deploy tree ships workspace packages without build outputs (a stale local build can mask this). A `--prod` reinstall drops root devDependencies, and vendored `@deepseek-ai/cordis` is a peerDependency of every harness package satisfied from those root devDependencies — removing them breaks peer resolution at runtime.

**Ship an HTTP bridge over the stdio JSON-RPC servers.** Rejected for now: it adds a new example bundle with tests and documentation, and the web UI already exposes the assembled application over HTTP.

## Consequences

Container deployment is available without touching any package source; the Dockerfile, `.dockerignore`, and workflow are repository-level files, so package gates are unaffected. Image builds pay the full workspace build cost (minutes, not seconds) on each push. Port 8080 is fixed by the entrypoint's flags; a different port requires overriding the container command, and the harness's own default (3080) is deliberately not used.
