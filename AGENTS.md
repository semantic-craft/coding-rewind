# AGENTS.md

实现、评审或验收前先读 [lessons.md](lessons.md) 与本文件，再按需查阅下表文档：

| 入口 | 内容与触发时机 |
| --- | --- |
| [README.md](README.md) | 项目定位、组件分工与快速开始 |
| [docs/architecture.md](docs/architecture.md) | 端到端数据流、Memos v1 线级契约、离线缓冲与宿主接线 |
| [docs/requirements.md](docs/requirements.md) | 用户一手原话、已拍板决定、MVP 与非目标边界 |
| [docs/sources.md](docs/sources.md) | 复用或对照的 MIT 上游项目及 GPL/AGPL/无许可排除清单 |
| [docs/privacy.md](docs/privacy.md) | 原文与 AI 摘要边界、凭据存储、导出与删除规则 |
| [docs/milestones.md](docs/milestones.md) | M0 至 M4 分期验收标准 |
| [docs/contributing.md](docs/contributing.md) | 人机协作与公开仓库提交边界 |

## 统一架构与源码导航

系统以单实例原版 `usememos/memos` 为唯一事实源，不在客户端另建业务数据库或自定义编辑器：

- **云端主干 `deploy/vps/`**，运行官方 `neosmemo/memos:stable` 容器提供 `/api/v1/memos` 与原生 Streamable HTTP `/mcp`，旁挂纯 Python 3 标准库服务 `deploy/vps/enricher/enricher.py`，同时支持 Standard Webhooks `POST /webhook` 验签触发与 5 秒容器内网轮询自愈。
- **网页端剪藏 `extensions/web-clipper/`**，Manifest V3 薄扩展，适配 ChatGPT、Claude 与 Gemini，提取选中 Markdown、会话标题、紧邻前序提问及最近 4 轮对话，由后台 Service Worker 直连 Memos REST API 并附带 `chrome.storage.local` 离线重放队列。
- **桌面端浮窗 `Sources/CodingRewindApp/` 与 `Sources/CodingRewindCore/`**，约三四百行原生 Swift 菜单栏与非激活毛玻璃浮窗，支持 `⌃⌥S` 捕获选区、`⌃⌥R` 速览近 72 小时热流卡片、`⌘Return` 经 `agentapi new-conversation` 直接在 Google Antigravity App 2.x 开启带脉络的新对话，并通过 `outbox.jsonl` 与 `hot_cache.json` 保障断网可用。
- **宿主桥接 `Sources/AntigravityBridge/` 与 `scripts/memos-mcp-bridge.sh`**，非阻塞钩子 `coding-rewind-hook` 在 `PostInvocation` 与 `Stop` 时提取 `lastUserInput` 与最近 4 轮会话写入 `active_turn.json`；`memos-mcp-bridge.sh` 从钥匙串读取令牌后调用 `mcp-remote` 连接远端 `/mcp`。

## Memos v1 线级契约不变量

三端读写必须严格遵守同一套标签状态机与正文布局，改动任一端时须同步核对另外两端：

1. **标签流转**，新建片段写入 `#rewind/pending` 与 `#source/<antigravity|chatgpt|claude|gemini|macos|web>`；若随附对话上下文评论，同时打上 `#rewind/has-ctx`。`rewind-enricher` 补齐抬头后将 `#rewind/pending` 与 `#rewind/has-ctx` 替换为 `#rewind/ready`；客户端归档成文后可更新为 `#rewind/synthesized`。
2. **上下文评论与等待窗口**，客户端通过 `POST /api/v1/memos/<serverId>/comments?commentId=<clientClipId>-ctx` 提交首行带 `<!-- rewind-context-v1 -->` 标记的私密评论；若主记录含 `#rewind/has-ctx` 且评论尚未到达，`rewind-enricher` 在创建后 15 秒内推迟处理以避免竞态漏读，满 15 秒后优雅降级。
3. **原文零篡改**，客户端使用符合 `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$` 的 `memoId` 幂等写入，可见度固定为 `PRIVATE`；`rewind-enricher` 只更新顶部标签行与引用块元数据 `Title`、`Session`、`Context`、`Keywords`、`Source`，下方的用户选中原文必须逐字原样保留。

## 凭据、安装路径与验收隔离

- **数据目录**，`CODING_REWIND_DATA_DIR` 优先，缺省为 `~/Library/Application Support/CodingRewind`。
- **服务地址**，`CODING_REWIND_MEMOS_URL` 优先，其次读取 `<dataDir>/config.json` 的 `memos_url` 字段；严禁将访问令牌写入 `config.json`、`mcp_config.json` 或 `servers.json`。
- **访问令牌与 QA 隔离**，`CODING_REWIND_MEMOS_TOKEN` 优先，其次读取 macOS Keychain 服务 `com.codingrewind.memos`；当设置 `CODING_REWIND_QA=1` 时强制切换至独立钥匙串服务 `com.codingrewind.memos.qa`，缺失时直接报错退出，绝不回退读取个人钥匙串。
- **宿主 CLI 解析**，`CODING_REWIND_AGENTAPI_BIN` 优先，其次查找 `PATH`，最后检查 `/Applications/Antigravity.app/Contents/Resources/app/bin/agentapi`。
- **固定安装位置与目录禁区**，安装 Antigravity 插件时必须将辅助可执行文件拷入 `~/Library/Application Support/CodingRewind/bin/`，严禁在插件或钩子配置中引用 `.build/`；任何构建输出与本地 QA 目录均不得使用 `/tmp` 或 `/private/tmp`。

## 验证与构建入口

- 全仓统一门禁运行 `./scripts/check`，依次执行静态卫生与边界检查、`swift test`、`deploy/vps/enricher` 单元测试、`extensions/web-clipper` 单元测试与 Shell 语法校验。
- 原生应用打包运行 `./scripts/build-app-bundle.sh`，在 `.build/CodingRewind.app` 生成启用 `LSUIElement` 的签名校验包。
