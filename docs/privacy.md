# 隐私、凭据安全与数据生命周期

AI 对话中的摘录、提示词与前文脉络往往涉及未发表思考或正在推进的工程细节。本文说明统一架构下用户数据在采集、传输、增强、缓存、导出与删除各环节的真实流向与硬边界。

需求范围见 [requirements.md](requirements.md)，线级数据格式见 [architecture.md](architecture.md)。

## 仓库与验收红线

- **严禁真实私密语料入库**，代码、文档与测试夹具一律使用虚构占位语料，不得提交真实私密聊天、个人提示词或未脱敏截图。
- **严禁硬编码凭据与私人节点身份**，源码、部署模板、MCP 配置与构建脚本中不得写入明文访问令牌、`sk-` 或 `whsec_` 密钥以及私人服务器 IP，由 `./scripts/check` 每次自动扫描拦截。
- **验收环境严格隔离**，自动化测试与本地 QA 必须设置独立的 `CODING_REWIND_DATA_DIR` 与 `CODING_REWIND_QA=1`，不读写个人日常钥匙串条目，也不在 `/tmp` 或 `/private/tmp` 散放构建与测试目录。

## 数据最小化设计原则

生命周期设计参考《通用数据保护条例》第 5 条关于目的限制、数据最小化、准确性与保密性的工程思路，原文见 [EUR-Lex Regulation 2016/679](https://eur-lex.europa.eu/eli/reg/2016/679/oj)。该引用仅作工程自检准绳，不构成特定法域的法律合规背书：

1. **只采用户显式选中的片段**，不做后台全量聊天录制，不采集未触发保存时的网页浏览轨迹或剪贴板历史。
2. **上下文严格限缩**，桌面钩子与网页扩展最多附带紧邻前序提问及最近 4 轮对话文本，仅用于帮助用户日后回忆当时讨论的语境。
3. **剪贴板零残留保护**，桌面端在辅助功能受限回退模拟 `⌘C` 时，先备份全部 `NSPasteboardItem` 原始数据并在读取后立即还原，既不覆盖用户剪贴板，也不会在无选区时误传旧剪贴板内容。

## 数据流向与存储边界

### 1. 唯一持久层与私密可见度

所有片段通过 HTTPS 发送至用户自己在阿里云轻量服务器上部署的原版 `usememos/memos` 实例，创建片段与挂载上下文评论时 `visibility` 均固定设为 `PRIVATE`，不经过任何第三方托管 SaaS 收藏平台。

### 2. AI 脉络增强与原文零篡改边界

VPS 内部的 `rewind-enricher` 仅读取带 `#rewind/pending` 的新片段及其 `<!-- rewind-context-v1 -->` 评论，调用用户在服务端 `.env` 中自行配置的 OpenAI 兼容模型接口生成四项结构化引用头 `Title`、`Session`、`Context` 与 `Keywords`。增强器生成的说明固定写在顶部 Markdown 引用块内，下方用户选中的原始文本逐字原样保留，确保日后回顾时一眼分清哪部分是当时保存的原话、哪部分是 AI 归纳的背景。

### 3. 客户端本地缓存与离线队列

客户端不维护第二套长期业务数据库，仅保留最小运行态文件：

- **macOS 桌面端**，在 `~/Library/Application Support/CodingRewind/` 下存放最近热流镜像 `hot_cache.json`、断网待发队列 `outbox.jsonl`、当前回合快照 `active_turn.json` 及仅含服务地址的 `config.json`。
- **浏览器扩展端**，在 `chrome.storage.local` 存放用户配置的 `Memos` 地址、访问令牌以及上限 50 条的断网待发队列 `outbox`，重放成功后即刻移出队列。

### 4. 一键接聊的短期请求与宿主记录

勾选卡片并点击开聊后，应用将原文、标题、脉络和出处组成提示词，交给 Antigravity 创建新会话并发送。接聊不经过剪贴板。

`<dataDir>/handoff/` 使用 `0700` 目录与 `0600` 文件。请求正文只用于本次交接，处理完成或过期后清除。回执保存请求编号、状态和成功时的会话编号，不保存提示词。进程中断后，无法确认的请求不会自动重发。

Antigravity 自己会在 `~/.gemini/antigravity/sidecar_data/<sidecarId>/events/` 记录 `agentapi` 调用，记录可能包含完整提示词。2026-11-12 的无敏感测试确认事件含测试提示词。此记录及已创建会话属于宿主的留存范围，不随 Coding Rewind 请求清理而删除。[官方 sidecar 运行数据说明](https://antigravity.google/docs/sidecars#runtime-data)描述了这些目录。

## 凭据保护机制

- **桌面端钥匙串存储**，`CodingRewindApp` 与 `scripts/memos-mcp-bridge.sh` 统一将 `Memos` 访问令牌保存在 macOS Security Keychain 服务 `com.codingrewind.memos` 中；`config.json`、`~/.gemini/config/plugins/coding-rewind/mcp_config.json` 与 `~/.config/agent-mcp/servers.json` 均不写入明文令牌。
- **可选本机开发启动器**，显式设置 `CODING_REWIND_MEMOS_TOKEN_REFERENCE` 构建时，包内 `DeveloperCredentials.plist` 只保存 1Password 引用与 `op` 的绝对路径。启动器通过 `op run` 仅向应用进程树注入令牌，不读取或更新钥匙串，也不设置全局环境。注入失败、空值、含空白或未解析的引用均不会启动应用，避免回落到钥匙串。未配置该构建选项的普通用户无需安装 1Password CLI。
- **开发与 QA 钥匙串隔离**，设置环境变量 `CODING_REWIND_QA=1` 时，客户端与桥接脚本固定访问 `com.codingrewind.memos.qa`，凭据缺失时直接报错返回非零退出码，绝不暗中回退读取个人日常钥匙串。
- **服务端环境变量隔离**，`MEMOS_ACCESS_TOKEN`、`AI_API_KEY` 与 `REWIND_WEBHOOK_SECRET` 仅通过服务器本地未入库的 `.env` 注入容器环境，仓库只保留占位模板 `.env.example`。

2026-11-12 的本机交付安装验收已确认，普通启动可读取远端热池，未出现 Keychain 弹窗。该次验收使用本机 ad-hoc 构建和进程环境注入。

## 导出、删除与留存期限

1. **自主导出**，由于全部片段以标准 Markdown 与清晰标签存于用户自托管的 `usememos/memos`，用户可随时通过 `Memos` 原生界面或 `/api/memos` 接口批量导出包含原文、脉络抬头、上下文评论、出处链接与时间戳的完整数据。
2. **单条与全量删除**，在 `Memos` 中删除单条记录或清空带 `#rewind/` 标签的条目时，关联的上下文评论随主记录一并移除；桌面浮窗刷新后 `hot_cache.json` 同步覆盖更新，本地离线队列也可随时清空。卸载浏览器扩展或清理浏览器本地存储会清除扩展内未发送的离线队列，已成功同步至 `Memos` 的记录不受影响。
3. **热窗口冷却而非静默删除**，超过 72 小时的记录以及标记为 `#rewind/synthesized` 的已成文记录只是自然退出桌面毛玻璃热流浮窗，不会在后台被自动删除，用户仍可在 `Memos` 或通过 Antigravity `/rewind` 技能随时检索调阅。
