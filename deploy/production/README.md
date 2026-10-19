# 154 Woodpecker deployment

生产入口为 `https://vm2api.motion-cover.com/console/`，API base URL 为
`https://vm2api.motion-cover.com/v1`。控制面只监听 `127.0.0.1:3187`。

## 发布链路

`zengwenliang416/vm2api` 的 `main` push / manual → Woodpecker 审批 →
30 项部署相关契约测试 → 源码构建（前端 TypeScript/Vite + Go helpers +
上游 payload SHA-256 校验）→ `local/vm2api:<完整 SHA>` → 维护门禁 →
停控制面并备份 → Compose 健康检查 → 管理员登录/鉴权冒烟 → 开放入口。

只允许本仓库专用 agent 执行；关闭 PR 部署，所有事件保留人工审批。
不要给上游 PR 配置宿主卷权限。构建器串行执行，限制 2 CPU / 3 GiB，
控制面限制 1 CPU / 1.5 GiB。槽位资源是独立配置，控制面限额不会限制槽位总量。

应用沿用上游所需 host 网络、NET_ADMIN / NET_RAW 和宿主 Docker socket。
这些权限允许控制面管理宿主容器和槽位出口，不构成对宿主的安全隔离。
不要向不可信用户开放管理员账号。初始状态不创建槽位、不导入订阅凭据。

## 服务器目录和凭据

- `/opt/vm2api/.env`：随机管理员密码、主 API key、数据库加密密钥，权限 0600。
- 管理员用户名 `wenliang`；密码在服务器 `.env`，不写 Git、CI 日志或交付文档。
- `/opt/vm2api/data`、`vms`、`config`：持久状态。
- `/opt/vm2api/bin`、`share`：当前镜像提供的上游预编译 payload。
- `/opt/vm2api/current-release.json`：实际部署的 SHA、镜像、版本及备份位置。
- `/opt/vm2api/backups/<时间-SHA>`：服务停止后的快照；包含加密密钥，权限 0700。
- `/opt/woodpecker/vm2api-agent`：独立 agent 配置和私密 token。

## 初次引导

已有 Woodpecker 管理端为 `https://ci.motion-cover.com`。启用 fork，配置
`.woodpecker/deploy.yml`，`allow_pr=false`，`require_approval=all_events`，
仅 trusted volumes，agent labels 为
`location=production-80,repo=zengwenliang416/vm2api`。

创建独立 BuildKit（先安装 `buildkitd.toml` 到 bootstrap 目录）：

```sh
DOCKER_CONFIG=/opt/vm2api/docker-client docker buildx create \
  --name vm2api-production --driver docker-container \
  --driver-opt memory=3g,memory-swap=3g,cpu-period=100000,cpu-quota=200000 \
  --buildkitd-config /opt/vm2api/bootstrap/buildkitd.toml --bootstrap
```

Nginx 需要在 http 上下文增加以下 map，再加载本目录的 `nginx.conf`：

```nginx
map $http_upgrade $vm2api_connection_upgrade {
    default upgrade;
    '' close;
}
```

DNS 使用 Cloudflare 代理，未知 hostname 拦截规则只增加本域名。
Let’s Encrypt 使用独立 webroot 和配置目录，系统定时器负责续期。

## 恢复和更新

发布通过 origin HTTP 请求验证 503 门禁，再停服务、备份。验证失败时保留
候选日志和失败状态；已有版本可在门禁内恢复快照，首次部署失败保持维护。
任何已有 `maintenance.flag` 或 `deployment.lock` 都要求检查原因，不自动清理。
有运行中槽位时，跨 payload 或数据库版本更新前应先停止新请求并排空槽位。
自动槽内 wrap 同步关闭（`KIN_AUTO_SYNC_WRAP=0`），槽位升级需单独安排。

需回退时，先开启维护并确认 503，停控制面及相关写入，再保留当前状态，
恢复已验证备份和旧镜像。不要在接受新写入后直接覆盖旧 SQLite 快照。
浏览器内置上游一键更新不属于本 CI 发布链路，应通过 fork 的 main 发布。

验证服务健康、管理员登录、API 鉴权不等于上游推理验证。导入合法订阅并配置
槽位出口后，另行验证真实流式消息、额度、工具调用和故障切换。
