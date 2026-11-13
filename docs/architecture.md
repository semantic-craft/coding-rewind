# 统一架构与线级数据契约

本项目采用单一开源事实源加极薄边缘感官架构，以自托管原版 `usememos/memos` 承接全部持久化存储、Webhook 事件与原生 `/mcp` 服务，客户端只保留毫秒级无感选区采集、近 72 小时毛玻璃热流速览以及拉起 **Google Antigravity App 2.x** 对话的极薄界面。

需求依据见 [requirements.md](requirements.md)，开源底座与许可核查见 [sources.md](sources.md)，凭据与数据保护规则见 [privacy.md](privacy.md)。

## 架构设计约束

以下约束直接承接用户一手需求与工程边界：

- **定位与时间窗口**，聚焦未来 1 至 3 天内确定要用到的高质量 AI 对话段落、提示词或思路，默认展示近 72 小时未归档热流卡片，不做全量聊天自动备份。
- **采集零打断**，在当前主线编码或阅读进行中一键暂存选中文本，不弹出协议确认窗，不抢夺原应用输入焦点，不向当前会话插入保存指令，也不强迫填写标题或标签。
- **双端统一汇聚**，同时覆盖独立桌面应用 `com.google.antigravity` 与浏览器中的 ChatGPT、Claude、Gemini，四处采集进入同一个 `Memos` 实例。
- **原文锁死与脉络定锚**，用户选中的原文必须逐字完整保留，不得被摘要替代；前序提问与周围对话轮次作为上下文交由后台增强器提炼结构化抬头，AI 补充信息与原文严格分区展示。
- **回归主力宿主成文**，长对话追问与对照写稿直接交给用户日常使用的 Antigravity App 2.x 及其 `Knowledge Work` 界面完成，通过 `agentapi new-conversation` 与原生 `/mcp` 贯通，不在菜单栏工具内重复维护富文本编辑器或本地双数据库同步逻辑。

## 端到端拓扑

```text
[桌面端 Antigravity App 2.x / macOS 应用]          [网页端 ChatGPT / Claude / Gemini]
  ⌃⌥S 辅助功能取选区或备份剪贴板模拟 ⌘C             Manifest V3 扩展提取选中 Markdown
  + coding-rewind-hook 记录最新提问与前 4 轮         + 提取会话标题、前序提问与最近 4 轮对话
                  │                                                  │
                  └────────────────────────┬─────────────────────────┘
                                           ▼
                    POST /api/memos?memoId=<clientClipId>
                    POST /api/memos/<serverId>/comments
                                           │
                                           ▼
             [单一事实源后端  deploy/vps  阿里云容器栈]
              • neosmemo/memos:26.11.0 原版存储 + 原生 Streamable HTTP /mcp
              • rewind-enricher 验签 Webhook + 5 秒容器内网自愈轮询
              • 等待上下文评论到达后调用兼容接口生成 Title / Session / Context
              • 保留 100% 选中原文并将标签翻转为 #rewind/ready
                                           │
                  ┌────────────────────────┴─────────────────────────┐
                  ▼                                                  ▼
[出口 1  CodingRewindApp 毛玻璃速览浮窗]           [出口 2  Antigravity 2.x 原生插件与 /mcp]
 • ⌃⌥R 非激活 NSPanel 速览 72 小时热流卡片          • memos-mcp-bridge.sh 从钥匙串读取令牌
 • hot_cache.json 与 outbox.jsonl 保障断网可用     • 经 mcp-remote 对接远端原生 /mcp
 • 勾选卡片按 ⌘Return 调 agentapi 开新对话          • /rewind 技能在会话与写作界面检索引用
```

## 四大组成部分职责

### 1. 云端单一事实源与幂等增强器

位于 `deploy/vps/`，由 `docker-compose.yml` 编排两个轻量容器：

- **原版 `neosmemo/memos:26.11.0`**，零源码修改提供 `/api/memos` REST 接口、评论挂载以及进程内原生 `/mcp` 服务，暴露 `memo_list_memos`、`memo_get_memo`、`memo_list_memo_comments`、`memo_create_memo`、`memo_update_memo` 等标准工具。
- **幂等增强器 `deploy/vps/enricher/enricher.py`**，使用 `python:3.12-slim` 纯标准库实现并固定非特权用户运行，零第三方 pip 依赖。由于 `Memos` 内置 Webhook 客户端对私网地址启用 SSRF 拦截，增强器同时提供两条触发通道：
  1. `POST /webhook` 接口按 Standard Webhooks 规范校验 `webhook-id`、`webhook-timestamp` 与 `webhook-signature` 的 HMAC-SHA256 签名，适用于经反代接入实时通知。
  2. 默认每 5 秒从 `http://memos:5230/api/memos?pageSize=50` 开始，沿 `nextPageToken` 枚举完整候选后再逐条增强。页大小不限制候选总数，漏通知或重启后仍为 pending 的记录会在后续扫描中恢复处理。

### 2. macOS 原生菜单栏与毛玻璃浮窗

位于 `Sources/CodingRewindApp/` 与 `Sources/CodingRewindCore/`：

- **零污染选区捕获 `MacOSSelection.swift`**，参照 MIT 项目 `tisfeng/SelectedTextKit` 与 `p0deje/Maccy`，释放捕获快捷键（默认 `⌃⌥S`）时先读取焦点元素的 `kAXSelectedTextAttribute`；仅在为空或受限时先异步等待所有物理修饰键释放（上限 1 秒），再备份当前 `NSPasteboard.general.pasteboardItems` 的全部类型字节与 `changeCount`，投递 `CGEvent` 模拟 `⌘C` 并在 200 毫秒上限内异步检查 `changeCount` 增长，退出时于 `defer` 无条件还原原剪贴板；若 `changeCount` 未变则判定无选区，绝不误存旧剪贴板。当前台应用为 `com.google.antigravity` 时自动合并 `active_turn.json` 上下文，当前台为 Safari、Chrome、Arc 或 Brave 时提取活动标签页标题与链接。
- **非激活毛玻璃浮窗 `QuickPeekHUDViews.swift`**，参照 `p0deje/Maccy` 使用带 `.nonactivatingPanel` 样式的 `NSPanel` 搭配 `.hudWindow` 材质 `NSVisualEffectView`，释放浮窗快捷键（默认 `⌃⌥R`）呼出近 72 小时热流卡片，支持关键词过滤、空格多选、`Esc` 收起以及区分 `待分析` 与 `AI 已定锚` 状态徽标。
- **全局快捷键 `AppShortcuts.swift`**，`ShortcutAction` 定义捕获与浮窗两个动作；`KeyboardShortcuts.Name` 是配置唯一来源，`AppShortcuts` 组织校验、真实注册状态与动作，主菜单、状态菜单及 HUD 提示从同一配置派生。设置直接使用上游 Recorder，实时保存，清空保留禁用值，恢复默认仍走校验。系统快捷键、动作重键和当前主菜单冲突阻止保存；运行时注册失败保留配置，显示原始 OSStatus 并提供重试。仅实际生效的绑定显示菜单 keyEquivalent，录制期间暂停不显示失败。库内既有 Carbon 注册以独占选项申请，其他独占注册的冲突会返回失败；macOS 允许独占注册优先于其他应用的共享注册，无法枚举全部其他应用绑定。菜单跟踪按已接受的 keyDown 配对 keyUp，不受修饰键先释放影响。Carbon 注册与菜单跟踪负责事件，应用不另设监听器。`AppCoordinator` 在异步捕获期间拒绝重入，避免热键、菜单和按钮重复入队。
- **一键创建宿主对话**，勾选卡片按下 `⌘Return`，组装包含脉络抬头、原始选段及出处链接的 Markdown 提示词。桌面端写入私有交接请求，Antigravity 管理的 `coding-rewind/launcher` sidecar 在宿主环境中以参数数组调用 `agentapi new-conversation`。桌面端异步等待会话编号回执，不读取其他进程环境，不使用剪贴板回退。“开聊后归档”由 `AppCoordinator` 唯一持有，HUD、菜单与快捷键共用同一个动作；首次请求保存该意图，恢复请求沿用已保存值。只有确认创建成功后才允许归档。
- **本地离线韧性**，未配置地址或网络异常时，采集请求追加写入 `<dataDir>/outbox.jsonl` 并镜像更新 `<dataDir>/hot_cache.json`，断网时从本地缓存显示热卡，网络恢复后凭 `?memoId=<clientClipId>` 幂等冲刷队列。

刷新请求在网络等待前记录请求编号和本地卡片版本，提交时核对仍为最新、卡片未变化且捕获已结束。过期成功或失败响应都不覆盖当前卡片、缓存或提示。有效提交重读当前 outbox，并把同一合并结果交给 UI 与热缓存。捕获不会等待刷新网络请求；交错时放弃旧刷新，后续刷新再读取远端更新。

### 3. 浏览器 Manifest V3 薄剪藏扩展

位于 `extensions/web-clipper/`，零外部 npm 依赖，首批适配 `https://chatgpt.com/*`、`https://claude.ai/*` 与 `https://gemini.google.com/*`：

- **纯函数提取层 `extractors.mjs`**，参照 MIT 项目 `revivalstack/ai-chat-exporter` 与 `pionxzh/chatgpt-exporter`，把 DOM `Selection` 清洗转换为保留围栏代码块语言标识、行内代码、列表与链接的 Markdown，同时提取清洗后的会话标题、紧邻前序用户提问以及截至当前消息的最近 4 轮问答文本，总长截断在 4000 字符以内。
- **后台直连投递 `background.js` 与 `memos_payload.mjs`**，参照 MIT 项目 `mem0ai/mem0-chrome-extension`，支持右键菜单与 `Alt+Shift+S` 快捷键触发，由后台 Service Worker 直接携带 `Authorization: Bearer <token>` 写入 `Memos` REST 接口；断网或服务端 5xx 时在 `chrome.storage.local` 缓存最多 50 条待发记录并幂等重试，页面右上角以 Shadow DOM 展示 2.2 秒轻提示。只有队列写入成功才反馈已暂存；本地存储拒绝会显示保存失败。

### 4. Antigravity 2.x 官方插件、钩子与钥匙串桥接

位于 `Sources/AntigravityBridge/`、`Sources/CodingRewindCore/AntigravityIntegration.swift` 与 `scripts/memos-mcp-bridge.sh`：

- **非阻塞会话钩子 `coding-rewind-hook`**，挂载 `PostInvocation` 与 `Stop` 事件，解析官方 `lastUserInput`、`conversationId`、`workspacePaths` 与 `transcriptPath`，从 `transcript.jsonl` 提取最近 4 轮 `USER_INPUT` 与 `PLANNER_RESPONSE` 正文后原子写入 `<dataDir>/active_turn.json` 并立即以退出码 0 返回。
- **固定二进制落点与插件布局**，参照 MIT 项目 `wxtsky/CodeIsland`，安装器先将 `coding-rewind-hook`、`coding-rewind-sidecar` 与 `memos-mcp-bridge.sh` 拷入固定路径 `~/Library/Application Support/CodingRewind/bin/`，生成的 hook 命令显式携带安装时解析的数据目录，安装与校验共用同一命令生成器，不依赖宿主继承应用环境；再向 `~/.gemini/config/plugins/coding-rewind/` 写入仅含官方支持字段的 `plugin.json`、扁平处理器数组格式的 `hooks.json` 以及引导调用 `memo_*` 工具的 `skills/rewind/SKILL.md`。
- **零明文令牌 MCP 桥接**，`scripts/memos-mcp-bridge.sh` 运行时从环境变量或 macOS Keychain 读取令牌，执行 `npx -y mcp-remote "${MEMOS_URL%/}/mcp"`，兼容 `~/.config/agent-mcp/servers.json` 与 `mcp-sync`，避免任何 JSON 配置文件落盘明文凭据。

### 接聊请求与回执

`ConversationHandoff.swift` 统一管理 `handoff/` 中的当前请求、独立请求文件和回执。应用先持久化请求编号与选卡信息，再发布正文。sidecar 持有独占进程锁，先记录 `dispatching`，然后调用宿主。成功只认结构化回执中的会话编号，已启动调用但结果不明时记录 `unknown`，不重发。

请求在 30 秒后过期。未发布完整的请求会在过期后收敛为 `expired`，不会补发。成功、拒绝、过期或未知结果都会清理请求正文。已完成回执保留七天，仍被当前请求引用的回执继续保留，避免重启后失去结果。归档进度按卡片编号单独保存，重试不会重新创建会话。

安装器保留宿主配置的其他字段和已有 `projectId`。sidecar 检测到稳定二进制被替换后退出，由宿主的 `always` 重启策略启动新版。它不读取 Memos 令牌。

## Memos REST 共享线级契约

桌面端、浏览器扩展与云端增强器严格共用同一套 REST 契约：

### 1. 创建初始片段

客户端生成满足 `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$` 的幂等标识 `clientClipId`，调用 `POST /api/memos?memoId=<clientClipId>`，请求体 `visibility` 固定为 `PRIVATE`。附带对话上下文时的初始 `content` 模板如下：

```markdown
#rewind/pending #rewind/has-ctx #source/<antigravity|chatgpt|claude|gemini|macos|web>

> **Source:** [<title_or_app>](<url_or_conversation_deeplink>) · <ISO8601_UTC>

<verbatim_selected_markdown>
```

当桌面普通应用划选等场景不含会话上下文时，省略 `#rewind/has-ctx` 标签，仅保留 `#rewind/pending` 与 `#source/macos`。

### 2. 挂载会话上下文评论

若存在会话标题、前序提问或近期轮次，客户端从创建响应 `name` 字段取出 `serverId`，调用 `POST /api/memos/<serverId>/comments?commentId=<clientClipId>-ctx` 写入私密评论：

```markdown
<!-- rewind-context-v1 -->
Session Title: <sessionTitle>
Prompt: <prompt>

### Recent Turns
<up to 4 preceding User/Assistant turns>
```

### 3. 幂等增强与原文保真回写

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

### 4. 热流读取与成文归档

客户端从 `GET /api/memos?pageSize=100` 开始，沿 `nextPageToken` 读完所有页后按记录编号合并；任一页失败都不发布部分结果。随后筛选含 `#rewind/`、不含 `#rewind/synthesized` 且 `createTime` 位于最近 72 小时内的条目按时间倒序渲染；当片段已送入 Antigravity 完成成文消费后，可通过 `PATCH /api/memos/<serverId>?updateMask=content` 将状态标签翻转为 `#rewind/synthesized` 退出热流池。

## 凭据解析与环境隔离优先级

所有运行时配置均遵循环境变量高于本地配置、拒绝硬编码与拒绝暗中回退的原则：

| 配置项 | 解析顺序 | 安全边界 |
| --- | --- | --- |
| 数据目录 | `CODING_REWIND_DATA_DIR` > `~/Library/Application Support/CodingRewind` | 禁止指向 `/tmp` 或 `/private/tmp` |
| Memos 地址 | `CODING_REWIND_MEMOS_URL` > `<dataDir>/config.json` 中 `memos_url` | `config.json` 严禁包含任何令牌字段 |
| Memos 令牌 | `CODING_REWIND_MEMOS_TOKEN` > macOS Keychain `com.codingrewind.memos` | `CODING_REWIND_QA=1` 时强制切换至 `com.codingrewind.memos.qa`，缺失即报错，绝不回退个人钥匙串 |
| 宿主 CLI | Antigravity sidecar 提供的 `PATH` | 仅由 sidecar 调用 `agentapi`，返回会话编号后确认成功 |

快捷键偏好使用库的 UserDefaults 存储，应用不维护第二份快捷键 JSON。普通运行使用 `.standard`；`CODING_REWIND_QA=1` 时在创建任何 Name 前注入按 `CODING_REWIND_DATA_DIR` 派生的独立域，重启稳定。QA 可通过 `CODING_REWIND_SHORTCUTS_SUITE` 指定 `dev.codingrewind.qa.` 前缀的域；非 QA 忽略该变量。构建脚本在 QA 模式使用 `dev.codingrewind.app.qa` bundle ID，签名策略不变。
