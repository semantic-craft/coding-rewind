# AGENTS.md

实现、评审或验收前先读 [lessons.md](lessons.md) 与本文件，再按需查阅下表文档：

| 入口 | 内容与触发时机 |
| --- | --- |
| [docs/code-quality.md](docs/code-quality.md) | 修复、实现与后续验收的代码标准和证据要求 |
| [progress/index.html](progress/index.html) | 当前实现、验证、合并及安装进度，数据原件为 progress/progress.json |
| [README.md](README.md) | 项目定位、组件分工与快速开始 |
| [docs/architecture.md](docs/architecture.md) | 端到端数据流、Memos REST 线级契约、离线缓冲与宿主接线 |
| [docs/requirements.md](docs/requirements.md) | 用户一手原话、已拍板决定、MVP 与非目标边界 |
| [docs/sources.md](docs/sources.md) | 复用或对照的 MIT 上游项目及 GPL/AGPL/无许可排除清单 |
| [docs/privacy.md](docs/privacy.md) | 原文与 AI 摘要边界、凭据存储、导出与删除规则 |
| [docs/milestones.md](docs/milestones.md) | M0 至 M4 分期验收标准 |
| [docs/contributing.md](docs/contributing.md) | 人机协作与公开仓库提交边界 |
| [docs/DECISIONS.md](docs/DECISIONS.md) | 跨进程文件锁、宿主代理头与静态扫描等非显然工程约束记录 |

## 统一架构与源码导航

系统以单实例原版 `usememos/memos` 为唯一事实源，不在客户端另建业务数据库或自定义编辑器：

- **云端主干 `deploy/vps/`**，运行官方固定版本 `neosmemo/memos:26.11.0` 容器提供 `/api/memos` 存储，旁挂纯 Python 3 标准库服务 `deploy/vps/enricher/enricher.py`（默认直连 DeepSeek 官方 API `https://api.deepseek.com` 与 `deepseek-flash` 即 `DeepSeek-V4.1-Flash` 非思考 JSON 模式，亦兼容 OpenAI 协议端点），支持 Standard Webhooks `POST /webhook` 验签触发、5 秒容器内网轮询自愈，以及通过 `REWIND_SUMMARY_LANGUAGE`（`auto`、`zh-Hans`、`en`）按剪藏语种自动或固定生成中英文摘要抬头。
- **网页端剪藏 `extensions/web-clipper/`**，Manifest V3 薄扩展，内置简体中文与英文界面本地化（`_locales/` 与 `i18n.js`，支持跟随浏览器或手动切换），覆盖任意 `http(s)` 网页并适配 ChatGPT、Claude 与 Gemini 对话上下文，支持选区多行就近悬浮“暂存”胶囊（含手势门控、可编辑区避让、生效范围与排除域名设置）、右键菜单及 `⌃⌥⇧⌘S`（`Hyper+S`）或 `Alt+Shift+S` 快捷键，按需懒加载提取去行号代码块与富文本 Markdown：在聊天页附带会话 ID、整个会话首轮开场提问（`Session Opening`）、紧邻提问及最近 4 轮对话；在普通网页提取页面导语与开头数行正文（`Page Lead`）写入上下文评论以赋能云端摘要，并在 `sourceUrl` 自动生成浏览器原生支持的 W3C Scroll-to-Text-Fragment（`#:~:text=...`）精确回跳锚点，由后台 Service Worker 直连 Memos REST API 并附带 `chrome.storage.local` 离线重放队列。
- **桌面端浮窗 `Sources/CodingRewindApp/` 与 `Sources/CodingRewindCore/`**，原生 Swift 6 AppKit 状态栏（`NSStatusItem` + `NSMenu`）、应用主菜单与非激活毛玻璃浮窗，支持简体中文与英文界面实时无重启切换、`SMAppService.mainApp` 登录时静默启动（同步读取 `keyAELaunchedAsLogInItem` 不弹浮窗），以及基于 GitHub Releases、`SHA256SUMS.txt` 与 `SecStaticCode`（含 `TeamIdentifier` 防降级门禁）的应用内自动更新。支持在 Antigravity、ChatGPT 与 Gemini 桌面端划选对话后弹出非激活“暂存”胶囊，在 DSH（DeepSeek Harness，`com.deepseek.dsh`）桌面端由轻量零依赖插件渲染选区下方闭合 Shadow DOM“暂存”胶囊并同步会话上下文，支持默认 `⌃⌥⇧⌘S`（`Hyper+S`）捕获选区、`⌃⌥R` 速览近 72 小时热流卡片，内置停靠式“脉络”预览抽屉（`⌘I` 或行内 `脉络` 按钮，三级 `Esc` 收起）直接查看完整选中原文、会话或网页开头留底、紧邻提问、近期轮次与 AI 笔记；通过显式 `SourceLocator` 区分网页 `http(s)` 打开（校验 `NSWorkspace.shared.open` 返回值并在失败时提示）、Antigravity 会话 ID 一键复制/唤醒与 DSH 会话（`dsh-session://<sessionId>`）经插件直达原会话及复制会话 ID 兜底（绝不向系统 LaunchServices 投递未注册的 `conversation://` 或 `dsh-session://` 协议），支持单条或批量归档（`⌘E`）与删除（`⌘⌫` 在底部展开行内红色确认条，`⌥⌘⌫` 或按住 `Option` 点击直接删除），并提供卡片行内按钮及右键上下文菜单。在“设置 → 插件与权限”并列管理 Antigravity 插件与 DSH 插件（DeepSeek Harness），并提供“AI 接入与权限”（`AI Access & Permissions`）分区，展示本机 MCP 状态、只读与读写权限切换开关及一键复制零明文 MCP JSON 配置按钮。`⌘Return`（或“开始对话”）先在浮窗内展开可编辑多行接聊草稿框（`Esc` 返回列表），预填附带每张卡片标识（`- 卡片 ID` / `- Clip ID`）及读写模式下 `append_snippet_note`/`create_snippet` 回写引导的完整提示词；选中 Antigravity 时主操作为“复制并唤醒 Antigravity”、次操作为“直接新建对话”（经官方 `coding-rewind/launcher` sidecar 调用 `agentapi new-conversation`）；选中 DSH 时主操作（`⌘Return`）为“填入 DSH 新会话”（经轻量 DSH Desktop 插件复用当前或最近工作区空白会话并以 `whenDraftExists: 'append'` 预填草稿不自动发送，确认预填后按「填入后归档」勾选归档）、次操作为“复制并唤醒 DSH”。未知结果不自动重发。通过 `outbox.jsonl`、`hot_cache.json` 与 `local_notes.json` 保障断网及纯本机可用（已同步片段拒绝离线物理删除，未上传的本地暂存可直接从离线队列移除）。
- **宿主上下文、DSH 插件与单二进制 Agent 接口 `Sources/CodingRewindCLI/` 与 `dsh-plugin/coding-rewind-dsh/`**，`AntigravityCaptureContext.swift` 只读取已确认会话编号对应的官方 transcript，`DSHCaptureContext.swift` 读取 DSH 插件导出的受保护只读活跃会话快照 `dsh-active-session.json`（`0600`、`O_NOFOLLOW`），两者均以唯一选区消息确定会话 ID、首轮开场提问（`Session Opening`）、紧邻前序提问和最多 4 个用户轮；无法定位时省略上下文。`ConversationSidecar` 负责 Antigravity 接聊；`dsh-plugin/coding-rewind-dsh/` 负责 DSH Desktop 的空白会话预填（`dsh-handoff/`）、原会话跳转（`dsh-actions/`）、选区下方暂存胶囊（`dsh-captures/`）与活跃会话导出（不接触 Memos 凭据）；单二进制 `coding-rewind`（固定安装路径 `~/Library/Application Support/CodingRewind/bin/coding-rewind`）直连 `CodingRewindCore` 提供八个 CLI 子命令（`list`、`search`、`get`、`create`、`update`、`note`、`archive`、`delete`）与内嵌 `coding-rewind mcp` stdio 服务（固定暴露 `list_snippets`、`search_snippets`、`get_snippet`、`archive_snippet`、`create_snippet`、`update_snippet_metadata`、`append_snippet_note` 七个领域工具，绝不向 Agent MCP 暴露物理删除 `delete`；当 `ai_access_mode` 为 `read_only` 时同步拒绝全部 4 个 MCP 写入工具及 CLI 写删子命令 `create`/`update`/`note`/`archive`/`delete`，保留只读查询，支持 `hot_cache.json`/`outbox.jsonl`/`local_notes.json` 离线与本机回退及 `>72h`、`#rewind/synthesized` 查询），经 `~/.config/agent-mcp/servers.json` 或设置页一键复制 JSON 跨宿主接线。

## Memos REST 线级契约不变量

三端与 Agent 接口读写必须严格遵守同一套标签状态机与正文布局，改动任一端时须同步核对其他端：

1. **标签流转**，来源标签集合为 `#source/<antigravity|dsh|chatgpt|claude|gemini|macos|web|agent>`（`create_snippet` 默认写入 `#source/agent`，首行额外自定义 `#<tag>` 原样保留）。新建片段写入 `#rewind/pending`（若 `create_snippet` 创建时已提供元数据抬头则直接写入 `#rewind/ready`）；若随附对话上下文评论，同时打上 `#rewind/has-ctx`。`rewind-enricher` 补齐抬头后将 `#rewind/pending` 与 `#rewind/has-ctx` 替换为 `#rewind/ready`；归档成文更新为 `#rewind/synthesized`，`update_snippet_metadata` 亦支持增删首行自定义标签及归档与取消归档流转。
2. **上下文评论、AI 笔记评论与等待窗口**，客户端通过 `POST /api/memos/<serverId>/comments?commentId=<clientClipId>-ctx` 提交首行带 `<!-- rewind-context-v1 -->` 标记的 `PRIVATE` 评论；若主记录含 `#rewind/has-ctx` 且评论尚未到达，`rewind-enricher` 在创建后 15 秒内推迟处理以避免竞态漏读，满 15 秒后优雅降级。Agent 或 CLI 执行 `append_snippet_note`（`coding-rewind note`）时，通过 `POST /api/memos/<serverId>/comments?commentId=<noteCommentId>` 提交首行带 `<!-- rewind-note-v1 -->` 标记的 `PRIVATE` 评论（与 `<!-- rewind-context-v1 -->` 严格隔离，未配置 Memos 的 `localOnly` 模式下存入 `<dataDir>/local_notes.json`），`get_snippet` 解析并返回按时间排序的 `notes`。
3. **原文零篡改**，客户端使用符合 `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$` 的 `memoId` 幂等写入，可见度固定为 `PRIVATE`；无论是 `rewind-enricher` 还是 `update_snippet_metadata`（`coding-rewind update`），均只允许改写首行标签与顶部引用块元数据 `Title`、`Session`、`Context`、`Keywords`、`Source`，下方的 `<verbatim_selected_markdown>` 原文必须 100% 逐字节原样保留。

## 凭据、安装路径与验收隔离

- **数据目录**，`CODING_REWIND_DATA_DIR` 优先，缺省为 `~/Library/Application Support/CodingRewind`。
- **服务地址与 AI 接入权限**，`CODING_REWIND_MEMOS_URL` 优先，其次读取 `<dataDir>/config.json` 的 `memos_url` 字段（远端地址强制要求 `https://`，仅 `localhost`/`127.0.0.0/8`/`[::1]` 回环地址允许 `http://`）；`CODING_REWIND_AI_ACCESS=read_only|read_write` 优先（非空非法值按故障关闭降级为 `read_only`，接管时禁用设置页开关并提示环境变量来源），其次读取 `<dataDir>/config.json` 的 `ai_access_mode` 字段（`"read_only"` | `"read_write"`，默认 `"read_write"`）。保存任一字段时必须保留另一字段，严禁将任何访问令牌写入 `config.json`、`mcp_config.json` 或 `servers.json`。
- **访问令牌与 QA 隔离**，`CODING_REWIND_MEMOS_TOKEN` 优先，其次在非 QA 启动时支持本机 `<dataDir>/DeveloperCredentials.plist`（强制 `O_NOFOLLOW`、单硬链接、当前用户属主与 `0600` 权限，并校验 `op` 可执行文件的 AgileBits `Developer ID` 签名后调用 `op read`），再其次读取 macOS Keychain 服务 `com.codingrewind.memos`；当设置 `CODING_REWIND_QA=1` 时强制切换至独立钥匙串服务 `com.codingrewind.memos.qa` 并忽略开发凭据文件，缺失时直接报错退出，绝不回退读取个人钥匙串。
- **宿主接聊**，`coding-rewind-sidecar` 由 Antigravity 管理并从其 `PATH` 解析 `agentapi`，不得从其他进程提取运行环境。私有 `handoff/` 与 `dsh-handoff/` 分别保存 Antigravity 与 DSH 的请求与回执（另设 `dsh-actions/` 与 `dsh-captures/` 分别承接 DSH 原会话回跳与选区胶囊捕获），旧 sidecar 只消费前者。双方均在调用前落盘 `dispatching`，未知结果不重发。DSH 插件运行在 `~/.dsh/profiles/desktop` 且不接收 Memos 凭据或 `CODING_REWIND_*` 启动环境，旧配置 `conversation-host.json` 中的 `"codex"` 在启动时自动迁移为 `"dsh"`。实际接聊边界见 [README.md](README.md#在-antigravity-接聊) 与 [README.md](README.md#在-dsh-接聊)。
- **固定安装位置与目录禁区**，安装 Antigravity 插件时必须将 `coding-rewind-sidecar` 与 `coding-rewind` 拷入 `~/Library/Application Support/CodingRewind/bin/`（并清理遗留旧脚本），安装 DSH 插件时必须将零依赖插件包拷入 `~/Library/Application Support/CodingRewind/dsh-plugin/coding-rewind-dsh/`（写入显式 `dataDir` 的 `0600` `runtime-config.json`）并经 `dsh plugin --profile desktop add` 注册，应用启动及自动更新就绪替换时同步刷新已安装的辅助二进制与 DSH 插件，严禁在插件、MCP 或钩子配置中引用 `.build/`；任何构建输出、更新暂存（固定位于 `<dataDir>/updates/`）与本地 QA 目录均不得使用 `/tmp` 或 `/private/tmp`。

## 验证与构建入口

- 全仓统一门禁运行 `./scripts/check`，依次执行静态卫生与边界检查、`swift test`、`deploy/vps/enricher` 单元测试、`extensions/web-clipper` 单元测试、`dsh-plugin/coding-rewind-dsh` 单元测试、Shell 语法校验与应用图标、本地化资源及发布打包校验。
- 原生应用打包运行 `./scripts/build-app-bundle.sh`，在 `.build/CodingRewind.app` 生成内嵌 `AppIcon.icns`、`MenuBarIcon` 模板图标、`zh-Hans.lproj`/`en.lproj` 资源并启用 `LSUIElement` 的签名校验包；公开构建运行 `./scripts/package-release.sh`（自动传入 `SKIP_DEVELOPER_CREDENTIALS=1`）输出双端压缩包与 `SHA256SUMS.txt`。
- 正式发布经 `./scripts/package-release.sh --notarize`（或默认非 QA/非 `SKIP_DEVELOPER_CREDENTIALS=1` 发布）通过 `macos-notary-profile` 解析公证凭据并完成公证、staple 与 Gatekeeper 校验后再封包。
