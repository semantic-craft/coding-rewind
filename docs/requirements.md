# 需求、MVP 与非目标

本文记录用户需求正本、架构拍板脉络、MVP 范围与非目标边界。具体技术契约见 [architecture.md](architecture.md)，可执行验收见 [milestones.md](milestones.md)，来源与开源协议核查见 [sources.md](sources.md)。

文档使用四类标记区分事实层级，避免把推演建议混写为用户决定：

- **决定**，用户已明确说出或拍板确认的要求。
- **方向**，早期讨论形成的转述摘要，非逐字引用。
- **建议**，整理方案时提出的工程做法，可按需调整。
- **待决**，留待用户后续单独拍板的事项。

## 需求正本与用户一手原话

### 1. 立项正本 2026-11-10

- **标记**，决定
- **日期**，2026-11-10
- **出处**，用户 t4624u 立项正本

> 待开发工具构想：针对与 AI 聊天过程中好用的高质量对话片段、提示词或思路，开发一个支持收集、归档与便捷回顾的功能/工具，把好用的片段系统存起来复用。

### 2. 用户一手直述补充 2026-11-10

- **标记**，决定
- **日期**，2026-11-10
- **出处**，用户在本仓库会话中的三轮直接口述原话，保留口语原貌不改写

关于核心痛点、1 至 3 天近期暂存时间尺度、桌面与网页双来源场景以及服务于写作思考：

> 我们这个项目实际上要解决这么一个问题，比如说我们在用Coding Agent的时候呢，经常会遇到一些片段，这些片段下意识地会觉得以后有用。 一两天内马上会用到，但是暂时又不想为这个去存到notes里面，其实一种方法是存到备忘录，但感觉总不太好。 所以我脑袋中总设想说有没有可能这个东西是我马上可能两三天后马上要用的。 这个Notes都保留进去。简单来讲就是我有一些片段我以后是用得上的。我希望我能够有这些东西能够回顾。有些时候呢，大多数时候 有些时候可能又是在单独的app里面，比如说网页版的聊天记录啊。 两种情况，一种是在Coding Agent的桌面版，一种是在网页版。他们都有对话，偶尔有一些片段会给我带来一些灵感，我会想要保留它们，然后偶尔还想要互动 每个目的就是说最后写东西的时候思考的时候要用得上。

关于当下不开新对话的捕获心理、A 与 C 两种消费场景以及围绕 Antigravity 和网页版设计：

> 主要就是很多东西我觉得对我来讲，比如这个东西非常好，接下来马上就要用了，但是我又不想马上开个新对话，差不多是这么一个东西。比如说它有些段落 然后某些段落呢，我觉得挺好的，接下来想用但一直又不知道放哪，但我很确定要用，所以我就是想要存起来，就是这么一个东西。 你要说场景的话更多的还是A跟C都有吧，然后这种片段我用的最多的是Antigravity。 所以你要围绕antigravity还有专门版的专门来做设计。

上文中的 A 指选中暂存片段继续跟 AI 追问推演，C 指一边对照暂存片段一边撰写自己的草稿思考并由 AI 辅助整理。

关于桌面端 Antigravity 的具体产品形态边界：

> 我觉得没问题，不过我们的antigravity是这种 https://antigravity.google/download Antigravity App v2.3.1 你也可以github上搜 一下 和ide版本不一样

经核对官网下载页与本机 `/Applications/Antigravity.app/Contents/Info.plist`，目标宿主为独立桌面应用 **Google Antigravity App 2.x**，`CFBundleIdentifier` 为 `com.google.antigravity`，无 IDE 外壳且不支持 VS Code `.vsix` 扩展，通过原生 `plugin.json`、`hooks.json`、`mcp_config.json`、`skills/` 及 `agentapi` CLI 集成，核查细节见 [sources.md](sources.md)。

### 3. 用户关于成熟开源底座、非胶水架构与原生浮窗的拍板 2026-11-11

- **标记**，决定
- **日期**，2026-11-11
- **出处**，用户在本仓库会话中的直接输入原话，保留原貌不改写

关于站在高星成熟开源项目基础上构建、理清逻辑主线与拒绝胶水代码：

> 还是倾向于就是先把最像的一些项目拿过来看一眼，然后在已有的项目的基础上去做。这有个什么好处呢？就是你会有那种尤其是新兴数高的那种项目。 你看看有没有最接近的项目，但我们这个设想我觉得没问题啊，但是你要找到一个接近的项目或者一个或者几个，然后把他们串一串。 你先要跟我复述一下，一般来讲好的代码、优美的代码应该是什么样的。在这种情况下，这个逻辑主线你要zoom in来看吗? 要怎么样就是不能是胶水代码拼在一起。

关于采用开源许可与 macOS 原生界面：

> 我是愿意开源的，就走路线1。再来我们能不能用原生UI呢

关于在明确 WebView 与原生差异后确认纯正 macOS 原生路线：

> 我觉得走路线1

关于确认 MIT 许可、首批三大网页聊天站点并推进原型选型：

> 没问题，先更新进docs 然后出三套界面原型

关于选定轻量非激活 HUD 速览浮窗作为桌面交互入口：

> 那就选方案2

### 4. ChatGPT 与 Gemini 桌面剪藏 2026-11-14

> ChatGPT 和 Gemini App 都补齐并对齐，全自动做到快捷键剪藏入库的实机验收通过，常规技术判断你自己定。

选区剪藏自动附带来源、私有会话链接、前序提问和截止所选消息的最多四个用户轮。验收覆盖真实快捷键、服务端原文与评论回读、会话切换、剪贴板恢复及离线重放。

## 已拍板决定汇总

| 事项 | 标记 | 日期 | 内容 |
| --- | --- | --- | --- |
| 项目名称 | 决定 | 2026-11-10 | 现用名为 `Coding-Rewind`，后续更换备选名前以此为准 |
| 项目性质 | 决定 | 2026-11-10 | 属于个人灵感片段暂存与成文辅助工具，不是流程或项目管理工具 |
| 自动暂存与相关时提示 | 决定 | 2026-11-10 | 两者仅作远期候选，不纳入现行版本范围 |
| 时间窗口与定位 | 决定 | 2026-11-10 | 聚焦近 1 至 3 天即刻要用的对话段落，捕获时不打断当前主线会话 |
| 目标来源 | 决定 | 2026-11-14 | Antigravity、ChatGPT、Gemini 桌面端与 ChatGPT、Claude、Gemini 网页端 |
| 开源协议 | 决定 | 2026-11-11 | 全仓采用 MIT License 公开维护，严禁混入 GPL、AGPL、Commons Clause 或无许可源码 |
| 统一后端与反胶水收敛 | 决定 | 2026-11-11 | 以阿里云轻量服务器自托管原版 `usememos/memos` 为唯一事实源，配合轻量幂等 AI 语境增强器与原生 `/mcp`，砍掉冗余本地 SQLite 业务库、重复自建编辑器与手写 MCP 服务 |
| 极薄客户端与宿主协同 | 决定 | 2026-11-11 | macOS 端保持约三百五十行非激活毛玻璃菜单栏 HUD，网页端采用直连 Memos REST API 的 MV3 薄扩展，勾选卡片后经 `agentapi new-conversation` 与 `/rewind` 交回 Antigravity 完成场景 A 追问与场景 C 写稿 |
| 单二进制 CLI 与领域 MCP 收敛 | 决定 | 2026-11-15 | 淘汰远端 41 个通用 Memos MCP 工具与 `memos-mcp-bridge.sh`，提供共用 `CodingRewindCore` 的单二进制 `coding-rewind`（CLI + 内嵌领域 `mcp` 子命令），支持按参数读取超过 72 小时或已标记 `#rewind/synthesized` 的历史片段，并替换 `servers.json` 接线 |
| 向 AI 开放的三层写入与闭环入口 | 决定 | 2026-11-16 | 将 `coding-rewind mcp` 由 4 个领域工具扩展至 7 个（新增 `create_snippet`、`update_snippet_metadata`、`append_snippet_note`，绝不向 MCP 暴露物理删除），CLI 同步补齐 `create`、`update`、`note` 子命令；在“设置 → 插件与权限”新增“AI 接入与权限”分区（本地 MCP 状态、只读与读写权限开关、一键复制零明文 MCP JSON 配置）；`⌘Return` 接聊提示词携带卡片 ID 并在读写开启时引导宿主 AI 回写笔记或暂存新提纲 |
| 来源开头留底、浮窗脉络抽屉与分平台回溯 | 决定 | 2026-11-16 | 不采用高权限打扰且不可检索的截图留底；AI 对话额外留存会话 ID 与首轮开场白（`Session Opening`，前 300 字），普通网页提取 `h1`、导语及正文开头数行（`Page Lead`）喂给 `enricher.py` 并生成 W3C `#:~:text=` 精确到句子的高亮回跳链接；浮窗内增设停靠式“脉络”预览抽屉（原地看完整原文、开头留底、提问与笔记），并以 `SourceLocator` 区分网页打开与 Antigravity 会话 ID 复制 |
| 浮窗可编辑接聊草稿框与直连 DeepSeek 官方 V4.1 Flash | 决定 | 2026-11-17 | 勾选卡片按 `⌘Return`（或点击“开始对话”）不再直接发往宿主 Agent，而是先在浮窗内展开可编辑多行接聊草稿框（`Esc` 返回列表），主操作默认一键复制修改后的提示词并唤醒所选宿主手动粘贴发送，次按钮保留“直接新建对话”；云端 `rewind-enricher` 停用 DashScope 中转，改为直连 DeepSeek 官方 API（`https://api.deepseek.com`，模型 `deepseek-flash` 即 `DeepSeek-V4.1-Flash`，非思考 JSON 模式） |
| 以 DSH 替换 Codex 接聊并补齐 DSH 桌面端双向协同 | 决定 | 2026-11-19 | 彻底移除 Codex 接聊通道并改由 **DSH**（DeepSeek Harness，`com.deepseek.dsh`）承接：通过随包分发的零依赖 DSH Desktop 插件消费 `dsh-handoff/`，打开当前或最近工作区空白新会话并以 `whenDraftExists: 'append'` 追加预填草稿不自动发送；浮窗选中 DSH 时主按钮（`⌘Return`）为「填入 DSH 新会话」、次按钮为「复制并唤醒 DSH」、勾选框为「填入后归档」（Antigravity 保持原主次顺序不变，默认目标仍为 Antigravity，旧配置 `"codex"` 启动自动迁移为 `"dsh"`）；保留 ChatGPT 桌面端（`com.openai.codex`）划词捕获不动，同时为 DSH 桌面端补齐选区下方闭合 Shadow DOM 暂存胶囊、上下文捕获（`#source/dsh`）及原会话直达回跳（未就绪时回退复制会话 ID），设置页并列管理 Antigravity 与 DSH 插件 |

## 已记录的产品方向

- **标记**，方向
- **日期**，2026-11-09 讨论整理，2026-11-11 架构收敛校准

1. **选段一键留存**，由用户主观选中值得复用的段落后触发保存，不做后台全量聊天录制。
2. **零前置命名负担**，保存瞬间不弹必填标题或标签输入框，语境抬头由后台增强器异步生成。
3. **原文、原问题与出处齐备**，完整保留选中原文、前序提问、周围 4 轮对话脉络与可回跳的会话或网页链接；缺失项如实省略或标明，绝不伪造原问题。

   上下文中的一轮指一次用户提问及其后的助手消息。最多保留所选消息所在轮及前三轮，截止所选消息。选中用户消息时不把它自身或更早的提问冒充前序提问。显示预算可截短附带的对话，并标明省略；保存的选区原文不受该预算影响。

4. **自然语言检索与复用**，回顾时支持按日常表述筛选或经 Memos `/mcp` 工具检索卡片并直接投入写作推演。

## MVP 能力范围

- **标记**，决定与落地切分

MVP 闭环围绕四步主链路构建：

1. **桌面与网页双端无感暂存**，在 Antigravity、ChatGPT 与 Gemini 桌面端划选对话正文弹出非激活“暂存”胶囊，或在任意 macOS 应用中按 `⌃⌥⇧⌘S`（`Hyper+S`）捕获选区并关联当前会话提问与近 4 轮记录；在 ChatGPT、Claude、Gemini 网页中通过选区上方“暂存”胶囊、右键菜单、`⌃⌥⇧⌘S`（`Hyper+S`）或 `Alt+Shift+S` 提取选区 Markdown 与近 4 轮对话直连写入 `Memos`，全程不抢焦点、不弹自定义协议确认框。
2. **异步幂等 AI 脉络定锚**，VPS 端 `rewind-enricher` 读取片段及上下文评论，生成精炼标题、原会话主题、上下文摘要与关键词引用头，100% 保留用户选中原文一字不改。
3. **72 小时毛玻璃热流速览与离线兜底**，按 `⌃⌥R` 呼出非激活毛玻璃面板查看近 72 小时热流卡片，断网时依赖 `hot_cache.json` 与 `outbox.jsonl` 实现毫秒级打开和后续幂等重放。
4. **无缝接入主力宿主开展 A 与 C 并闭环回写**，在 HUD 多选卡片按 `⌘Return` 先在浮窗内展开带卡片 ID 与完整上下文的可编辑接聊草稿框（Antigravity 默认一键复制并唤醒粘贴发送、可选直接新建对话；DSH 默认一键追加预填进当前/最近工作区空白新会话不自动发送、次按钮保留复制并唤醒），或通过 `coding-rewind`（8 个 CLI 子命令与受只读/读写权限控制的 `coding-rewind mcp` 七个领域工具）检索引用片段、追加 AI 笔记、更新元数据或暂存新提纲草稿，让推演结论流回浮窗（物理删除仅保留给桌面端与终端人工操作，绝不向 MCP 暴露）。
5. **数据自主可控**，依托自托管 `usememos/memos` 支持随时查看、导出、归档和彻底删除单条或全部记录。

## 当前非目标

当前版本明确不做以下事项：

- 默认后台全量自动采集全部聊天记录。
- 在用户未主动唤起时弹出相关性推荐打扰心流。
- 在客户端重复造富文本草稿编辑器或维护双数据库双向同步胶水代码。
- 通过自定义 URL 协议从浏览器唤醒桌面端中转剪藏数据。
- 在仓库、配置文件或测试夹具中写入真实私密聊天、明文访问令牌或私人服务器 IP。
- 复制任何 GPL、AGPL、Commons Clause、闭源商业扩展或无许可仓库的代码。

## 待决事项

以下事项留待后续按实际使用体感单独决定：

1. **超过 72 小时未消费卡片的提醒策略**，当前超过热窗口的片段继续安全保留在自托管 `Memos` 库中随时可搜，是否增加每周回顾摘要待用户后续决定。
2. **候选实验特性**，未来是否单独立项评估可选自动暂存或相关片段温和提示。
3. **正式产品定名**，是否继续沿用 `Coding-Rewind` 或启用新名称。

## 2026-11-14 网页扩展界面

用户在当前聊天选择布局：

> 单页偏好（推荐）：设置集中，少一次切换

已拍板：扩展设置使用单页分区，集中展示 Memos 连接、保存偏好和同步操作。设置页、页面内保存按钮与保存提示沿用桌面端明亮底色和蓝色强调。现有保存、权限、同步与原文提取行为保持不变。

## 2026-11-14 划词暂存胶囊与默认快捷键收敛

用户在当前聊天确认动作范围与快捷键：

> 我觉得就只需要暂存。 然后快捷键用hyper+S

已拍板：在 Gemini 网页端（及扩展支持的网页对话）、Gemini 桌面端与 Antigravity 桌面端统一提供 PopClip 风格的单动作非激活“暂存”悬浮胶囊，桌面端在设置通用页提供“选中文本时显示暂存胶囊”开关；默认捕获快捷键迁移为 `⌃⌥⇧⌘S`（`Hyper+S`），未自定义的旧版 `⌃⌥S` 配置自动一次性升级，用户显式自定义或清空的快捷键保持不变。

## 2026-11-15 单二进制 CLI 与领域 MCP 收敛

用户在当前聊天确认 Agent 接口收敛与历史片段查询边界：

> 1 .淘汰远端 41 个通用 Memos 工具。2. 允许 Agent 传入参数读取超过 72 小时或已标记 #rewind/synthesized 的历史片段。 3. 倾向于一步到位做出同二进制的 coding-rewind（同时包含 CLI 与 mcp 子命令并替换 servers.json 中的 memos-mcp-bridge.sh）

已拍板：退役 `scripts/memos-mcp-bridge.sh`、`npx mcp-remote` 及远端 41 个通用 Memos MCP 工具，由共用 `CodingRewindCore` 的原生单二进制 `coding-rewind`（固定安装路径 `~/Library/Application Support/CodingRewind/bin/coding-rewind`）同时提供 CLI（`list`、`search`、`get`、`archive`，后于 PR #36 补入人工与终端专用的 `delete`）与内嵌 `coding-rewind mcp` stdio 服务（首批暴露 `list_snippets`、`search_snippets`、`get_snippet`、`archive_snippet` 四个领域工具），默认聚焦近 72 小时活跃片段，同时支持按参数查询超过 72 小时或已标记 `#rewind/synthesized` 的历史片段，并在断网时回退读取本机 `hot_cache.json` 与 `outbox.jsonl`。

## 2026-11-16 向 AI 开放的三层写入与闭环入口

用户在当前会话拍板确认向 AI 开放受控写入能力与推演回流闭环：

- **标记**，决定
- **日期**，2026-11-16

已拍板按协议层、应用可见层与工作流闭环三层落地：

1. **协议层（MCP 与 CLI 领域写入扩展）**，将 `coding-rewind mcp` 由 4 个领域工具扩展为 7 个领域工具，在保留 `list_snippets`、`search_snippets`、`get_snippet`、`archive_snippet` 的基础上新增 `create_snippet`（AI 直接暂存提纲、草稿或归纳结果，默认标记 `#source/agent`）、`update_snippet_metadata`（仅更新标题、会话主题、上下文摘要、关键词、自定义标签以及归档/取消归档状态，100% 逐字节保留选中原文不改动）与 `append_snippet_note`（通过首行带 `<!-- rewind-note-v1 -->` 的 Memos 私密评论追加 AI 笔记，与采集上下文评论 `<!-- rewind-context-v1 -->` 严格隔离，纯本机模式下存于 `<dataDir>/local_notes.json` 并由 `get_snippet` 解析返回 `notes`）。CLI 同步新增 `create`、`update`、`note` 子命令，形成 `list`、`search`、`get`、`create`、`update`、`note`、`archive`、`delete` 八个子命令。物理删除 `delete` 严格限定为桌面 HUD 与终端 CLI 的人工操作，绝不通过 MCP 向 AI 暴露。
2. **应用可见层（AI 接入与权限面板）**，在桌面端“设置 → 插件与权限”下新增“AI 接入与权限”（`AI Access & Permissions`）分区，直观展示本机 MCP 服务就绪状态、只读与读写权限切换开关（持久化于 `<dataDir>/config.json` 的 `ai_access_mode` 字段，取值为 `"read_only"` 或 `"read_write"`，默认 `"read_write"`，绝不存储任何访问令牌；支持通过环境变量 `CODING_REWIND_AI_ACCESS=read_only|read_write` 覆盖并在界面禁用开关及标明环境管理来源，只读模式下 `coding-rewind mcp` 拒绝全部 4 个写入类工具 `create_snippet`、`update_snippet_metadata`、`append_snippet_note` 与 `archive_snippet`），以及面向 Claude Desktop、Cursor、Codex、Antigravity 等宿主的一键复制零明文 MCP JSON 配置按钮。
3. **工作流闭环（接聊携带卡片 ID 与结论回流）**，浮窗勾选卡片按下 `⌘Return` 生成的宿主接聊提示词为每张卡片附带标识（中文 `- 卡片 ID`、英文 `- Clip ID`），并在开启 AI 读写权限时于末尾提示宿主 AI 可在推演成文后调用 `append_snippet_note` 将结论挂回原卡片，或调用 `create_snippet` 将新整理的提纲草稿暂存回 Coding Rewind，使对话产出直接流回 HUD 热流池（只读模式下省略该回写引导）。

## 2026-11-17 浮窗可编辑接聊草稿框与云端 DeepSeek V4.1 Flash 切换

用户在当前会话明确接聊发送前调整环节与云端摘要模型切换要求：

> 1 .接聊交互方式：你更倾向于 方案 A（浮窗内先弹出可编辑草稿框，默认一键复制并唤醒 Antigravity 去粘贴发送，可选保留直接建会话按钮），
> 2. 云端的AI用的是qwen的 dashscope key，那么模型你要看一下deepseek最新的官方文档，给我改成用deepseek官方最新的 4.1 flash

已拍板：

1. **接聊发送前草稿框（方案 A）**，浮窗勾选片段后按 `⌘Return` 或点击“开始对话”不再直接触发宿主 Agent 创建会话，而是先在浮窗内展开可编辑多行接聊草稿框（按 `Esc` 或点击“返回列表”退回卡片列表，未发送的手工修改在同一选集下保留，可随时“恢复默认”）；主操作（`⌘Return` / “复制并唤醒 Antigravity”或“复制并唤醒 Codex”）将调整后的文本写入剪贴板并激活目标宿主供手动粘贴发送，同时保留“直接新建对话”次要按钮按编辑后文本创建新会话。
2. **云端摘要切换为直连 DeepSeek 官方 V4.1 Flash**，用户进一步明确直连 DeepSeek 官方接口而非继续走 DashScope：将 `deploy/vps/` 默认配置与云端实例统一切换为 `AI_BASE_URL=https://api.deepseek.com` 与 `AI_MODEL=deepseek-flash`（对应 `DeepSeek-V4.1-Flash`，自动注入 `{"thinking": {"type": "disabled"}}` 配合 `json_object` 非流式结构化输出）。

## 2026-11-19 以 DSH 替换 Codex 接聊并补齐 DSH 桌面端双向协同

用户提出将接聊宿主由 Codex 全面替换为 DSH（DeepSeek Harness），并经 `/grill-me` 逐分支拍板全部细节：

> 本项目已经不需要插入对话到codex中了，而是要将codex改成dsh。

已拍板：

1. **全面退役 Codex 接聊通道**：移除 `CodexConversationClient`、`CodexAppIntegration`、`codex-handoff/` 与相关菜单/测试夹具；界面统一简称 **DSH**（设置页副标题注明 DeepSeek Harness）；首次默认目标保持 Antigravity，旧配置 `conversation-host.json` 中的 `"codex"` 在启动时自动平滑迁移为 `"dsh"`。
2. **DSH 空白会话预填与草稿框主次**：通过零依赖 DSH Desktop 插件消费 `dsh-handoff/`，打开 DSH 当前或最近工作区（无可用工作区时回退默认工作区）的空白会话并以 `whenDraftExists: 'append'` 追加预填草稿而不自动发送；选中 DSH 时浮窗主按钮（`⌘Return`）为「填入 DSH 新会话」、次按钮保留「复制并唤醒 DSH」、勾选框显示为「填入后归档」并在确认预填成功后归档；Antigravity 维持原有主次不变。
3. **DSH 桌面端划词暂存与原会话回跳**：保留既有 ChatGPT 桌面端（`com.openai.codex`）划词捕获不动，同时由 DSH 插件在聊天正文选区下方渲染闭合 Shadow DOM「暂存」胶囊并同步活跃会话脉络（`#source/dsh`、`dsh-session://<sessionId>`）；点击 `#source/dsh` 来源按钮经插件直接切回原会话并唤醒 DSH，未就绪时诚实回退复制会话 ID。设置页「插件与权限」并列管理 Antigravity 与 DSH 插件。
