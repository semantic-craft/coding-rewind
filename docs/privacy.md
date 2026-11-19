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
2. **上下文严格限缩**，桌面捕获与网页扩展最多附带所选消息对应的前序提问及最近 4 个用户轮的对话文本，仅用于帮助用户日后回忆当时讨论的语境。
3. **剪贴板零残留保护**，桌面端在辅助功能受限回退模拟 `⌘C` 时，先备份全部 `NSPasteboardItem` 原始数据并在读取后立即还原，既不覆盖用户剪贴板，也不会在无选区时误传旧剪贴板内容。

## 数据流向与存储边界

### 1. 唯一持久层与私密可见度

所有片段（含 Agent 经 `create_snippet` 暂存的提纲草稿，默认标记 `#source/agent`）、采集上下文评论（`<!-- rewind-context-v1 -->`）与 AI 追加笔记评论（`<!-- rewind-note-v1 -->`）均通过 HTTPS 发送至用户自己在阿里云轻量服务器上部署的原版 `usememos/memos` 实例，`visibility` 固定设为 `PRIVATE`，不经过任何第三方托管 SaaS 收藏平台。

### 2. AI 脉络增强、受控写入与原文零篡改边界

VPS 内部的 `rewind-enricher` 仅读取带 `#rewind/pending` 的新片段及其 `<!-- rewind-context-v1 -->` 评论，调用用户在服务端 `.env` 中自行配置的 OpenAI 兼容模型接口生成四项结构化引用头 `Title`、`Session`、`Context` 与 `Keywords`。增强器生成的说明固定写在顶部 Markdown 引用块内，下方用户选中的原始文本逐字原样保留，确保日后回顾时一眼分清哪部分是当时保存的原话、哪部分是 AI 归纳的背景。

客户端向外部 Agent 开放写入时执行同样严格的边界约束：

- **元数据改写绝不动原文**，`update_snippet_metadata`（及 `coding-rewind update`）只允许重写首行标签与顶部引用块元数据（`Title`、`Session`、`Context`、`Keywords`），正文 `<verbatim_selected_markdown>` 100% 逐字节原样保留。
- **AI 批注独立挂载**，`append_snippet_note`（及 `coding-rewind note`）通过 `POST /api/memos/<serverId>/comments?commentId=<noteCommentId>` 写入首行带 `<!-- rewind-note-v1 -->` 的 `PRIVATE` 评论（纯本机模式下写入 `<dataDir>/local_notes.json`），既不篡改主记录原文，也与采集上下文评论 `<!-- rewind-context-v1 -->` 严格隔离，由 `get_snippet` 单独解析为 `notes` 返回。
- **只读开关与禁止 MCP 物理删除**，物理删除（`delete`）严格保留给桌面 HUD 与终端 CLI 的人工操作，绝不通过 `coding-rewind mcp` 向 AI 暴露；用户可随时在“设置 → 插件与权限 → AI 接入与权限”切换为只读（`ai_access_mode: "read_only"`）或设置环境变量 `CODING_REWIND_AI_ACCESS=read_only`（非空非法值同样按故障关闭降级为 `read_only`），实时阻断 `create_snippet`、`update_snippet_metadata`、`append_snippet_note`、`archive_snippet` 全部 4 个 MCP 写入工具以及 CLI 写删子命令（`create`、`update`、`note`、`archive`、`delete`）。

### 3. 客户端本地缓存与离线队列

客户端不维护第二套长期业务数据库，仅保留最小运行态文件：

- **macOS 桌面端与 CLI / MCP**，在 `~/Library/Application Support/CodingRewind/` 下存放最近热流镜像 `hot_cache.json`、断网待发队列 `outbox.jsonl`、纯本机模式下的笔记文件 `local_notes.json`，以及仅存储 `memos_url` 与 `ai_access_mode`（`"read_only"` | `"read_write"`，默认 `"read_write"`，严禁存储任何访问令牌）的 `config.json`。设置页一键复制的 MCP JSON 配置同样只含固定二进制路径与参数，不含任何密钥。
- **浏览器扩展端**，在 `chrome.storage.local` 存放用户配置的 `Memos` 地址、访问令牌以及上限 50 条的断网待发队列 `outbox`，重放成功后即刻移出队列。

### 4. 一键接聊的短期请求与宿主记录

勾选卡片并点击开聊后，应用将卡片标识（`- 卡片 ID` / `- Clip ID`）、原文、标题、脉络和出处组成提示词（读写模式下附带 `append_snippet_note` / `create_snippet` 回写说明，只读模式下省略），在浮窗草稿框调整后交给所选的 Antigravity 或 DSH（DeepSeek Harness）。通过直接通道投递时不经过系统剪贴板。

`<dataDir>/handoff/` 与 `<dataDir>/dsh-handoff/` 分别保存两种宿主的请求，另设 `<dataDir>/dsh-actions/`（原会话回跳）、`<dataDir>/dsh-captures/`（DSH 选区胶囊暂存）与 `<dataDir>/dsh-active-session.json`（DSH 活跃会话只读快照），全部强制使用 `0700` 目录与 `0600` 文件及 `O_NOFOLLOW` 校验。请求正文只用于本次交接，处理完成或过期后清除。回执保存请求编号、状态和成功时的会话编号，不保存提示词。进程中断后，无法确认的请求不会自动重发。

Antigravity 自己会在 `~/.gemini/antigravity/sidecar_data/<sidecarId>/events/` 记录 `agentapi` 调用，记录可能包含完整提示词。2026-11-12 的无敏感测试确认事件含测试提示词。此记录及已创建会话属于宿主的留存范围，不随 Coding Rewind 请求清理而删除。[官方 sidecar 运行数据说明](https://antigravity.google/docs/sidecars#runtime-data)描述了这些目录。

DSH 接聊通过运行在 `~/.dsh/profiles/desktop` 内的零依赖插件 `coding-rewind-dsh` 与同源本地路由 `POST /coding-rewind/api` 协作，仅将草稿追加填入 DSH 空白会话输入框而不自动发送，也不会向 DSH 传递 Memos 访问令牌或 `CODING_REWIND_*` 环境变量。用户在 DSH 内实际发送后的会话记录属于 DSH 自身存储范围，不随 Coding Rewind 清理短期交接请求而删除。

## 凭据保护机制

- **桌面端钥匙串存储**，`CodingRewindApp` 与 `coding-rewind`（CLI 及 `coding-rewind mcp`）统一通过 `CodingRewindCore` 从 macOS Security Keychain 服务 `com.codingrewind.memos` 读取或保存 `Memos` 访问令牌；`config.json`、`~/.gemini/config/plugins/coding-rewind/` 与 `~/.config/agent-mcp/servers.json` 均不写入明文令牌。
- **可选本机开发凭据配置**，显式设置 `CODING_REWIND_MEMOS_TOKEN_REFERENCE` 构建时，包内 `DeveloperCredentials.plist`（并在首次启动时以 `0600` 权限幂等同步至 `<dataDir>/DeveloperCredentials.plist`）只保存 1Password 引用与 `op` 的绝对路径。桌面端与 `coding-rewind` 在非 QA 模式下以 `O_NOFOLLOW` 校验该文件属主、单链接与 `0600` 权限，并核验 `op` 二进制的 AgileBits `Developer ID`（`2BUA8C4S2C`）代码签名后通过 `op read --no-newline` 私有管道读取令牌，不回写钥匙串，也不设置全局环境；配置无效或 `op` 失败、超时时严禁暗中回落到个人钥匙串。未配置该构建选项的普通用户无需安装 1Password CLI。
- **开发与 QA 钥匙串隔离**，设置环境变量 `CODING_REWIND_QA=1` 时，桌面端与 `coding-rewind` 忽略开发凭据配置并固定访问 `com.codingrewind.memos.qa`，凭据缺失时绝不暗中回退读取个人日常钥匙串。
- **服务端环境变量隔离**，`MEMOS_ACCESS_TOKEN`、`AI_API_KEY` 与 `REWIND_WEBHOOK_SECRET` 仅通过服务器本地未入库的 `.env` 注入容器环境，仓库只保留占位模板 `.env.example`。

2026-11-12 的本机交付安装验收已确认，普通启动可读取远端热池，未出现 Keychain 弹窗。该次验收使用本机 ad-hoc 构建和进程环境注入。

## 导出、删除与留存期限

1. **自主导出**，由于全部片段以标准 Markdown 与清晰标签存于用户自托管的 `usememos/memos`，用户可随时通过 `Memos` 原生界面或 `/api/memos` 接口批量导出包含原文、脉络抬头、`<!-- rewind-context-v1 -->` 上下文评论、`<!-- rewind-note-v1 -->` AI 笔记评论、出处链接与时间戳的完整数据。
2. **单条与全量删除**，物理删除仅限桌面端毛玻璃浮窗、终端 `coding-rewind delete <id>` 或 `Memos` 网页界面人工执行（绝不通过 MCP 向 AI 暴露）；删除记录（或清空带 `#rewind/` 标签条目）时，关联的上下文评论与 AI 笔记评论随主记录一并移除，本机 `hot_cache.json`、`outbox.jsonl` 与 `local_notes.json` 同步清理对应条目。为防止离线删漏导致重连复活，已同步至 `Memos` 的卡片在断网或未配置云端时拒绝离线物理删除，仅未上传的本地暂存可直接从离线队列清除。卸载浏览器扩展或清理浏览器本地存储会清除扩展内未发送的离线队列，已成功同步至 `Memos` 的记录不受影响。
3. **热窗口冷却而非静默删除**，超过 72 小时的记录以及标记为 `#rewind/synthesized` 的已成文记录只是自然退出桌面毛玻璃热流浮窗，不会在后台被自动删除，用户仍可在 `Memos` 或通过 Antigravity `/rewind` 技能随时检索调阅。
