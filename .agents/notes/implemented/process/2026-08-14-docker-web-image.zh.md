# Agent Note：dsh web 档位的容器镜像

Status: implemented

[English](2026-08-14-docker-web-image.md) | 中文

## Problem

仓库此前没有容器化方案。服务面 `dsh web` 浏览器 UI 会绑定 HTTP 端口（默认 3080，支持 `--host`/`--port`），因此是唯一能直接映射到容器端口的入口；ACP 与 SDK JSON-RPC 服务器仍是 stdio 传输，不在本次范围内。

## Decision

仓库根目录的多阶段 `Dockerfile` 从源码构建，使每个镜像对应触发构建的 git commit。builder 阶段执行 `pnpm install --frozen-lockfile` 与 `pnpm run build`；运行时阶段复制整个 workspace（完整 node_modules 加构建出的 `lib/` 与 `apps/web/dist/`）。两个阶段都使用完整 `node:24` 镜像（非 slim），因为 harness 的 shell 与 subprocess 能力会在容器内执行系统命令。入口是 `dsh web --patch docker/web-all-interfaces.cordis.yml`：CLI 把 `--host 0.0.0.0` 作为交互使用的危险操作拒绝，因此 all-interfaces 绑定 8080 端口由该 overlay 显式声明，容器的对外暴露由端口发布控制。`DSH_HOME=/data` 加声明的卷把 `~/.dsh` 持久化树（会话、设置、凭据）移到挂载点。LLM 访问全部走环境注入：`DEEPSEEK_API_KEY` 与 `DEEPSEEK_BASE_URL` 在 `docker run` 时注入；更换协议通过挂载 profile patch 层实现，不写进镜像内容。

`docker-build.yml` 用内置 `GITHUB_TOKEN` 发布到 GHCR（无需配置 registry secrets）。master 推送发布 `latest`、UTC 构建日期（`YYYY.MM.DD`）与 `sha-<short>`；`v*` 与 `dsh-v*` tag 发布 tag 名。仓库名转为小写，因为 GHCR 要求镜像路径全小写。构建为 amd64 并使用 GitHub Actions 缓存，结构参照 wehermes 项目的 workflow。

## Alternatives considered

**安装已发布的 npm 包代替源码构建。** 镜像更小、构建更快，但版本跟随 npm 发布线而非 commit，push 触发的构建可能重复发布相同内容。

**用 `pnpm deploy` 或 `--prod` 重装修剪。** 均不采用。pnpm 在 install 时物化 workspace 包的 `.pnpm` 副本，早于 `lib/` 与 `apps/web/dist/` 的生成，部署树里的 workspace 包因此不含构建产物（本地旧构建会掩盖这一点）；`--prod` 重装会移除根 devDependencies，而 vendored `@deepseek-ai/cordis` 是每个 harness 包的 peerDependency、由根 devDependencies 满足 —— 移除后运行时 peer 解析断链。

**为 stdio JSON-RPC 服务器封装 HTTP 桥接。** 暂不采用：需要新增带测试与文档的 example bundle，而 web UI 已经通过 HTTP 暴露组装后的完整应用。

## Consequences

容器部署不改动任何 package 源码即可使用；Dockerfile、`.dockerignore` 与 workflow 都是仓库级文件，package 门不受影响。镜像构建每次 push 都要付出整个 workspace 的构建成本（分钟级）。端口 8080 由入口命令行参数固定；换端口需要覆盖容器命令，harness 自身默认端口（3080）在此被有意不用。
