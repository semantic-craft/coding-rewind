# 统一架构与线级数据契约

本项目采用单一开源事实源加极薄边缘感官架构，以自托管原版 `usememos/memos` 承接全部持久化存储与 Webhook 事件，客户端只保留毫秒级无感选区采集、近 72 小时毛玻璃热流速览、拉起 **Google Antigravity App 2.x 或 Codex** 对话的极薄界面，以及供各 Coding Agent 跨宿主共用的单二进制 `coding-rewind`（8 个 CLI 子命令 + 受只读/读写权限门控的内嵌 7 工具 `stdio` MCP）。

需求依据见 [requirements.md](requirements.md)，开源底座与许可核查见 [sources.md](sources.md)，凭据与数据保护规则见 [privacy.md](privacy.md)。

## 架构设计约束

以下约束直接承接用户一手需求与工程边界：

- **定位与时间窗口**，聚焦未来 1 至 3 天内确定要用到的高质量 AI 对话段落、提示词或思路，默认展示近 72 小时未归档热流卡片，不做全量聊天自动备份。
- **采集零打断**，在当前主线编码或阅读进行中一键暂存选中文本，不弹出协议确认窗，不抢夺原应用输入焦点，不向当前会话插入保存指令，也不强迫填写标题或标签。
- **双端统一汇聚**，同时覆盖 Antigravity、ChatGPT、Gemini 桌面应用与浏览器中的任意 `http(s)` 网页及 ChatGPT、Claude、Gemini，采集结果进入同一个 `Memos` 实例。
- **原文锁死与脉络定锚**，用户选中的原文必须逐字完整保留，不得被摘要替代；前序提问与周围对话轮次作为上下文交由后台增强器提炼结构化抬头，AI 补充信息与原文严格分区展示。
- **回归主力宿主成文与闭环回流**，长对话追问与对照写稿直接交给用户日常使用的 Antigravity App 2.x、Codex 等主力宿主完成，通过 `agentapi new-conversation`、Codex app-server 队列以及单二进制 `coding-rewind`（CLI 与 `coding-rewind mcp` 七个领域工具）贯通；宿主 AI 在读写权限下可将结论笔记挂回原卡片或暂存新提纲回流浮窗，不在菜单栏工具内重复维护富文本编辑器或本地双数据库同步逻辑。

## 端到端拓扑

```text
[桌面端 Antigravity App 2.x / macOS 应用]          [网页端 任意 http(s) 网页 / ChatGPT / Claude / Gemini]
  划选弹出非激活暂存胶囊或按 ⌃⌥⇧⌘S 捕获选区          Manifest V3 扩展弹出暂存胶囊或按快捷键提取选中 Markdown
  + 按选区会话编号读取对应 transcript         + 聊天页提取前序提问与最近 4 轮对话，普通网页仅存选段与出处
                  │                                                  │
                  └────────────────────────┬─────────────────────────┘
                                           ▼
                    POST /api/memos?memoId=<clientClipId>
                    POST /api/memos/<serverId>/comments
                                           │
                                           ▼
             [单一事实源后端  deploy/vps  阿里云容器栈]
              • neosmemo/memos:26.11.0 原版 /api/memos 存储与评论挂载
              • rewind-enricher 验签 Webhook + 5 秒容器内网自愈轮询
              • 等待上下文评论到达后调用兼容接口生成 Title / Session / Context
              • 保留 100% 选中原文并将标签翻转为 #rewind/ready
                                           │
                  ┌────────────────────────┴─────────────────────────┐
                  ▼                                                  ▼
[出口 1  CodingRewindApp 毛玻璃速览浮窗]           [出口与回写通道 2  单二进制 coding-rewind (CLI + MCP)]
 • ⌃⌥R 非激活 NSPanel 速览 72 小时热流卡片          • ~/Library/Application Support/CodingRewind/bin/coding-rewind
 • hot_cache / outbox / local_notes 保障离线可用    • list / search / get / create / update / note / archive / delete
 • 勾选卡片可归档、删除或带卡片 ID 按 ⌘Return 接聊  • MCP 暴露 7 个领域工具（绝无 delete），受 ai_access_mode 只读/读写门控
```

## 四大组成部分职责

### 1. 云端单一事实源与幂等增强器

位于 `deploy/vps/`，由 `docker-compose.yml` 编排两个轻量容器：

- **原版 `neosmemo/memos:26.11.0`**，零源码修改提供 `/api/memos` REST 接口与评论挂载，作为跨设备唯一事实源。
- **幂等增强器 `deploy/vps/enricher/enricher.py`**，使用 `python:3.12-slim` 纯标准库实现并固定非特权用户运行，零第三方 pip 依赖。由于 `Memos` 内置 Webhook 客户端对私网地址启用 SSRF 拦截，增强器同时提供两条触发通道：
  1. `POST /webhook` 接口按 Standard Webhooks 规范校验 `webhook-id`、`webhook-timestamp` 与 `webhook-signature` 的 HMAC-SHA256 签名，适用于经反代接入实时通知。
  2. 默认每 5 秒从 `http://memos:5230/api/memos?pageSize=50` 开始，沿 `nextPageToken` 枚举完整候选后再逐条增强。页大小不限制候选总数，漏通知或重启后仍为 pending 的记录会在后续扫描中恢复处理。

### 2. macOS 原生菜单栏与毛玻璃浮窗

`NativeChatAXCapture` 把当前 ChatGPT 或 Gemini 窗口转换为不可变消息快照。`NativeConversationContext` 只接受唯一选区归属或明确的消息锚点，遇到缺失消息停止回溯。`NativeSelectionMarkdown` 根据真实剪贴板 HTML 恢复格式，ChatGPT 代码编辑器的代码行提供缩进与空行校验。捕获完成后复核窗口和消息序列，发生会话变化时省略上下文。

`NativeChatBacklink` 使用 ChatGPT 的 **Open on chatgpt.com** 或 Gemini 的 **在浏览器中打开**。ChatGPT 从本次新增的内置浏览器页面读取私有会话 URL；Gemini 从默认 Chrome 的新增标签读取。只关闭能够归属于本次操作的标签，不调用公开分享。无法确认链接时不猜会话 ID。


位于 `Sources/CodingRewindApp/` 与 `Sources/CodingRewindCore/`：

- **两阶段划词探测与非激活暂存胶囊 `SelectionPopupController.swift`**，参照 MIT 项目 `GaimsDevSoftware/linuxpop` 与 `p0deje/Maccy`，仅针对白名单宿主 `com.google.antigravity`、`com.openai.codex` 与 `com.google.GeminiMacOS` 响应拖拽（距离不少于 6pt）、双击或 Shift 扩展选区手势（含 Shift 方向键扩选），浏览器与普通单次点击一律忽略。第一阶段探测完全只读，零剪贴板触碰且零 `CGEvent` 投递，排除编辑器、终端与输入框后在选区居中展示带 `.nonactivatingPanel` 的胶囊按钮（`com.google.antigravity` 与 `com.google.GeminiMacOS` 默认锚定于选区上方 8pt，靠近屏幕顶端时下翻；`com.openai.codex` 默认锚定于选区下方 8pt 以避让 ChatGPT 顶部原生选区栏，靠近屏幕底端时上翻），点击或按下捕获热键时原位反馈“暂存中…”与“已同步 / 待同步”并在 900 毫秒后自动收起，不额外抢焦或展开主 HUD；仅在配置缺失或报错时唤起非激活 HUD 给出提示。
- **零污染选区捕获 `MacOSSelection.swift`**，参照 MIT 项目 `tisfeng/SelectedTextKit` 与 `p0deje/Maccy`，触发捕获（默认 `⌃⌥⇧⌘S`，即 `Hyper+S`）时先读取焦点元素或聊天页面 `AXWebArea` 的 `kAXSelectedTextAttribute`；仅在为空或受限时先异步等待所有物理修饰键释放（上限 1 秒），再备份当前 `NSPasteboard.general.pasteboardItems` 的全部类型字节与 `changeCount`，投递 `CGEvent` 模拟 `⌘C` 并在 200 毫秒上限内异步检查 `changeCount` 增长，退出时于 `defer` 无条件还原原剪贴板；若 `changeCount` 未变则判定无选区，绝不误存旧剪贴板。当前台应用为 `com.google.antigravity` 时，从选区所属 `AXWebArea` 的本机会话 URL（`http://127.0.0.1:<port>/c/<uuid>` 或 `https://127.0.0.1/c/<uuid>`）确认编号，再由 Core 读取对应 transcript；不能定位消息时不附带猜测的上下文，当前台为 Safari、Chrome、Arc 或 Brave 时提取活动标签页标题与链接。
- **非激活毛玻璃浮窗 `QuickPeekHUDViews.swift`**，参照 `p0deje/Maccy` 使用带 `.nonactivatingPanel` 样式的 `NSPanel` 搭配 `.hudWindow` 材质 `NSVisualEffectView`，释放浮窗快捷键（默认 `⌃⌥R`）呼出近 72 小时热流卡片，支持关键词过滤、空格多选、`Esc` 分级收起（优先退出删前确认条，再关闭浮窗）以及区分 `待整理` 与 `AI 已整理` 状态徽标。每张卡片常驻行内归档与删除图标按钮及右键上下文菜单（归档、复制正文、查看来源、删除），勾选栏提供批量归档（`⌘E`）与删除（`⌘⌫` 弹出底部行内红色确认条，`⌥⌘⌫` 或按住 `Option` 点击直接删除）；刷新期间对正在删除中的卡片抑制重现，已成功删除卡片若远端列表暂存未清空则在本地过滤不复活。
- **全局快捷键 `AppShortcuts.swift`**，`ShortcutAction` 定义捕获（默认 `⌃⌥⇧⌘S`）与浮窗（默认 `⌃⌥R`）两个动作；启动时通过 `CodingRewind.captureSelectionShortcutSchemaVersion` 执行一次性 v2 迁移，仅将未自定义的旧版默认 `⌃⌥S` 平滑升级至 `⌃⌥⇧⌘S`，保留用户显式清空或自定义组合。`KeyboardShortcuts.Name` 是配置唯一来源，`AppShortcuts` 组织校验、真实注册状态与动作，主菜单、状态菜单、划词胶囊及 HUD 提示从同一配置派生。设置直接使用上游 Recorder，实时保存，清空保留禁用值，恢复默认仍走校验。系统快捷键、动作重键和当前主菜单冲突阻止保存；运行时注册失败保留配置，显示原始 OSStatus 并提供重试。仅实际生效的绑定显示菜单 keyEquivalent，录制期间暂停不显示失败。库内既有 Carbon 注册以独占选项申请，其他独占注册的冲突会返回失败；macOS 允许独占注册优先于其他应用的共享注册，无法枚举全部其他应用绑定。菜单跟踪按已接受的 keyDown 配对 keyUp，不受修饰键先释放影响。Carbon 注册与菜单跟踪负责事件，应用不另设监听器。`AppCoordinator` 在异步捕获期间拒绝重入，避免热键、菜单和按钮重复入队。
- **一键创建宿主对话与结论回写闭环**，勾选卡片按下 `⌘Return`，由 `ConversationPrompt` 组装包含每张卡片标识（中文 `- 卡片 ID：\`<id>\``、英文 `- Clip ID: \`<id>\``）、脉络抬头、原始选段及出处链接的共享 Markdown 提示词；当 `aiAccessMode == .readWrite` 时，末尾附带闭环说明，提示宿主 AI 在归纳推演后可凭卡片 ID 调用 `append_snippet_note` 将结论挂回原卡片，或调用 `create_snippet` 将新生成的提纲草稿暂存回 Coding Rewind（`aiAccessMode == .readOnly` 时省略该回写说明）。`AppCoordinator` 唯一持有目标与归档意图，HUD、菜单与快捷键调用同一个 `launchChecked(in:)`。目标偏好保存到 `conversation-host.json`，默认 Antigravity。已有任一宿主请求时始终先恢复它，不能切换目标覆盖已保存的意图。只有确认宿主实际收件后才允许归档。Antigravity 继续由官方 sidecar 调用 `agentapi new-conversation`，Codex 走下述官方队列与 App 唤醒链路。
- **AI 接入与权限面板**，在桌面端“设置 → 插件与权限”内设“AI 接入与权限”（`AI Access & Permissions`）分区，展示本机 MCP 二进制状态、只读与读写切换开关（原子写入 `<dataDir>/config.json` 的 `ai_access_mode` 字段并保留 `memos_url`，默认 `"read_write"`；当环境变量 `CODING_REWIND_AI_ACCESS` 非空时覆盖磁盘配置、禁用界面开关并展示环境管理提示）以及一键复制标准零明文 `mcpServers` JSON 配置按钮（面向 Claude Desktop、Cursor、Codex、Antigravity 等宿主）。
- **开机自启动、校验自动更新与双语界面 `LoginItemController.swift`、`AppUpdater.swift`、`Localization.swift` 与 `AppStrings.swift`**，`applicationDidFinishLaunching` 首行同步采样 `NSAppleEventManager.shared().currentAppleEvent`（识别 `keyAELaunchedAsLogInItem`）与 `--restarted-after-update`/`--background` 参数，使系统登录启动与更新重启保持静默驻留，而常规打开与 Dock 重开正常聚焦浮窗。`AppUpdater` 在私有 `<dataDir>/updates/` 目录暂存 GitHub Releases 资产，依次执行 `SHA256SUMS.txt` 摘要比对、`ditto` 解压与 `lsregister -u` 注销、`SecStaticCodeCheckValidityWithErrors`（含 `kSecCSStrictValidate`）及 `BundleSignatureAuthority.canReplace`（阻止 `Developer ID` 被 ad-hoc 或不同 `TeamIdentifier` 覆盖以保护 TCC 辅助功能授权），就绪后同步刷新 `bin/coding-rewind-sidecar` 与 `bin/coding-rewind`，并通过等待原 PID 退出的原子交换脚本完成回滚安全升级。桌面端采用纯枚举 `switch` 双语词表以兼容独立无 bundle 的辅助进程，网页扩展采用 `_locales/` 与 `i18n.js` 实时重渲染，云端 `enricher.py` 支持 `REWIND_SUMMARY_LANGUAGE=auto|zh-Hans|en`，三端共享不变的 Memos 标签与引用头契约。
- **本地离线韧性**，未配置地址或网络异常时，采集与 `create_snippet` 请求追加写入 `<dataDir>/outbox.jsonl` 并镜像更新 `<dataDir>/hot_cache.json`，纯本机模式下的 `append_snippet_note` 原子写入 `<dataDir>/local_notes.json`；断网时从本地缓存显示热卡，网络恢复后凭 `?memoId=<clientClipId>` 幂等冲刷队列。

刷新请求在网络等待前记录请求编号和本地卡片版本，提交时核对仍为最新、卡片未变化且捕获已结束。过期成功或失败响应都不覆盖当前卡片、缓存或提示。有效提交重读当前 outbox，并把同一合并结果交给 UI 与热缓存。捕获不会等待刷新网络请求；交错时放弃旧刷新，后续刷新再读取远端更新。

### 3. 浏览器 Manifest V3 薄剪藏扩展

位于 `extensions/web-clipper/`，零外部 npm 依赖且空闲态零额外模块加载，覆盖任意 `http://*/*`、`https://*/*` 网页并对 `chatgpt.com`、`chat.openai.com`、`claude.ai` 与 `gemini.google.com` 提供对话脉络提取：

- **纯函数提取层 `extractors.mjs`**，仅在实际保存选区时按需懒加载。参照 MIT 项目 `revivalstack/ai-chat-exporter`、`pionxzh/chatgpt-exporter`、`kepano/defuddle` 与 `mixmark-io/turndown`，把 DOM `Selection` 清洗转换为保留围栏代码块语言标识、Shiki / Expressive Code 逐行换行、GitHub `table.highlight` 代码表格、图片相对链接、GFM 任务列表、`<mark>`、`<kbd>` 与 `<details>/<summary>` 的 Markdown，自动剥离语法高亮器行号列并清洗普通网页 `og:site_name` 标题后缀；在 AI 聊天站点通过声明式 `TURN_ADAPTERS` 提取紧邻前序用户提问与截至当前消息的最近 4 轮问答文本，总长截断在 4000 字符以内。
- **页面内单动作暂存胶囊、范围控制与后台直连投递 `content.js`、`background.js`、`memos_payload.mjs` 与 `options.js`**，参照 MIT 项目 `mem0ai/mem0-chrome-extension`、`obsidianmd/obsidian-clipper`、`crimx/ext-saladict`、`floating-ui/floating-ui` 与 `ChatGPTBox-dev/chatGPTBox`，通过 `GestureGate` 仅对主按键拖拽、双击、Shift 扩展选区及键盘选区展示 Shadow DOM 隔离的“暂存”胶囊，避让可编辑输入框与在线代码编辑器（放行 `readonly` 与 `aria-readonly="true"`），按 `Range.getClientRects()` 单行上方居中、多行正向尾行下方或反向首行上方就近锚定，并在脚本重注入时调用 `__CODING_REWIND_HOOK__.dispose()` 清理旧宿主与监听器。选项页支持切换胶囊生效范围（全部网页 / 仅 AI 聊天网站 / 关闭）与排除域名列表（默认排除 Google Docs/Sheets/Slides、Figma、Canva），右键菜单、`⌃⌥⇧⌘S`（`Hyper+S`）与 `Alt+Shift+S` 在任意页面始终可用。后台 Service Worker 直接携带 `Authorization: Bearer <token>` 写入 `Memos` REST 接口，断网或服务端 5xx 时在 `chrome.storage.local` 缓存最多 50 条待发记录并幂等重试；只有队列写入成功才反馈待同步，本地存储拒绝会显示保存失败。

### 4. Antigravity 2.x 官方插件与单二进制 CLI / MCP

位于 `Sources/ConversationSidecar/`、`Sources/CodingRewindCLI/`、`Sources/CodingRewindCore/AntigravityIntegration.swift`、`Sources/CodingRewindCore/SnippetRepository.swift` 与 `Sources/CodingRewindCore/DeveloperCredentialsResolver.swift`：

- **按选区定位上下文 `AntigravityCaptureContext.swift`**，只读取已确认编号对应的 `~/.gemini/antigravity/brain/<conversationId>/.system_generated/logs/transcript.jsonl`，在完整记录中查找唯一匹配消息。上下文截止所选消息，最多含该用户轮及前三轮。重复或无法匹配时保留原文与已确认会话链接，省略提问和上下文，不读取其他会话。旧的全局最新 Hook 快照不再参与捕获。
- **固定二进制落点与插件布局**，参照 MIT 项目 `wxtsky/CodeIsland`，应用启动、插件安装与自动更新将 `coding-rewind-sidecar` 与 `coding-rewind` 拷入固定路径 `~/Library/Application Support/CodingRewind/bin/`（同时清理历史遗留旧脚本），向 `~/.gemini/config/plugins/coding-rewind/` 写入 `plugin.json`、sidecar 配置和说明全部 7 个领域 MCP 工具、只读权限边界及按卡片 ID 回写结论的 `skills/rewind/SKILL.md`。升级只撤下本插件生成的旧 Hook 处理器，保留其他处理器与已有用户数据。
- **单二进制 CLI 与内嵌领域 MCP**，`coding-rewind` 直接链接 `CodingRewindCore` 的 `SnippetRepository` 与 `DeveloperCredentialsResolver`，零外部第三方依赖同时提供 8 个终端子命令（`list`、`search`、`get`、`create`、`update`、`note`、`archive`、`delete`，支持 `--json`）与 `coding-rewind mcp` 标准 `stdio` JSON-RPC 2.0 服务。MCP 服务固定暴露 `list_snippets`、`search_snippets`、`get_snippet`、`archive_snippet`、`create_snippet`、`update_snippet_metadata`、`append_snippet_note` 七个领域工具（替代远端通用 41 个 Memos 工具与外部 Node 桥接进程；物理删除 `delete` 严格保留给终端 CLI 与桌面端人工操作，绝不向 Agent MCP 暴露）。每次 MCP 工具调用实时读取 `AIAccessMode`（无需重启 MCP 进程）：当处于 `read_only` 时，调用全部 4 个写入工具（`create_snippet`、`update_snippet_metadata`、`append_snippet_note`、`archive_snippet`）立即返回 `isError: true` 拒绝修改，3 个读取工具（`list_snippets`、`search_snippets`、`get_snippet`）保持可用。默认返回近 72 小时未归档片段，支持传入 `window: "all"`（或 `--window all` / `--window <N>h`）查询超过 72 小时的历史片段，传入 `status: "synthesized"` 或 `"all"` 查询已成文归档片段，并在未配置云端或断网时自动回退服务本机 `hot_cache.json`、`outbox.jsonl` 与 `local_notes.json`（`localOnly` / `offlineFallback`；离线状态下仅允许删除尚在本地 `outbox.jsonl` 的未上传暂存，拒绝删除已同步卡片）。通过 `~/.config/agent-mcp/servers.json` 或设置页一键复制配置指定 `command: "${HOME}/Library/Application Support/CodingRewind/bin/coding-rewind"` 与 `args: ["mcp"]` 即可跨宿主接入，任何 JSON 配置文件均不落盘明文令牌。

### 接聊请求与回执

`ConversationHandoff.swift` 为 Antigravity 保留 `handoff/` v1 文件契约，为 Codex 使用独立 `codex-handoff/`。旧 sidecar 不会消费 Codex 请求。两套目录都复用 `ConversationSidecarWorker` 的独占进程锁和状态流转，调用前先落盘 `dispatching`，不明结果保持 `unknown` 并禁止重发。请求、回执和逐卡归档进度只有既有 store 一个所有者，没有额外业务数据库或分阶段检查点。

Antigravity 成功只认结构化回执中的会话编号。Codex 成功必须同时有真实 thread 编号、turn 编号，以及首条用户消息的 `clientId` 和完整 UTF-8 提示词匹配。助手回复是否完成不影响收件事实。
请求在 45 秒后过期。未发布完整的请求会在过期后收敛为 `expired`，不会补发。成功、拒绝、过期或未知结果都会清理请求正文。已完成回执保留七天，仍被当前请求引用的回执继续保留，避免重启后失去结果。归档进度按卡片编号单独保存，重试不会重新创建会话。

安装器保留宿主配置的其他字段和已有 `projectId`。sidecar 检测到稳定二进制被替换后退出，由宿主的 `always` 重启策略启动新版。它不读取 Memos 令牌。

### Codex 的队列与原生 App 接管

`CodexAppIntegration.swift` 发现 `com.openai.codex` 应用和它的捆绑 CLI，显式 `CODING_REWIND_CODEX_BIN` 绝对路径优先，常规 CLI `~/.local/bin/codex` 作为后备。子进程不接收协调器注入的 Memos 凭据，启动环境也移除 `CODING_REWIND_*`。`CodexConversationClient.swift` 通过私有管道使用官方 `app-server --stdio` JSONL，每个响应按请求编号关联，忽略通知。只声明自己的客户端身份和 `experimentalApi`，不覆盖模型、sandbox 或审批设置。

1. 第一个短暂进程执行 `initialize`、`initialized`、`thread/start`，工作目录为用户主目录，仅设置 `thread_unload_delay_secs=0`。随后 `thread/name/set` 正常持久化空会话，`thread/unsubscribe` 释放运行时并退出。
2. 第二个短暂进程只读新会话，确认它未加载且没有轮次。随后仅向该专用新会话执行一次 `thread/queue/add`，以持久化请求 UUID 作为 `clientUserMessageId`。`thread/queue/list` 核对唯一条目和完整提示词后退出。
3. AppKit 层打开 `codex://threads/wake/<threadId>`。Codex App 接管首轮运行、审批与后续输入。第三个短暂进程只用 `thread/read` 核对真实首条用户消息，确认后写成功回执。它不 resume、不创建 turn，也不保留会话运行时。
4. 确认收件后 AppKit 层打开 `codex://threads/<threadId>` 导航到同一会话。打开失败保留已成功回执供重试，不能重新发送。归档按既有剩余卡片编号恢复。

上述写操作均在 durable worker 的 `dispatching` 之后发生。任何中断或不明结果都不再创建线程或投递消息，保留卡片让用户核对。所有短暂子进程有确认超时并在退出时关闭、终止和回收。

## Memos REST 共享线级契约

桌面端、浏览器扩展、云端增强器与单二进制 Agent 接口严格共用同一套 REST 契约：

### 1. 创建初始片段与 AI 直接暂存（`create_snippet`）

客户端或 Agent 生成满足 `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$` 的幂等标识 `clientClipId`，调用 `POST /api/memos?memoId=<clientClipId>`，请求体 `visibility` 固定为 `PRIVATE`。来源平台标签集合为 `#source/<antigravity|chatgpt|claude|gemini|macos|web|agent>`，首行同时支持附加经清洗的自定义 `#<tag>` 标签。附带对话上下文时的初始 `content` 模板如下：

```markdown
#rewind/pending #rewind/has-ctx #source/<antigravity|chatgpt|claude|gemini|macos|web|agent>

> **Source:** [<title_or_app>](<url_or_conversation_deeplink>) · <ISO8601_UTC>

<verbatim_selected_markdown>
```

当桌面普通应用或普通网页划选不含前序提问与近期对话轮次时，主记录仍保留 `> **Source:** [<title_or_app>](<url_or_conversation_deeplink>) · <ISO8601_UTC>`，但省略 `#rewind/has-ctx` 标签，仅保留 `#rewind/pending` 与 `#source/<macos|web>`，且不发送空白上下文评论，避免触发增强器等待窗口。

当通过 `create_snippet`（或 `coding-rewind create`）暂存提纲、草稿或总结时，默认来源标签为 `#source/agent`（默认出处标题为 `AI Synthesis`）：若调用时已提供任一结构化抬头（`Title`、`Session`、`Context` 或非空 `Keywords`），首行直接写入 `#rewind/ready #source/<platform>`（及可选 `#<tag>`）并输出引用块抬头与 100% 原样正文；若未提供结构化抬头，则写入 `#rewind/pending #source/<platform>`（及可选 `#<tag>`）与 `> **Source:** ...`，交由云端增强器异步补齐。

### 2. 挂载会话上下文评论与 AI 笔记评论（`append_snippet_note`）

若存在非空的前序提问或近期对话轮次，客户端从创建响应 `name` 字段取出 `serverId`，调用 `POST /api/memos/<serverId>/comments?commentId=<clientClipId>-ctx` 写入 `PRIVATE` 评论：

```markdown
<!-- rewind-context-v1 -->
Session Title: <sessionTitle>
Prompt: <prompt>

### Recent Turns
<up to 4 preceding User/Assistant turns>
```

当通过 `append_snippet_note`（或 `coding-rewind note`）向已有片段追加推演结论或批注时，生成满足同一 `<= 36` ASCII 字节正则的 `noteCommentId`，调用 `POST /api/memos/<serverId>/comments?commentId=<noteCommentId>` 写入首行带 `<!-- rewind-note-v1 -->` 标记的 `PRIVATE` 评论：

```markdown
<!-- rewind-note-v1 -->
Created At: <ISO8601_UTC>
Author: <single_line_author>

<verbatim_note_markdown>
```

`<!-- rewind-note-v1 -->` 与 `<!-- rewind-context-v1 -->` 在解析层严格双向隔离，互不混读；在未配置 Memos 地址的 `localOnly` 模式下，笔记原子写入 `<dataDir>/local_notes.json`。调用 `get_snippet`（或 `coding-rewind get`）时，客户端合并云端 `<!-- rewind-note-v1 -->` 评论与本地笔记、按评论标识去重并按创建时间升序返回 `notes`。

### 3. 幂等增强、元数据更新（`update_snippet_metadata`）与原文保真回写

`rewind-enricher` 扫描到含 `#rewind/pending` 的记录后按以下状态机流转：

1. 若记录已含 `#rewind/ready` 或 `#rewind/synthesized`，直接跳过，保证重复投递零额外模型调用。
2. 若记录含 `#rewind/has-ctx`，拉取 `/api/memos/<serverId>/comments` 查找含 `<!-- rewind-context-v1 -->` 的评论；若尚未到达且距创建时间不足 15 秒则暂缓等待下一轮，满 15 秒后以现有信息继续处理。
3. 调用环境变量配置的 OpenAI 兼容 `chat/completions` 接口请求严格 JSON 结构 `title`、`session_topic`、`context_summary` 与 `keywords`。
4. 通过 `PATCH /api/memos/<serverId>?updateMask=content` 原子替换顶部标签与引用头，100% 保持 `<verbatim_selected_markdown>` 原封不动：

```markdown
#rewind/ready #source/<platform>

> **Title:** <title>
> **Session:** <session_topic>
> **Context:** <context_summary>
> **Keywords:** <kw1>, <kw2>, <kw3>
> **Source:** [<title_or_app>](<url_or_conversation_deeplink>) · <ISO8601_UTC>

<verbatim_selected_markdown>
```

Agent 或终端执行 `update_snippet_metadata`（`coding-rewind update`）时遵循同一原文零篡改铁律：只允许重写首行标签（含状态标签归档/取消归档流转以及自定义 `#<tag>` 增删）与顶部引用块元数据（`Title`、`Session`、`Context`、`Keywords`），正文区域的 `<verbatim_selected_markdown>`（包括代码围栏、缩进空行与正文内出现的 `#tag` 文本）必须 100% 逐字节原样保留。

### 4. 热流读取与成文归档

客户端从 `GET /api/memos?pageSize=100` 开始，沿 `nextPageToken` 读完所有页后按记录编号合并；任一页失败都不发布部分结果。桌面浮窗默认筛选含 `#rewind/`、不含 `#rewind/synthesized` 且 `createTime` 位于最近 72 小时内的条目按时间倒序渲染；`coding-rewind` CLI 与 `coding-rewind mcp` 在保持同一 72 小时活跃默认值的同时，支持显式查询全量历史窗口（`window: "all"`）与 `#rewind/synthesized` 归档片段；当片段已完成成文消费或需要调整状态时，可通过 `PATCH /api/memos/<serverId>?updateMask=content`（`archive_snippet`、`update_snippet_metadata`、`coding-rewind archive`/`update` 或 HUD 归档操作）将状态标签翻转为 `#rewind/synthesized` 退出热流池（或取消归档恢复至 `#rewind/ready` / `#rewind/pending`），全程保留 100% 原文不变；确认永久移除时，仅限用户在桌面浮窗（底部行内确认或按住 `Option` 跳过确认）或终端 `coding-rewind delete <id>` 触发 `DELETE /api/memos/<serverId>`（MCP 绝不暴露物理删除），同时清理本机 `hot_cache.json`、`outbox.jsonl` 与对应本地状态（已同步卡片在未连通 Memos 时拒绝离线删除）。

## 凭据解析与环境隔离优先级

所有运行时配置均遵循环境变量高于本地配置、拒绝硬编码与拒绝暗中回退的原则：

| 配置项 | 解析顺序 | 安全边界 |
| --- | --- | --- |
| 数据目录 | `CODING_REWIND_DATA_DIR` > `~/Library/Application Support/CodingRewind` | 禁止指向 `/tmp` 或 `/private/tmp` |
| Memos 地址 | `CODING_REWIND_MEMOS_URL` > `<dataDir>/config.json` 中 `memos_url` | 与 `ai_access_mode` 共享原子保存且互不覆盖；`config.json` 严禁包含任何令牌字段 |
| AI 接入权限 | `CODING_REWIND_AI_ACCESS`（`read_only` / `read_write`） > `<dataDir>/config.json` 中 `ai_access_mode` > 默认 `read_write` | 非空非法环境变量值按故障关闭降级为 `read_only`；环境变量接管时设置页禁用开关并提示来源；`read_only` 下 `coding-rewind mcp` 拒绝全部 4 个写入工具 |
| Memos 令牌 | `CODING_REWIND_MEMOS_TOKEN` > 非 QA 下 `DeveloperCredentials.plist`（`op read`） > macOS Keychain `com.codingrewind.memos` | `CODING_REWIND_QA=1` 时忽略开发凭据并强制切换至 `com.codingrewind.memos.qa`；`DeveloperCredentials.plist` 存在但无效或 `op` 失败时严禁暗中回退个人钥匙串 |
| 宿主 CLI | Antigravity sidecar 提供的 `PATH` | 仅由 sidecar 调用 `agentapi`，返回会话编号后确认成功 |

快捷键偏好使用库的 UserDefaults 存储，应用不维护第二份快捷键 JSON。普通运行使用 `.standard`；`CODING_REWIND_QA=1` 时在创建任何 Name 前注入按 `CODING_REWIND_DATA_DIR` 派生的独立域，重启稳定。QA 可通过 `CODING_REWIND_SHORTCUTS_SUITE` 指定 `dev.codingrewind.qa.` 前缀的域；非 QA 忽略该变量。构建脚本在 QA 模式使用 `dev.codingrewind.app.qa` bundle ID，签名策略不变。
