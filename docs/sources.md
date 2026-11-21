# 来源核查与开源复用边界

本文记录项目立项与统一架构设计期间实际核查的开源仓库、商业对照页面及规范文本。所有代码级参考与裁剪均严格限定在标准 `MIT` 许可项目内并保留原作者版权声明；凡属 `GPL`、`AGPL`、`Commons Clause`、无许可或闭源商业产品，一律保持零代码复用。

无许可仓库的处理依据见 [Choose a License No Permission](https://choosealicense.com/no-permission/)。

## 直接复用或裁剪模式的 MIT 上游项目

以下十五个项目均已核实仓库根目录 `LICENSE` 全文与 GitHub API `license.spdx_id` 为标准 `MIT`，构成本仓库四端实现的技术底座：

| 项目 | 仓库与许可证据 | 在本项目中的具体复用与适配 |
| --- | --- | --- |
| `usememos/memos` | [usememos/memos](https://github.com/usememos/memos)，`MIT License` | 零修改直接采用官方固定版本 `neosmemo/memos:26.11.0` 容器作为唯一后端事实源，使用其 `/api/memos`、评论接口与 `internal/webhook/webhook.go` 的 Standard Webhooks HMAC-SHA256 签名约定 |
| `p0deje/Maccy` | [p0deje/Maccy](https://github.com/p0deje/Maccy)，`MIT License`，Copyright Alex Rodionov | 在 `CodingRewindApp` 适配其 `FloatingPanel` 的 `.nonactivatingPanel` 非激活浮窗标志位、`.hudWindow` 毛玻璃视觉材质、键盘多选列表手感与剪贴板快照保护思路 |
| `GaimsDevSoftware/linuxpop` | [GaimsDevSoftware/linuxpop](https://github.com/GaimsDevSoftware/linuxpop)，`MIT License`（2026-11-14 Asia/Shanghai 读取 `README.md` 与 `LICENSE`） | 在 `SelectionPopupController.swift` 借鉴其 PopClip 风格划词探测与执行两阶段分离思路，第一阶段仅在满足拖拽或双击手势阈值后以纯只读方式判定选区并展示非激活胶囊，第二阶段仅在用户点击胶囊或按下快捷键时执行实际捕获 |
| `sindresorhus/KeyboardShortcuts` | [3.1.0 上游源码](https://github.com/sindresorhus/KeyboardShortcuts/tree/772133d9dbe800fdac0473226822994c5c162c58)，`MIT License`，Copyright Sindre Sorhus | `Vendor/KeyboardShortcuts/` 保留源码、测试、本地化资源、manifest 与原许可，提供 Recorder、Hyper、配置持久化、Carbon 注册与菜单跟踪。本地补丁提供真实注册状态、失败重试、可注入偏好域和复用菜单冲突查询；版本与补丁边界见该目录 README |
| `tisfeng/SelectedTextKit` | [tisfeng/SelectedTextKit](https://github.com/tisfeng/SelectedTextKit)，`MIT License`，Copyright Tao Shi | 在 `MacOSSelection.swift` 采用其选区获取双阶段策略，先读焦点元素 `kAXSelectedTextAttribute`，为空时完整备份 `NSPasteboardItem` 全部类型数据与 `changeCount`，投递 `CGEvent` 模拟 `⌘C` 校验计数递增后在 `defer` 无条件还原剪贴板 |
| `wxtsky/CodeIsland` | [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland)，`MIT License`，Copyright wxtsky | 在 `AntigravityIntegration.swift` 借鉴将 `coding-rewind-sidecar` 与 `coding-rewind` 固定拷入 `~/Library/Application Support/CodingRewind/bin/` 避免 `.build/` 断链的安装模式。早期借鉴的 Hook 快照管线已由按选区读取官方 transcript 替代 |
| `mem0ai/mem0-chrome-extension` | [mem0ai/mem0-chrome-extension](https://github.com/mem0ai/mem0-chrome-extension)，`MIT License` | 在 `extensions/web-clipper/` 适配其 Manifest V3 划选捕获、右键菜单加快捷键触发、后台 Service Worker 直连远端 REST 接口以及右上角 2.2 秒轻量非抢焦点提示条交互，彻底替代自定义 URL 协议唤醒 |
| `revivalstack/ai-chat-exporter` | [revivalstack/ai-chat-exporter](https://github.com/revivalstack/ai-chat-exporter)，`MIT License` | 在 `extensions/web-clipper/extractors.mjs` 参考其跨 AI 聊天站点的消息轮次角色识别、会话标题清洗及代码块与列表 HTML 转 Markdown 规则 |
| `pionxzh/chatgpt-exporter` | [pionxzh/chatgpt-exporter](https://github.com/pionxzh/chatgpt-exporter)，`MIT License` | 在 `extensions/web-clipper/extractors.mjs` 参考其针对聊天 DOM 选区与围栏代码块语言类名的稳健清洗转换策略，提取选中内容与前序 4 轮问答脉络 |
| `obsidianmd/obsidian-clipper` | [obsidianmd/obsidian-clipper](https://github.com/obsidianmd/obsidian-clipper)，`MIT License`，Copyright (c) 2024 Obsidian，commit `6d56d618b00b` | 在 `extensions/web-clipper/content.js` 适配其内容脚本重注入生命周期清理（`__CODING_REWIND_HOOK__.dispose()`），统一卸载旧 Shadow DOM 宿主、页面事件与 `chrome.runtime` 监听，防止扩展更新或重注入后残留僵尸监听器 |
| `crimx/ext-saladict` | [crimx/ext-saladict](https://github.com/crimx/ext-saladict)，`MIT License`，Copyright (c) 2018 Crimx，commit `1673df156908` | 在 `extensions/web-clipper/content.js` 与 `options.js` 适配其划词手势门控（主按键拖拽距离、双击、Shift 扩展选区与键盘 `Shift+Arrow` 防抖）、可编辑控件与在线代码编辑器避让（放行只读框与 `aria-readonly="true"`）以及排除域名匹配 |
| `floating-ui/floating-ui` | [floating-ui/floating-ui](https://github.com/floating-ui/floating-ui)，`MIT License`，Copyright (c) 2021 Floating UI contributors，commit `c3042f1f37d9` | 在 `extensions/web-clipper/content.js` 适配其基于 `Range.getClientRects()` 的多矩形选区锚定策略，单行居中悬浮于选区上方，多行按正向尾行或反向首行就近定位并在视口边缘翻转夹紧 |
| `kepano/defuddle` | [kepano/defuddle](https://github.com/kepano/defuddle)，`MIT License`，Copyright (c) 2025 Steph Ango，commit `3e8bde9f5f85` | 在 `extensions/web-clipper/extractors.mjs` 适配其语法高亮器行号列剥离、GitHub `table.highlight` 与 Rouge 代码表格还原、Shiki / Expressive Code 逐行换行保留以及网页 `og:site_name` 标题后缀清洗与 `og:title` 回退规则 |
| `mixmark-io/turndown` | [mixmark-io/turndown](https://github.com/mixmark-io/turndown)，`MIT License`，Copyright (c) 2017 Dom Christie，commit `b86e2b18539f` | 在 `extensions/web-clipper/extractors.mjs` 适配其富文本行内与块级 HTML 转 Markdown 规则，覆盖图片相对链接解析、GFM 任务列表复选框、`<mark>`、`<kbd>` 与 `<details>/<summary>` |
| `ChatGPTBox-dev/chatGPTBox` | [ChatGPTBox-dev/chatGPTBox](https://github.com/ChatGPTBox-dev/chatGPTBox)，`MIT License`，commit `f0717a154e75` | 在 `extensions/web-clipper/` 参考其全网 `http(s)` 内容脚本挂载、Shadow DOM 样式隔离以及生效范围切换（全部网页 / 仅 AI 聊天网站 / 关闭）与排除域名设置模型 |

## 因协议不兼容或缺失许可而严格排除代码复用的项目

本项目采用 `MIT` 开源协议发布，以下仓库虽在功能调研中查阅对照，但因强传染性 Copyleft 协议、附加商业限制或缺失开源许可，严格执行零代码复制与零衍生引用：

| 项目 | 链接与核实许可 | 排除代码复用的原因 |
| --- | --- | --- |
| `codexu/note-gen` | [codexu/note-gen](https://github.com/codexu/note-gen)，`GPL-3.0` | 协议为强传染性 `GPL-3.0` 与本项目 `MIT` 不兼容，且工程为 Tauri 加 Next.js WebView 重栈；本项目仅吸收其先轻量记录碎片后勾选成文的产品分阶段理念，零代码复用 |
| `karakeep-app/karakeep` | [karakeep-app/karakeep](https://github.com/karakeep-app/karakeep)，`GPL-3.0` | 原名 Hoarder，支持书签剪藏与服务端 AI 自动摘要打标，但采用 `GPL-3.0` 协议且依赖多容器重型架构；本项目改用 `MIT` 协议的 `usememos/memos` 搭配自写百行标准库 `enricher.py`，零代码复用 |
| `abraxas914/VESTI` | [abraxas914/VESTI](https://github.com/abraxas914/VESTI)，无标准开源许可 | 面向网页 AI 聊天剪藏整理，但仓库缺失兼容 `MIT` 的标准开源授权文件；按无许可默认保留全部权利原则排除一切代码参考与复用 |
| `tisfeng/Easydict` | [tisfeng/Easydict](https://github.com/tisfeng/Easydict)，`GPL-3.0` | 应用本体为 `GPL-3.0`，不引用其任何源码；选区能力仅参考同一作者独立以 `MIT` 发布的组件库 `tisfeng/SelectedTextKit` |
| `anavvathi/Bridgecontext` | [anavvathi/Bridgecontext](https://github.com/anavvathi/Bridgecontext)，`GPL-3.0` | `GPL-3.0` 跨平台上下文捕获扩展，因 Copyleft 传染性严格排除代码复用 |
| `TenCent46/hypratia` | [TenCent46/hypratia](https://github.com/TenCent46/hypratia)，`AGPL-3.0` | `AGPL-3.0` 卡片对话画布应用，因协议限制严格排除代码复用 |
| `Veverke/bAInder` | [Veverke/bAInder](https://github.com/Veverke/bAInder)，`MIT with Commons Clause` | 附加 Commons Clause v1.0 禁止商业出售，不属于标准宽松开源协议，不并入或复制任何源码 |
| `Solveneers/ai-chat-navigator-pro` | [Solveneers/ai-chat-navigator-pro](https://github.com/Solveneers/ai-chat-navigator-pro)，无 `LICENSE` | 仓库无扩展实现源码且无许可文件，不当作开源软件 |
| `ericmjl/canvas-chat` | [ericmjl/canvas-chat](https://github.com/ericmjl/canvas-chat)，无 `LICENSE` | 仓库未提供开源许可文件，仅记录公开 README 中的多选分支交互概念，零代码复用 |
| `lee-jet/chat-highlight` | [lee-jet/chat-highlight](https://github.com/lee-jet/chat-highlight)，闭源 | 仓库仅作问题反馈页，扩展本体闭源 |
| `nextai-translator/nextai-translator` | [nextai-translator/nextai-translator](https://github.com/nextai-translator/nextai-translator)，`AGPL-3.0` | 全网划词浮标扩展采用强传染性 `AGPL-3.0` 协议，严格排除代码阅读与复用 |
| `webclipper/web-clipper` | [webclipper/web-clipper](https://github.com/webclipper/web-clipper)，`NOASSERTION` | GitHub 许可识别为 `NOASSERTION`，授权边界不符合标准 `MIT` 要求，严格排除代码复用 |
| `hcfyapp/crx-selection-translate` | [hcfyapp/crx-selection-translate](https://github.com/hcfyapp/crx-selection-translate)，无 `LICENSE` | 划词翻译扩展缺失开源许可文件，按默认保留全部权利原则排除一切代码参考与复用 |
| `deathau/markdownload` | [deathau/markdownload](https://github.com/deathau/markdownload)，`Apache-2.0` | 网页转 Markdown 扩展采用 `Apache-2.0` 协议；本项目代码级裁剪限定在标准 `MIT` 上游（`kepano/defuddle` 与 `mixmark-io/turndown`），保持零代码复用 |
| `modelcontextprotocol/swift-sdk` | [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)，`Apache-2.0` | 官方 Swift MCP SDK 已由早期宽松许可转为 `Apache-2.0`；为保持全仓纯 `MIT` 零协议混用与零第三方外部包依赖，严格排除引入或复制其源码，改由 `CodingRewindCLI` 基于 `Foundation` 自研 JSON-RPC 2.0 `stdio` 服务端 |

## 目标宿主与早期机制对照来源

以下来源用于明确目标宿主扩展契约与早期产品交互对照，不涉及第三方源码并入：

### 1. Google Antigravity App 2.x 官方文档与本机包信息

- **核查链接**，[下载页](https://antigravity.google/download)、[2.0 发布说明](https://antigravity.google/blog/introducing-google-antigravity-2)、[构建插件指南](https://antigravity.google/docs/build-plugins/)、[自定义发现路径](https://antigravity.google/docs/customization-discovery/)、[更新日志](https://antigravity.google/docs/changelog/)。
- **宿主事实**，Google Antigravity 2.x 是独立 Electron 桌面应用，`CFBundleIdentifier` 为 `com.google.antigravity`，不支持 VS Code `.vsix` 扩展；官方扩展表面位于 `~/.gemini/config/plugins/<name>/`，其中 `plugin.json` 的 `suggestedPrompts` 必须为纯字符串数组，插件内 `hooks.json` 的 `PostInvocation` 与 `Stop` 必须为扁平命令处理器数组，标准输入提供 `lastUserInput`、`conversationId`、`workspacePaths` 与 `transcriptPath`，内置 `/Applications/Antigravity.app/Contents/Resources/app/bin/agentapi` 支持通过 `new-conversation` 启动新会话，且 `Knowledge Work` 视图适合直接消费 `/mcp` 工具对照成文。

### 2. DeepSeek Harness（DSH）桌面端官方接口与本机安装包

- **宿主事实**，本机 `com.deepseek.dsh`（DeepSeek Harness 0.2.2-rc.2）由 Electron 桌面端独占 `~/.dsh/profiles/desktop` profile，内置 `dsh://open` 唤醒主窗口，通过 `dsh plugin --profile desktop add` 加载符合 `@deepseek-ai/cordis` 契约的插件包（前端入口经 `window.__ModuleLoader__.load` 注册为 classic 脚本）。
- **官方插件接缝**，Host 侧经 `ctx.webServer.register` 挂载同源路由并经 `ctx.sessionQuery` 读取实时与持久化会话日志；Client 侧经 `ctx.uiWorkspace.openWorkspace`、`ctx.uiWorkspace.openSession` 与 `ctx.conversation.input.requestDraftInitialization(..., { whenDraftExists: 'append' })` 完成空白会话预填与原会话跳转，不复制安装包源码，也不向插件暴露任何 Memos 凭据。
- **历史注记**：早期版本曾对接 Codex `app-server --stdio` 与 `codex://threads/wake/<UUID>`，已于 2026-11-19 按用户决定彻底移除并由 DSH 替代；ChatGPT 桌面端（`com.openai.codex`）仅保留辅助功能选区暂存支持。

### 3. 立项初期核查的产品机制对照项

| 来源 | 链接与性质 | 机制启发与取舍边界 |
| --- | --- | --- |
| `yetone/rewind-for-x` | [yetone/rewind-for-x](https://github.com/yetone/rewind-for-x)，`MIT` | 验证了保留出处链接、可检索与可清空的轻量回看体验，但其自动记录时间线曝光帖子的模式不同于本项目的主观选段暂存，零代码复制 |
| `Glasp` 指南页 | [Save and Highlight AI Chat Answers](https://glasp.co/posts/how-to-save-and-highlight-ai-chat-answers)，闭源商业服务 | 对照了只存选中最小片段与原会话回链并通过 MCP 供助手检索的工作流，本项目不绑定第三方商业账号 |
| `Superpower ChatGPT` 功能页 | [Text Highlights and Annotations](https://spchatgpt.com/features/text-highlights)，闭源商业产品 | 印证了必须将用户批注或派生说明与原始聊天正文严格区分展示的原则 |
| `ccheney/threadmark` | [ccheney/threadmark](https://github.com/ccheney/threadmark)，`MIT` | 验证了聊天选段收藏与原会话回跳定位，本项目进一步打通桌面 Antigravity 与多网页站点统一汇聚 |
| `AUI-AI-squad/bookmark_chrome_extension` | [bookmark_chrome_extension](https://github.com/AUI-AI-squad/bookmark_chrome_extension)，`MIT` | 其保存时强制输入名称的交互作为反例排除，确立本项目一键无感保存且异步生成标题的原则 |
| `jrnt30/tangent` 与 `fernandosmither/claude-tangents` | [tangent](https://github.com/jrnt30/tangent) 与 [claude-tangents](https://github.com/fernandosmither/claude-tangents)，均为 `MIT` | 印证了主对话推进中不愿当场分叉污染主线的延迟分叉心理，本项目将其延伸为跨应用的 72 小时热流池 |
| `egroup-labs/kept` 与 `aliabdm/ContextVault` | [kept](https://github.com/egroup-labs/kept) 与 [ContextVault](https://github.com/aliabdm/ContextVault)，均为 `MIT` | 对照了多采集端汇入单一存储并经 MCP 反哺桌面 Agent 的拓扑形态 |
| `benjaminfh/researchtree` 与 `MemPalace/mempalace` | [researchtree](https://github.com/benjaminfh/researchtree) 与 [mempalace](https://github.com/MemPalace/mempalace)，均为 `MIT` | 分别对照了围绕片段追问成文的消费流与 Antigravity 2.x 钩子载荷字段核查方法 |
| `obsidianmd/obsidian-clipper` | [obsidian-clipper](https://github.com/obsidianmd/obsidian-clipper)，`MIT` | 早期曾评估其自定义 URL Scheme 唤醒方案，实测浏览器会弹系统确认框并抢夺焦点，已在 v0.2 弃用并记入 [lessons.md](../lessons.md)；其内容脚本重注入生命周期清理模式已按 MIT 适配入 `extensions/web-clipper/content.js` |

## 文档与隐私参考规范

| 规范 | 链接 | 用途 |
| --- | --- | --- |
| GitHub Docs About READMEs | [About READMEs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes) | 保持根 `README.md` 简明扼要，专题文档拆分至 `docs/` 并用相对链接互指 |
| Diataxis | [Diataxis Start Here](https://www.diataxis.fr/start-here/) | 将需求边界、架构参考、来源核查与验收步骤分文件独立维护 |
| GDPR Article 5 | [EUR-Lex Regulation 2016/679](https://eur-lex.europa.eu/eli/reg/2016/679/oj) | 作为 [privacy.md](privacy.md) 数据最小化、原文准确性与可删除设计原则的参考，不构成法域合规声明 |

## 2026-11-13 桌面入口与设置复核

核读 Maccy 提交 `f0b571e32e4031d7b91ba811f50d0f33e8e5548b` 的 [AppDelegate](https://github.com/p0deje/Maccy/blob/f0b571e32e4031d7b91ba811f50d0f33e8e5548b/Maccy/AppDelegate.swift)、[GeneralSettingsPane](https://github.com/p0deje/Maccy/blob/f0b571e32e4031d7b91ba811f50d0f33e8e5548b/Maccy/Settings/GeneralSettingsPane.swift) 与 [AppearanceSettingsPane](https://github.com/p0deje/Maccy/blob/f0b571e32e4031d7b91ba811f50d0f33e8e5548b/Maccy/Settings/AppearanceSettingsPane.swift)，再次读取根 LICENSE 确认为 MIT。此次沿用状态栏对象集中持有、偏好集中保存、原生设置分组的做法，不引入其 Defaults 或 Settings 依赖，不复制源码。具体验收规则见 [代码质量与验收标准](code-quality.md)。

## 2026-11-15 单二进制 CLI 与内嵌领域 MCP 架构模式对照

核查下列三个标准 `MIT` 开源项目的架构组织（均已核实仓库根目录 `LICENSE` 为标准 `MIT`，仅作架构模式参考，**零第三方代码复制**）：

| 项目 | 仓库与核实许可 | 架构模式参考（零代码复制） |
| --- | --- | --- |
| `tobi/qmd` | [tobi/qmd](https://github.com/tobi/qmd)，`MIT License` | 参考同一单二进制同时承载终端 CLI 子命令（`search`、`get` 等）与 `mcp` `stdio` 子命令、收敛为少量高信噪比领域工具而非透传底层通用 CRUD 接口的分层设计 |
| `openclaw/gogcli` | [openclaw/gogcli](https://github.com/openclaw/gogcli)，`MIT License` | 参考面向 Coding Agent 的稳定 `--json` 机器可读输出、标准错误与非零退出码分离及最小可组合动词集设计 |
| `steipete/Peekaboo` | [steipete/Peekaboo](https://github.com/steipete/Peekaboo)，`MIT License` | 参考 macOS 原生应用与同名 CLI / `mcp` 工具共享底层 Swift Core 模块并随应用包统一分发签名的双面入口组织 |

## 2026-11-16 片段归档与删除交互核查

核查下列三个标准 `MIT` 开源项目的归档与破坏性删除交互模式（均已核实 GitHub API 返回许可为标准 `MIT License`，仅作交互与接口设计对照，**零第三方代码复制**）：

| 项目 | 仓库与核实许可 | 交互与接口设计参考（零代码复制） |
| --- | --- | --- |
| `usememos/memos` | [usememos/memos](https://github.com/usememos/memos)，`MIT License` | 参考 `MemoActionMenu.tsx` 区分状态流转归档与物理删除的入口分层，以及 `memo_service.proto` 的 `DeleteMemo` DELETE 接口契约 |
| `p0deje/Maccy` | [p0deje/Maccy](https://github.com/p0deje/Maccy)，`MIT License` | 参考 `ConfirmationView.swift`、`Footer.swift` 与 `KeyChord.swift` 在非激活 `NSPanel` 中采用面板内确认条及修饰键直删而不弹系统模态窗的焦点保持模式 |
| `raycast/extensions` | [raycast/extensions](https://github.com/raycast/extensions)，`MIT License` | 参考 `Action.Style.Destructive` 对高危操作视觉警示、确认提示及快捷键与常规归档动作分离的设计习惯 |

## 2026-11-16 来源开头留底、文本片段锚点与浮窗脉络预览核查

核查下列开源项目与开放标准在来源留底、精准段落回跳与浮窗内原地预览上的设计（均仅作机制参考或规范遵从，**零第三方代码复制**）：

| 项目或规范 | 链接与核实许可 | 机制与设计参考（零代码复制） |
| --- | --- | --- |
| `obsidianmd/obsidian-clipper` 与 `kepano/defuddle` | [obsidian-clipper](https://github.com/obsidianmd/obsidian-clipper)（`MIT`）、[defuddle](https://github.com/kepano/defuddle)（`MIT`） | 参考以结构化页面导语（标题、描述、开头正文）搭配选区前后短文本锚点（`TextQuoteAnchor`）替代重型页面截图的轻量留底设计 |
| `WICG/scroll-to-text-fragment` | [scroll-to-text-fragment](https://github.com/WICG/scroll-to-text-fragment)，W3C 社区组规范 | 遵循 URL Fragment Text Directives 标准语法 `#:~:text=[prefix-,]textStart[,textEnd][,-suffix]` 及词边界对齐、`%2D` 连字符转义与 `#hash:~:text=` 组合规则，使普通网页链接在现代浏览器中无需扩展即可直达原句高亮 |
| `entireio/cli` 与 `daaain/claude-code-log` | [entireio/cli](https://github.com/entireio/cli)（`MIT`）、[claude-code-log](https://github.com/daaain/claude-code-log)（`MIT`） | 参考面向 Coding Agent 本地会话采用会话 UUID 与首轮开场提问（`Session Opening`）锁定全局任务意图，配合 `p0deje/Maccy` 的 `PreviewItemView` 思路在浮窗内提供两步渐进式脉络预览 |

## 2026-11-21 位置（Places）与对象化笔记设计对照

许可经 `gh api repos/<repo>` 于 2026-11-21 实测，均仅作设计对照，**零第三方代码复制**：

| 项目或来源 | 链接与核实许可 | 设计参考（零代码复制） |
| --- | --- | --- |
| Paco Cantero〈Your Thoughts Are Objects, Not Notes〉 | [x.com/PacomyICOR/status/2123739890449805718](https://x.com/PacomyICOR/status/2123739890449805718) | ICOR「My Life」地图与「捕获与思考两个世界、两个工具」的分治原则 |
| `usememos/memos` | [usememos/memos](https://github.com/usememos/memos)，`MIT License` | 层级标签树承载 `#project/<slug>` 等位置标签；`ListMemoRelations` / `SetMemoRelations` 双向 `REFERENCE` 关系留作后续片段连接 |
| `silverbulletmd/silverbullet` | [silverbulletmd/silverbullet](https://github.com/silverbulletmd/silverbullet)，`MIT License` | 在纯 Markdown 中以标签与字段表达带类型对象的写法，对照位置记录引用头格式 |
| `raycast/extensions` | [raycast/extensions](https://github.com/raycast/extensions)，`MIT License` | 单行模糊搜索列表加动作面板，对照浮窗 `⌘P` 落位选择器 |
| `logseq/logseq`、`siyuan-note/siyuan`、`TriliumNext/Trilium` | `AGPL-3.0` | 仅对照块引用、页面属性与大纲交互概念，严禁复制代码 |
| `anyproto/anytype-ts`、`toeverything/AFFiNE` | GitHub 许可识别为 `NOASSERTION` | 仅对照 Type / Relation 对象模型概念，严禁复制代码 |
