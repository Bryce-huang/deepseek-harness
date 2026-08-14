# DeepSeek Harness container image: the `dsh web` browser UI.
#
# Built from source so each image corresponds to the git commit that triggered
# the build. The builder compiles the workspace, then reinstalls with --prod to
# drop devDependencies; workspace symlinks keep pointing at the built lib/
# directories, so the runtime carries the workspace as launched from source.
# (pnpm deploy is not used: its .pnpm copies of workspace packages materialize
# at install time, before lib/ and dist/ exist.)

FROM node:24 AS builder

# pnpm is pinned by packageManager; installing that exact version keeps the
# container build independent of corepack availability on the base image.
RUN npm install -g pnpm@11.7.0

WORKDIR /repo
COPY . .

# Frozen install keeps the lockfile the single source of dependency truth;
# lefthook's postinstall tolerates the git-less build context. The full
# (dev-inclusive) install stays: vendored @deepseek-ai/cordis is a
# peerDependency satisfied from root devDependencies, so a --prod reinstall
# breaks every workspace package's peer resolution.
RUN pnpm install --frozen-lockfile \
    && pnpm run build

FROM node:24

COPY --from=builder /repo /app

# Session logs, settings, and credentials default to ~/.dsh; DSH_HOME moves
# that tree onto the mounted volume. LLM access (DEEPSEEK_API_KEY,
# DEEPSEEK_BASE_URL) is injected at docker run, not baked into the image.
ENV NODE_ENV=production \
    DSH_HOME=/data

RUN mkdir /data && chown node:node /data
USER node
WORKDIR /app

EXPOSE 8080
VOLUME /data

CMD ["node", "apps/cli/lib/bin.js", "web", "--patch", "docker/web-all-interfaces.cordis.yml"]
