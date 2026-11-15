# 自托管 Memos 云端同步部署

本目录提供 Coding Rewind 的可选云端后端栈，通过 [docker-compose.yml](docker-compose.yml) 运行原版 `neosmemo/memos:26.11.0` 与纯标准库增强器 [enricher.py](enricher/enricher.py)（服务名 `rewind-enricher`）。

## 本地使用与云端同步区别

- **零配置本机模式**，不填写 Memos 服务时，桌面端仍支持划选或 `⌃⌥⇧⌘S` 暂存片段到本地队列与缓存、按 `⌃⌥R` 查看近 72 小时卡片，并勾选卡片在 Antigravity 或 Codex 开始对话。
- **自托管 Memos 云端同步**，部署本目录服务栈后可解锁跨设备片段同步、Chrome 网页剪藏持久化，以及由 `rewind-enricher` 自动生成的中文或英文标题、会话主题、脉络摘要与关键词引用头（选中原文一字不改）。

## 快速部署步骤

1. 进入 `deploy/vps` 目录，复制 [.env.example](.env.example) 为 `.env`。

```bash
cp .env.example .env
```

2. 编辑 `.env`，填写兼容 OpenAI 接口的摘要模型参数与密钥。

- `AI_API_KEY`，必填，模型调用密钥，未填写时 `rewind-enricher` 无法启动。
- `AI_BASE_URL` 与 `AI_MODEL`，模型接口地址与模型名，默认沿用模板中的兼容端点与 `qwen-plus`。
- `REWIND_SUMMARY_LANGUAGE`，摘要语种模式，可选 `auto`（按剪藏正文自动判定中文或英文）、`zh-Hans` 或 `en`。
- `MEMOS_IMAGE`、`MEMOS_DATA_DIR`、`MEMOS_BIND_ADDR`、`MEMOS_PORT`、`ENRICHER_BIND_ADDR` 与 `ENRICHER_PORT`，镜像版本、数据卷目录及监听端口，默认仅绑定 `127.0.0.1`。

3. 首次尚未申请令牌时，因为 [docker-compose.yml](docker-compose.yml) 在解析阶段会校验 `MEMOS_ACCESS_TOKEN` 与 `AI_API_KEY` 非空，请先临时传入非空占位值单独启动 `memos`（两项均已在 `.env` 填妥时直接运行 `docker compose up -d` 即可）。

```bash
MEMOS_ACCESS_TOKEN=pending docker compose up -d memos
```

4. 首次访问 Memos 网页界面（本机默认 `http://127.0.0.1:5230`，公网访问需搭配 HTTPS 反向代理），创建管理员账号。
5. 登录后进入 Memos 的设置页面（Settings），创建一个具备读写权限的个人访问令牌。
6. 将该令牌填入 `.env` 的 `MEMOS_ACCESS_TOKEN`，然后启动完整服务栈。

```bash
docker compose up -d
```

7. 打开 Coding Rewind 桌面端“设置 → 云端同步”或 Chrome 扩展“云端同步”设置页，填入服务地址（也可点击地址旁的“打开后台拿令牌 ↗”直达网页）与访问令牌并保存，客户端会在保存时自动检测连通性。

## 反向代理与 Webhook

- 默认端口 `5230` 与 `8090` 均仅监听 `127.0.0.1`。若需公网访问或暴露原生 `/mcp` 流式接口，请参考 [Caddyfile.example](Caddyfile.example) 配置 TLS 反向代理。
- `REWIND_WEBHOOK_SECRET` 为可选配置。设置后 `rewind-enricher` 会校验 `/hooks/rewind` 的 Standard Webhooks 签名并即时增强；留空时仍按 `POLL_INTERVAL_SECONDS`（默认每 5 秒）自动轮询待处理记录。
