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

- **云端主干 `deploy/vps/`**：原版 `neosmemo/memos:26.11.0`（`/api/memos`）为唯一事实源，不在客户端另建业务库或编辑器；旁挂标准库 `deploy/vps/enricher/enricher.py`（Webhook + 5 秒轮询幂等补齐抬头）。
- **网页剪藏 `extensions/web-clipper/`**：Manifest V3 后台 Service Worker 直连 `/api/memos` 并带 `chrome.storage.local` 离线重放队列，严禁借自定义 URL Scheme 唤醒桌面端。
- **桌面端 `Sources/CodingRewindApp/`、`Sources/CodingRewindCore/`**：Swift 6 AppKit 状态栏与资料库（`NSStatusItem` + `NSMenu` + `NSApp.mainMenu`，禁用 `MenuBarExtra` 与 `.toolTip`）；`SystemURLOpener.open(_:)` 校验返回值且不向系统投递 `conversation://` 或 `dsh-session://`；离线仅用 `outbox.jsonl`（锁 `outbox.jsonl.lock`）、`hot_cache.json`、`local_notes.json`。
- **宿主与单二进制接口 `Sources/CodingRewindCLI/`、`dsh-plugin/coding-rewind-dsh/`**：DSH 插件零依赖且不接触凭据；`~/Library/Application Support/CodingRewind/bin/coding-rewind` 提供 8 个 CLI 子命令与 `coding-rewind mcp`（7 个工具，绝不向 MCP 暴露 `delete`；`read_only` 模式同步拦截全部 4 个 MCP 写工具与 CLI `create`/`update`/`note`/`archive`/`delete`）。
- **QA 与偏好隔离**：`CODING_REWIND_QA=1` 强制切换 `com.codingrewind.memos.qa`；测试 `UserDefaults` suite 须以 `dev.codingrewind.qa.` 开头且退出前清理。
- **统一验证**：修改后必须跑通 `./scripts/check`（静态边界、线级契约、形式化验证、`swift test`、三端单测、真实 Memos E2E 及签名图标门禁）。

## Memos REST 线级契约不变量

三端与 Agent 接口读写必须严格遵守同一套标签状态机与正文布局，改动任一端时须同步核对其他端：

1. **标签流转**，来源标签集合为 `#source/<antigravity|dsh|chatgpt|claude|gemini|macos|web|agent>`（`create_snippet` 默认写入 `#source/agent`，首行额外自定义 `#<tag>` 原样保留）。新建片段通常写入 `#rewind/pending`。采集时关闭 AI 整理，或 `create_snippet` 已提供元数据抬头，直接写入 `#rewind/ready`。待整理片段随附上下文评论时加 `#rewind/has-ctx`。`rewind-enricher` 补齐抬头后将 `#rewind/pending` 与 `#rewind/has-ctx` 替换为 `#rewind/ready`；归档成文更新为 `#rewind/synthesized`，`update_snippet_metadata` 亦支持增删首行自定义标签及归档与取消归档流转。位置记录为首行 `#rewind/place #<project|topic|person>/<slug>` 的独立记录（`memoId` 为 `pl-<p|t|u>-<slug>`，不含片段状态标签），片段落位即首行 `#<kind>/<slug>` 标签，`rewind-enricher` 只能从 active 位置中选择（封闭词表），「未落位」由「`ready`/`synthesized` 且无位置标签」推导，格式见 [docs/architecture.md](docs/architecture.md)。
2. **上下文评论、AI 笔记评论与等待窗口**，客户端通过 `POST /api/memos/<serverId>/comments?commentId=<clientClipId>-ctx` 提交首行带 `<!-- rewind-context-v1 -->` 标记的 `PRIVATE` 评论；若主记录含 `#rewind/has-ctx` 且评论尚未到达，`rewind-enricher` 在创建后 15 秒内推迟处理以避免竞态漏读，满 15 秒后优雅降级。Agent 或 CLI 执行 `append_snippet_note`（`coding-rewind note`）时，通过 `POST /api/memos/<serverId>/comments?commentId=<noteCommentId>` 提交首行带 `<!-- rewind-note-v1 -->` 标记的 `PRIVATE` 评论（与 `<!-- rewind-context-v1 -->` 严格隔离，未配置 Memos 的 `localOnly` 模式下存入 `<dataDir>/local_notes.json`），`get_snippet` 解析并返回按时间排序的 `notes`。
3. **原文零篡改**，客户端使用符合 `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$` 的 `memoId` 幂等写入，可见度固定为 `PRIVATE`；无论是 `rewind-enricher` 还是 `update_snippet_metadata`（`coding-rewind update`），均只允许改写首行标签与顶部引用块元数据 `Title`、`Session`、`Context`、`Keywords`、`Source`，下方的 `<verbatim_selected_markdown>` 原文必须 100% 逐字节原样保留。

## 凭据、安装路径与验收隔离

- **数据目录**，`CODING_REWIND_DATA_DIR` 优先，缺省为 `~/Library/Application Support/CodingRewind`。
- **服务地址与 AI 接入权限**，`CODING_REWIND_MEMOS_URL` 优先，其次读取 `<dataDir>/config.json` 的 `memos_url` 字段（远端地址强制要求 `https://`，仅 `localhost`/`127.0.0.0/8`/`[::1]` 回环地址允许 `http://`）；`CODING_REWIND_AI_ACCESS=read_only|read_write` 优先（非空非法值按故障关闭降级为 `read_only`，接管时禁用设置页开关并提示环境变量来源），其次读取 `<dataDir>/config.json` 的 `ai_access_mode` 字段（`"read_only"` | `"read_write"`，默认 `"read_write"`）。保存任一字段时必须保留另一字段，严禁将任何访问令牌写入 `config.json`、`mcp_config.json` 或 `servers.json`。
- **访问令牌与 QA 隔离**，`CODING_REWIND_MEMOS_TOKEN` 优先，其次在非 QA 启动时支持本机 `<dataDir>/DeveloperCredentials.plist`（强制 `O_NOFOLLOW`、单硬链接、当前用户属主与 `0600` 权限，并校验 `op` 可执行文件的 AgileBits `Developer ID` 签名后调用 `op read`），再其次读取 macOS Keychain 服务 `com.codingrewind.memos`；当设置 `CODING_REWIND_QA=1` 时强制切换至独立钥匙串服务 `com.codingrewind.memos.qa` 并忽略开发凭据文件，缺失时直接报错退出，绝不回退读取个人钥匙串。
- **宿主接聊**，`coding-rewind-sidecar` 由 Antigravity 管理并从其 `PATH` 解析 `agentapi`，不得从其他进程提取运行环境。私有 `handoff/` 与 `dsh-handoff/` 分别保存 Antigravity 与 DSH 的请求与回执（另设 `dsh-actions/` 与 `dsh-captures/` 分别承接 DSH 原会话回跳与选区胶囊捕获），旧 sidecar 只消费前者。双方均在调用前落盘 `dispatching`，未知结果不重发。DSH 插件运行在 `~/.dsh/profiles/desktop` 且不接收 Memos 凭据或 `CODING_REWIND_*` 启动环境，旧配置 `conversation-host.json` 中的 `"codex"` 在启动时自动迁移为 `"dsh"`。实际接聊边界见 [README.md](README.md#在-antigravity-接聊) 与 [README.md](README.md#在-dsh-接聊)。
- **固定安装位置与目录禁区**，安装 Antigravity 插件时必须将 `coding-rewind-sidecar` 与 `coding-rewind` 拷入 `~/Library/Application Support/CodingRewind/bin/`（并清理遗留旧脚本），安装 DSH 插件时必须将零依赖插件包拷入 `~/Library/Application Support/CodingRewind/dsh-plugin/coding-rewind-dsh/`（写入显式 `dataDir` 的 `0600` `runtime-config.json`）并经 `dsh plugin --profile desktop add` 注册，应用启动及自动更新就绪替换时同步刷新已安装的辅助二进制与 DSH 插件，严禁在插件、MCP 或钩子配置中引用 `.build/`；任何构建输出、更新暂存（固定位于 `<dataDir>/updates/`）与本地 QA 目录均不得使用 `/tmp` 或 `/private/tmp`。

## 验证与构建入口

- 全仓统一门禁运行 `./scripts/check`。
- 原生应用打包运行 `./scripts/build-app-bundle.sh`（生成 `.build/CodingRewind.app`）；公开构建运行 `./scripts/package-release.sh`（自动传入 `SKIP_DEVELOPER_CREDENTIALS=1` 输出双端压缩包与 `SHA256SUMS.txt`）。
- 正式发布运行 `./scripts/package-release.sh --notarize`，经 `macos-notary-profile` 完成公证、staple 与 Gatekeeper 校验后封包。
