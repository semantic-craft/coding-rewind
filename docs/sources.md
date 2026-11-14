# 来源核查与开源复用边界

本文记录项目立项与统一架构设计期间实际核查的开源仓库、商业对照页面及规范文本。所有代码级参考与裁剪均严格限定在标准 `MIT` 许可项目内并保留原作者版权声明；凡属 `GPL`、`AGPL`、`Commons Clause`、无许可或闭源商业产品，一律保持零代码复用。

无许可仓库的处理依据见 [Choose a License No Permission](https://choosealicense.com/no-permission/)。

## 直接复用或裁剪模式的 MIT 上游项目

以下九个项目均已核实仓库根目录 `LICENSE` 全文与 GitHub API `license.spdx_id` 为标准 `MIT`，构成本仓库四端实现的技术底座：

| 项目 | 仓库与许可证据 | 在本项目中的具体复用与适配 |
| --- | --- | --- |
| `usememos/memos` | [usememos/memos](https://github.com/usememos/memos)，`MIT License` | 零修改直接采用官方固定版本 `neosmemo/memos:26.11.0` 容器作为唯一后端事实源，使用其 `/api/memos`、评论接口、`internal/webhook/webhook.go` 的 Standard Webhooks HMAC-SHA256 签名约定以及进程内原生 `/mcp` Streamable HTTP 服务 |
| `p0deje/Maccy` | [p0deje/Maccy](https://github.com/p0deje/Maccy)，`MIT License`，Copyright Alex Rodionov | 在 `CodingRewindApp` 适配其 `FloatingPanel` 的 `.nonactivatingPanel` 非激活浮窗标志位、`.hudWindow` 毛玻璃视觉材质、键盘多选列表手感与剪贴板快照保护思路 |
| `GaimsDevSoftware/linuxpop` | [GaimsDevSoftware/linuxpop](https://github.com/GaimsDevSoftware/linuxpop)，`MIT License`（2026-11-14 Asia/Shanghai 读取 `README.md` 与 `LICENSE`） | 在 `SelectionPopupController.swift` 借鉴其 PopClip 风格划词探测与执行两阶段分离思路，第一阶段仅在满足拖拽或双击手势阈值后以纯只读方式判定选区并展示非激活胶囊，第二阶段仅在用户点击胶囊或按下快捷键时执行实际捕获 |
| `sindresorhus/KeyboardShortcuts` | [3.1.0 上游源码](https://github.com/sindresorhus/KeyboardShortcuts/tree/772133d9dbe800fdac0473226822994c5c162c58)，`MIT License`，Copyright Sindre Sorhus | `Vendor/KeyboardShortcuts/` 保留源码、测试、本地化资源、manifest 与原许可，提供 Recorder、Hyper、配置持久化、Carbon 注册与菜单跟踪。本地补丁提供真实注册状态、失败重试、可注入偏好域和复用菜单冲突查询；版本与补丁边界见该目录 README |
| `tisfeng/SelectedTextKit` | [tisfeng/SelectedTextKit](https://github.com/tisfeng/SelectedTextKit)，`MIT License`，Copyright Tao Shi | 在 `MacOSSelection.swift` 采用其选区获取双阶段策略，先读焦点元素 `kAXSelectedTextAttribute`，为空时完整备份 `NSPasteboardItem` 全部类型数据与 `changeCount`，投递 `CGEvent` 模拟 `⌘C` 校验计数递增后在 `defer` 无条件还原剪贴板 |
| `wxtsky/CodeIsland` | [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland)，`MIT License`，Copyright wxtsky | 在 `AntigravityIntegration.swift` 借鉴将辅助二进制固定拷入 `~/Library/Application Support/CodingRewind/bin/` 避免 `.build/` 断链的安装模式。早期借鉴的 Hook 快照管线已由按选区读取官方 transcript 替代 |
| `mem0ai/mem0-chrome-extension` | [mem0ai/mem0-chrome-extension](https://github.com/mem0ai/mem0-chrome-extension)，`MIT License` | 在 `extensions/web-clipper/` 适配其 Manifest V3 划选捕获、右键菜单加快捷键触发、后台 Service Worker 直连远端 REST 接口以及右上角 2.2 秒轻量非抢焦点提示条交互，彻底替代自定义 URL 协议唤醒 |
| `revivalstack/ai-chat-exporter` | [revivalstack/ai-chat-exporter](https://github.com/revivalstack/ai-chat-exporter)，`MIT License` | 在 `extensions/web-clipper/extractors.mjs` 参考其跨 AI 聊天站点的消息轮次角色识别、会话标题清洗及代码块与列表 HTML 转 Markdown 规则 |
| `pionxzh/chatgpt-exporter` | [pionxzh/chatgpt-exporter](https://github.com/pionxzh/chatgpt-exporter)，`MIT License` | 在 `extensions/web-clipper/extractors.mjs` 参考其针对聊天 DOM 选区与围栏代码块语言类名的稳健清洗转换策略，提取选中内容与前序 4 轮问答脉络 |

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

## 目标宿主与早期机制对照来源

以下来源用于明确目标宿主扩展契约与早期产品交互对照，不涉及第三方源码并入：

### 1. Google Antigravity App 2.x 官方文档与本机包信息

- **核查链接**，[下载页](https://antigravity.google/download)、[2.0 发布说明](https://antigravity.google/blog/introducing-google-antigravity-2)、[构建插件指南](https://antigravity.google/docs/build-plugins/)、[自定义发现路径](https://antigravity.google/docs/customization-discovery/)、[更新日志](https://antigravity.google/docs/changelog/)。
- **宿主事实**，Google Antigravity 2.x 是独立 Electron 桌面应用，`CFBundleIdentifier` 为 `com.google.antigravity`，不支持 VS Code `.vsix` 扩展；官方扩展表面位于 `~/.gemini/config/plugins/<name>/`，其中 `plugin.json` 的 `suggestedPrompts` 必须为纯字符串数组，插件内 `hooks.json` 的 `PostInvocation` 与 `Stop` 必须为扁平命令处理器数组，标准输入提供 `lastUserInput`、`conversationId`、`workspacePaths` 与 `transcriptPath`，内置 `/Applications/Antigravity.app/Contents/Resources/app/bin/agentapi` 支持通过 `new-conversation` 启动新会话，且 `Knowledge Work` 视图适合直接消费 `/mcp` 工具对照成文。

### 2. Codex 官方 app-server 与本机安装包

- **协议来源**，发现的官方 CLI 的 `app-server --help` 与 `app-server generate-json-schema`。实现使用 `initialize`、`thread/start`、`thread/name/set`、`thread/unsubscribe`、`thread/queue/add`、`thread/queue/list` 和 `thread/read`，不复制安装包源码。
- **持久化依据**，官方 [LocalThreadStore 的 metadata 更新](https://github.com/openai/codex/blob/main/codex-rs/thread-store/src/local/update_thread_metadata.rs#L99-L107) 在首轮前命名线程时持久化空记录。官方 [线程配置](https://github.com/openai/codex/blob/main/codex-rs/config/src/config_toml.rs#L349-L353) 定义 `thread_unload_delay_secs=0` 使无订阅、无活动的线程立即卸载。
- **宿主边界**，本机 `com.openai.codex` 安装包的 `codex://threads/wake/<UUID>` 负责运行待发消息，`codex://threads/<UUID>` 负责导航。接聊只向本次创建、已持久化且已卸载的新线程排队。成功须读回真实首轮及原文，不把 queue 回执或 URL 打开作为收件证明。

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
| `obsidianmd/obsidian-clipper` | [obsidian-clipper](https://github.com/obsidianmd/obsidian-clipper)，`MIT` | 早期曾评估其自定义 URL Scheme 唤醒方案，实测浏览器会弹系统确认框并抢夺焦点，已在 v0.2 弃用并记入 [lessons.md](../lessons.md) |

## 文档与隐私参考规范

| 规范 | 链接 | 用途 |
| --- | --- | --- |
| GitHub Docs About READMEs | [About READMEs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes) | 保持根 `README.md` 简明扼要，专题文档拆分至 `docs/` 并用相对链接互指 |
| Diataxis | [Diataxis Start Here](https://www.diataxis.fr/start-here/) | 将需求边界、架构参考、来源核查与验收步骤分文件独立维护 |
| GDPR Article 5 | [EUR-Lex Regulation 2016/679](https://eur-lex.europa.eu/eli/reg/2016/679/oj) | 作为 [privacy.md](privacy.md) 数据最小化、原文准确性与可删除设计原则的参考，不构成法域合规声明 |

## 2026-11-13 桌面入口与设置复核

核读 Maccy 提交 `f0b571e32e4031d7b91ba811f50d0f33e8e5548b` 的 [AppDelegate](https://github.com/p0deje/Maccy/blob/f0b571e32e4031d7b91ba811f50d0f33e8e5548b/Maccy/AppDelegate.swift)、[GeneralSettingsPane](https://github.com/p0deje/Maccy/blob/f0b571e32e4031d7b91ba811f50d0f33e8e5548b/Maccy/Settings/GeneralSettingsPane.swift) 与 [AppearanceSettingsPane](https://github.com/p0deje/Maccy/blob/f0b571e32e4031d7b91ba811f50d0f33e8e5548b/Maccy/Settings/AppearanceSettingsPane.swift)，再次读取根 LICENSE 确认为 MIT。此次沿用状态栏对象集中持有、偏好集中保存、原生设置分组的做法，不引入其 Defaults 或 Settings 依赖，不复制源码。具体验收规则见 [代码质量与验收标准](code-quality.md)。
