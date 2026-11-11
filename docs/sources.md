# 来源调研

读取日期（除非条目另注）：2026-11-10，时区 Asia/Shanghai。本节只记录已实际打开并阅读的原始页面或仓库文件，不根据星数排序，也不把商业产品写成开源软件。

调研目的有两层：一是看清「选段保存、保留出处、再找回来」这一类产品已经怎么做；二是为立项文档结构找可信规范。所有第三方实现都只作机制对照，不复制代码。

## 阅读方法

- 指定的三个来源均直接读取页面或仓库原始文件，而不是二手摘要。
- 开源项目另核 GitHub API 的 `license` 字段，并读取仓库内的 `LICENSE` 或 README 许可声明。二者不一致时以仓库内的许可文本为准，并在条目中写明。
- 没有许可文件的公开仓库，不视为可合法再使用的开源软件。依据见 [Choose a License：No License](https://choosealicense.com/no-permission/)。
- 本次检索中看到但不符合「可核、相关、真开源」标准的项目，记在文末，避免误用。

## 指定来源

### 1. yetone/rewind-for-x

| 项 | 内容 |
| --- | --- |
| 链接 | 仓库：https://github.com/yetone/rewind-for-x ；README：https://raw.githubusercontent.com/yetone/rewind-for-x/main/README.md ；许可：https://raw.githubusercontent.com/yetone/rewind-for-x/main/LICENSE ；官网：https://rewindforx.com/ ；隐私政策：https://rewindforx.com/privacy/ |
| 已读 | 仓库说明、README、`LICENSE` 全文、官网首页、隐私政策、GitHub API 仓库元数据 |
| 许可证据 | README 写明 MIT；`LICENSE` 为 MIT License，Copyright (c) 2026 yetone；GitHub API `license.spdx_id` 为 `MIT`。最近推送时间（API `pushed_at`）为 2026-11-10 09:12:24 UTC，即 2026-11-10 17:12:24 Asia/Shanghai。 |
| 它是什么 | Chrome 扩展：在 X 首页时间线里，把已经在屏幕上露出一半以上的帖子记下来，方便首页刷新后回看。这是浏览历史回看，**不是** AI 对话收藏工具。 |
| 可借鉴机制 | 本机存储（`chrome.storage.local`），无账号、无上传；保留作者、正文、图片、引用和链接等出处信息；可搜索；可一键清空；有数量上限（最多 3000 条，超出淘汰旧记录）。隐私政策写明不向开发者或服务器发送数据。 |
| 限制 | 只记首页推荐/关注时间线，不记广告、详情页、个人主页；自动记下「看过的」内容，这与本项目「用户选段后再保存」并不相同，更接近本项目里尚未立项的「自动暂存」。领域是 X 帖子，不是 AI 聊天。图中文字识别需另开，并在本机下载识别数据。 |
| 复用边界 | 许可是 MIT，允许在保留版权与许可声明的前提下使用、修改和再分发。本项目**不复制其源代码**。可借鉴的是「本机保存、保留出处、可搜索、可清空」这些机制，而不是把 X 浏览历史产品改名为 AI 收藏。 |

### 2. Glasp：How to Save and Highlight AI Chat Answers

| 项 | 内容 |
| --- | --- |
| 链接 | https://glasp.co/posts/how-to-save-and-highlight-ai-chat-answers |
| 已读 | 该指南全文（页面标注日期 Oct 09, 2026），包括步骤、隐私说明与 FAQ |
| 许可证据 | 未在该页发现开源许可。Glasp 是带账号的商业浏览器扩展与服务，**不是开源项目**。 |
| 它是什么 | 教用户在 ChatGPT、Claude、Gemini 等聊天页面里划选文本、加高亮，把选段存进可搜索的收藏，并保留指向原会话的链接。 |
| 可借鉴机制 | 先打开有独立 URL 的会话，再划选值得留下的最小片段；建议同时高亮提示词（原问题）和回答；可用笔记说明「为什么留下」，标签可选地用于跨会话归类；用搜索或标签找回；`Open Link` 回到原线程；可导出到 Notion、Obsidian、Markdown 等；可用 MCP Connector（`https://glasp.co/api/mcp`）让助手用自然语言检索自己的高亮。该页称 Connector 只能搜索，不能编辑或删除，写入仅在用户批准时添加书签。AI 聊天站点上的高亮自 2026-08-05 起在各档套餐（含 Free）默认私密。FAQ 明确：它不自动保存整段对话，只保存用户选中的段落和回链。 |
| 限制 | 依赖浏览器扩展和 Glasp 账号；原会话需要可回指的 URL，桌面客户端或没有稳定链接的聊天可能不适用；检索与导出能力绑定其商业服务；本页不是产品全部条款，完整隐私政策与服务条款未在本轮逐条另读。 |
| 复用边界 | 只能借鉴产品机制与文案中公开说明的工作流，不能把 Glasp 当作可复制的开源实现，也不能把其 MCP、导出或隐私策略直接写成 Coding-Rewind 的已定方案。 |

### 3. Superpower ChatGPT：Text Highlights and Annotations

| 项 | 内容 |
| --- | --- |
| 链接 | https://spchatgpt.com/features/text-highlights |
| 已读 | 该功能页全文，包括工作流、能力列表与 FAQ |
| 许可证据 | 未在该页发现开源许可。Superpower 是面向 ChatGPT 的商业产品，**不是开源项目**。 |
| 它是什么 | 在 ChatGPT 回答里划选文本、选择颜色并添加注释，把选段连同来源会话和周围上下文存成可搜索笔记。 |
| 可借鉴机制 | 选段保存而不是整页复制；注释用来记下「为什么重要」；高亮与来源、上下文一起保存；之后用搜索、笔记、文件夹或导出找回；页面提醒：高亮只是留下一段文字，并不等于核实答案正确，需要把原文和用户自己的注释区分开。 |
| 限制 | 该页描述的是 ChatGPT 工作流，不能据此认定它覆盖其他助手；实现细节、存储位置、许可和数据是否出设备，本页没有完整说明；未在本轮另读其全部条款。 |
| 复用边界 | 仅作商业产品的机制对照，不可当作开源代码或可再分发组件。 |

## 少量真正相关的开源或源码公开项目

下面三项与「保存 AI 聊天中的片段并再找到」直接相关，且都实际阅读了 README（及许可文本）。收录不依据星数。

### 4. ccheney/threadmark

| 项 | 内容 |
| --- | --- |
| 链接 | https://github.com/ccheney/threadmark ；README：https://raw.githubusercontent.com/ccheney/threadmark/main/README.md ；许可：https://raw.githubusercontent.com/ccheney/threadmark/main/LICENSE |
| 已读 | README、`LICENSE` 全文、GitHub API 仓库元数据 |
| 许可证据 | `LICENSE` 为 MIT License，Copyright (c) 2025 Threadmark contributors；GitHub API `license.spdx_id` 为 `MIT`。 |
| 它是什么 | Chrome 扩展：在 ChatGPT 会话中划选文本并一键收藏，在侧边栏里浏览和搜索「clipbook」，点击条目可回到原聊天并滚动到原文位置（含对懒加载的定位）。数据存 IndexedDB，README 称不向外部服务器发送数据，权限范围限定 `chatgpt.com`。 |
| 可借鉴机制 | 与本项目「选段一键留存、保留出处、再回顾」最为接近；用模糊匹配 / DOM 锚定应对聊天内容位移；本地优先。标签和笔记是其功能，但本项目方向是「不强迫标题标签」，对照时应注意不要把可选注释做成保存的前置条件。 |
| 限制 | 目前只覆盖 ChatGPT 网页；是否满足「自然语言找回」从 README 只能看到搜索与筛选，不能认定已有自然语言问答式检索。 |
| 复用边界 | MIT 允许在保留声明的前提下使用和修改。本项目不复制其代码，只借鉴机制。 |

### 5. AUI-AI-squad/bookmark_chrome_extension

| 项 | 内容 |
| --- | --- |
| 链接 | https://github.com/AUI-AI-squad/bookmark_chrome_extension ；README：https://raw.githubusercontent.com/AUI-AI-squad/bookmark_chrome_extension/main/README.md ；许可：https://raw.githubusercontent.com/AUI-AI-squad/bookmark_chrome_extension/main/LICENSE |
| 已读 | README、`LICENSE` 全文、GitHub API 仓库元数据 |
| 许可证据 | `LICENSE` 为 MIT License，Copyright (c) 2026 AUI-AI-squad；README 声明 MIT；GitHub API `license.spdx_id` 为 `MIT`。 |
| 它是什么 | Chrome 扩展：为 ChatGPT、Gemini、Claude 的「整轮对话」（turn）加书签，用浮动面板和弹出页跳转，并把整段会话导出为 Markdown。ChatGPT 另有高亮文本与问答之间的双向引用。 |
| 可借鉴机制 | 跨三个网页产品的出处与跳转；导出 Markdown；按会话组织已保存条目。 |
| 限制 | 使用说明要求点击书签图标后「enter a name」，即保存时需要命名。这与本项目「不强迫标题」直接相反，只能当反例，不能当默认交互。它保存的是整轮，不是任意选段；自然语言找回在 README 中未见。DOM 选择器会随各站改版失效，README 自己也提醒这一点。 |
| 复用边界 | MIT，允许在保留声明下使用。本项目不复制其代码。 |

### 6. Veverke/bAInder

| 项 | 内容 |
| --- | --- |
| 链接 | https://github.com/Veverke/bAInder ；README：https://raw.githubusercontent.com/Veverke/bAInder/main/README.md ；许可：https://raw.githubusercontent.com/Veverke/bAInder/main/LICENSE |
| 已读 | README（含功能说明与许可摘要）、`LICENSE` 全文、GitHub API 仓库元数据 |
| 许可证据 | 仓库内 `LICENSE` 标题为 “MIT License with Commons Clause”，Copyright (c) 2026 Avraham Y. Kahana。GitHub API 仅标为 `Other` / `NOASSERTION`，不能把它当成标准 MIT。Commons Clause v1.0 明确：**不授予出售该软件的权利**；不得把该软件作为其价值主要来源的产品或托管服务对外收费提供。README 亦写明可用于个人和内部业务，但不得作为商业产品或托管服务出售。 |
| 它是什么 | 本地优先的浏览器扩展：可一键保存整段会话，也可对选中文本右键「Save selection」另存为摘录；覆盖 ChatGPT、Claude、Gemini、Copilot、Perplexity、DeepSeek。数据在 `chrome.storage.local`。另有组织、检索、阅读、导出/导入等大量功能。 |
| 可借鉴机制 | 选段另存、保留来源平台、导出 Markdown（含来源与日期等元数据）、导入备份、本地存储用量提示。标签和标题出现在保存对话框中，是否强制填写需以后对照实际界面，不能从 README 武断结论。 |
| 限制 | 功能面远大于本项目 MVP，许多能力（全文会话快照、主题树、评分、AI 对比等）不属于当前范围。许可不是宽松开源意义上的 MIT。 |
| 复用边界 | **不可当作标准开源许可下的可商业再发布软件。** 本项目不复制其代码，不把它的实现当作可直接并入的依赖。只记录公开文档中的机制，供对照。 |

## 查阅后不作为开源实现的项目

| 项目 | 链接 | 为何排除 |
| --- | --- | --- |
| Solveneers/ai-chat-navigator-pro | https://github.com/Solveneers/ai-chat-navigator-pro ；README：https://raw.githubusercontent.com/Solveneers/ai-chat-navigator-pro/main/README.md | 2026-11-10 读取 README 与 GitHub API。README 描述了划选高亮、跨平台、本地存储等机制，但仓库内容只有 `README.md`、`index.html` 和若干图标，**没有扩展源码，也没有 `LICENSE`**。API 的 `license` 为 `null`。按 [No License](https://choosealicense.com/no-permission/)：没有许可通常意味着没有使用、修改、分享的许可。故只当作宣传说明，不当作可复用开源软件。 |
| lee-jet/chat-highlight | https://github.com/lee-jet/chat-highlight | 检索时看到其 README 写明：仓库是社区议题与文档中心，**扩展代码目前闭源**。因此不作为开源项目收录，也不把商业/闭源实现写成开源。 |
| ericmjl/canvas-chat | https://github.com/ericmjl/canvas-chat ；README：https://raw.githubusercontent.com/ericmjl/canvas-chat/HEAD/README.md | 2026-11-10 读取 README 与 GitHub API。README 清晰展示了 `Highlight & Branch`（选中节点内文本生成摘录分支）与 `Multi-Select & Merge`（多选节点合并上下文追问）的交互，但 GitHub API 的 `license` 为 `null`，仓库内亦未提供 `LICENSE`。按 [No License](https://choosealicense.com/no-permission/) 不视为可复用开源软件，仅记录公开功能机制以供交互对照。 |

指定的三个来源以及上表仓库链接在 2026-11-10 均可打开，没有因死链剔除的指定来源。

## 2026-11-10 补充调研：Antigravity App 2.x、延迟分叉、双端本机汇聚与片段互动工作台

读取日期：2026-11-10，时区 Asia/Shanghai。以下条目针对用户一手确认的四个关键维度补充核查：（1）目标宿主 **Google Antigravity App 2.x** 与 IDE 版的边界；（2）看到好段落**当下不开新对话、不打断主线**的支线/暂存心理；（3）**网页版 + 桌面端统一汇聚本机**并暴露 MCP；（4）回顾后**围绕片段互动（A）+ 对照写草稿（C）**。

### 7. Google Antigravity App 2.x 官方文档与本机包元数据（目标宿主，非开源）

| 项 | 内容 |
| --- | --- |
| 链接 | 下载页：https://antigravity.google/download ；2.0 发布说明：https://antigravity.google/blog/introducing-google-antigravity-2 ；构建插件：https://antigravity.google/docs/build-plugins/ ；自定义发现路径：https://antigravity.google/docs/customization-discovery/ ；更新日志：https://antigravity.google/docs/changelog/ |
| 已读 | 上述五个公开页面正文，以及 Helios 本机 `/Applications/Antigravity.app/Contents/Info.plist`（仅读取应用包元数据，未读取任何用户私密会话内容） |
| 许可证据 | Google 商业软件与官方文档，**不是开源项目**。 |
| 关键事实 | 1. **与 Antigravity IDE 完全独立**：2.0 发布说明明确写明 Google Antigravity 2.0 是独立桌面应用（*"there is no IDE... it is a completely separate desktop application"*）；本机 `Info.plist` 显示 `CFBundleIdentifier` 为 `com.google.antigravity`（当前版本 `2.31.0`，为 Electron 应用），**不加载 VS Code `.vsix` 界面扩展**。<br>2. **原生扩展表面（Plugin 体系）**：支持在 `~/.gemini/config/plugins/<name>/` 或工作区 `.agents/plugins/<name>/` 放置插件目录，包含 `plugin.json`（含可点击的 Starter prompts）、`mcp_config.json`（本地 `stdio` 或远端 MCP Server）、`hooks.json`（`SessionStart`、`PreInvocation`、`PostInvocation`、`PreToolUse`、`PostToolUse`、`Stop` 等生命周期钩子）、`skills/<name>/SKILL.md`（支持自然语言或 `/skill` 调用）与 `agents/`，但**不提供修改聊天界面右键菜单或注入自定义浮窗的 UI API**。<br>3. **写作与研究界面**：更新日志记录 `v2.30.0`（2026-11-09）新增 `Knowledge Work` 界面，隐藏 Git 与终端，聚焦对话、文档与 Artifacts。 |
| 对本项目的约束 | 针对 Antigravity App 2.x 设计时，不能假设 `.vsix` 插件可用；「零打扰选段暂存」需依靠系统级划选快捷动作配合 Hook/本地会话元数据关联，而「A+C 互动与写作」既可在独立工作台中完成，也可通过原生 Plugin（MCP + Skill）无缝接入 Antigravity App 的 `Knowledge Work` 界面。 |

### 8. jrnt30/tangent 與 fernandosmither/claude-tangents（划选开支线、不污染主对话）

| 项 | 内容 |
| --- | --- |
| 链接 | （1）https://github.com/jrnt30/tangent ；README：https://raw.githubusercontent.com/jrnt30/tangent/main/README.md ；许可：https://raw.githubusercontent.com/jrnt30/tangent/main/LICENSE <br>（2）https://github.com/fernandosmither/claude-tangents ；README：https://raw.githubusercontent.com/fernandosmither/claude-tangents/main/README.md ；许可：https://raw.githubusercontent.com/fernandosmither/claude-tangents/main/LICENSE |
| 已读 | 两个仓库的 README、`LICENSE` 全文、GitHub API 仓库元数据 |
| 许可证据 | 两者 `LICENSE` 均为 MIT License（分别为 Copyright (c) 2025 与 Copyright (c) 2026 fernandosmither），GitHub API `license.spdx_id` 均为 `MIT`。 |
| 它们是什么 | 面向 ChatGPT / Claude 网页端的浏览器扩展：在长回答里划选某一段文字，不污染当前主对话、也不用跳去新建空白标签页丢失上下文，而是在旁边挂起带引用上下文的侧边支线（`jrnt30/tangent` 支持最小化收起、稍后恢复）。 |
| 可借鉴机制 | 直接印证了「主对话正在推进时不想因一段好内容打断心流或污染上下文」的痛点；把「选段 + 保留前文语境」做成轻量动作。 |
| 限制 | 只活在浏览器单站点页面内，覆盖不到独立桌面端 Antigravity App，也没有跨 2～3 天的统一近期暂存池与写作草稿台。 |
| 复用边界 | MIT 许可。本项目不复制代码，只借鉴「延迟分叉（先摘出段落保住语境，稍后再展开对话）」的交互逻辑。 |

### 9. egroup-labs/kept 与 aliabdm/ContextVault（网页 + 本地跨端归集与 MCP）

| 项 | 内容 |
| --- | --- |
| 链接 | （1）https://github.com/egroup-labs/kept ；README：https://raw.githubusercontent.com/egroup-labs/kept/main/README.md ；许可：https://raw.githubusercontent.com/egroup-labs/kept/main/LICENSE <br>（2）https://github.com/aliabdm/ContextVault ；README：https://raw.githubusercontent.com/aliabdm/ContextVault/main/README.md ；许可：https://raw.githubusercontent.com/aliabdm/ContextVault/main/LICENSE |
| 已读 | 两个仓库的 README、`LICENSE` 全文、GitHub API 仓库元数据 |
| 许可证据 | `kept` 为 MIT License，Copyright (c) 2026 E-Group Labs；`ContextVault` 为 MIT License，Copyright (c) 2026 Mohammad Ali Abdul Wahed；GitHub API `license.spdx_id` 均为 `MIT`。 |
| 它们是什么 | `kept` 采用「浏览器扩展采集网页对话 → 发送至本机桌面端（`localhost`）→ 落盘本地 Markdown + SQLite FTS5」，支持对着本地存档继续聊天，并提供 MCP Server 给本地 Coding Agent 调用。`ContextVault` 同时采集浏览器聊天与本地终端/Agent 会话，归一化到本地存储并打包成下次会话可直接使用的 Prepared Context。 |
| 可借鉴机制 | 「轻量浏览器采集端 + 本机核心库 + 本地 MCP Server 反哺 Agent」的跨端拓扑结构；无云账号、本地优先。 |
| 限制 | 二者均偏向「整场会话全量归档与长期知识库」，而本项目核心是「用户主观挑中某几个好段落的近 2～3 天轻量暂存与成文互动」。 |
| 复用边界 | MIT 许可。本项目不复制源码，仅参考其「多采集入口汇入同一本机服务并暴露 MCP」的数据流形态。 |

### 10. anavvathi/Bridgecontext（跨平台上下文桥接，GPL-3.0）

| 项 | 内容 |
| --- | --- |
| 链接 | https://github.com/anavvathi/Bridgecontext ；README：https://raw.githubusercontent.com/anavvathi/Bridgecontext/main/README.md ；许可：https://raw.githubusercontent.com/anavvathi/Bridgecontext/main/LICENSE |
| 已读 | README、`LICENSE` 全文、GitHub API 仓库元数据 |
| 许可证据 | 仓库 `LICENSE` 为 GNU General Public License v3.0（GPL-3.0），GitHub API `license.spdx_id` 为 `GPL-3.0`。 |
| 它是什么 | 本地优先的上下文捕获与跨平台注入扩展，抓取 ChatGPT、Claude、Gemini 等对话上下文并桥接注入其他聊天端或本地编辑器。 |
| 复用边界 | **GPL-3.0 具有强 Copyleft 传染性。** 在本项目许可未定前，严禁复制、引用或衍生其任何代码；此处仅记录「跨平台捕获后一键注入写作/对话现场」的产品思路。 |

### 11. benjaminfh/researchtree 与 TenCent46/hypratia（围绕片段互动 A + 对照写作 C）

| 项 | 内容 |
| --- | --- |
| 链接 | （1）https://github.com/benjaminfh/researchtree ；README：https://raw.githubusercontent.com/benjaminfh/researchtree/master/README.md ；许可：https://raw.githubusercontent.com/benjaminfh/researchtree/HEAD/LICENSE <br>（2）https://github.com/TenCent46/hypratia ；README：https://raw.githubusercontent.com/TenCent46/hypratia/HEAD/README.md ；许可：https://raw.githubusercontent.com/TenCent46/hypratia/HEAD/LICENSE |
| 已读 | 两个仓库的 README、`LICENSE` 前文与声明、GitHub API 仓库元数据 |
| 许可证据 | `researchtree` 为 MIT License，Copyright (c) 2025 Benjamin F. Hall（GitHub API `MIT`）。`hypratia` 仓库内 `LICENSE` 为 **GNU Affero General Public License v3（AGPL-3.0）** 并另附商业许可说明（GitHub API 标为 `NOASSERTION`，按仓库内 `LICENSE` 为准）。 |
| 它们是什么 | `researchtree` 将分支对话与每个分支旁的可编辑 Markdown Canvas 结合，支持划选某段话在后台发起支线提问，再把有价值的结论合回草稿。`hypratia` 是 macOS 本地应用，将聊天消息或选段拖成独立 Markdown 卡片，支持选中卡片用快捷键继续向 AI 追问（对应场景 A），并在画布中串联成文导出（对应场景 C）。 |
| 限制与商业对照 | 二者都偏重重型研究画布，缺少跨 Antigravity App 与浏览器的「一秒无感塞入」。同类「左选片段、中聊推演（A）、右写草稿（C）」的成熟商业对照还有 **Google NotebookLM** 与 **Pieces for Developers**（均为闭源商业产品，非开源，仅作交互对照）。 |
| 复用边界 | `hypratia` 为 AGPL-3.0，**严禁复制或并入其代码**；`researchtree` 为 MIT，本项目亦不复制源码，只提炼「勾选暂存卡片组合成上下文追问 + 分栏草稿成文」的最小工作流。 |

### 12. MemPalace/mempalace 与 wxtsky/CodeIsland（Google Antigravity App 2.x 原生集成实例）

| 项 | 内容 |
| --- | --- |
| 链接 | （1）https://github.com/MemPalace/mempalace ；README：https://raw.githubusercontent.com/MemPalace/mempalace/HEAD/README.md ；调研笔记：https://raw.githubusercontent.com/MemPalace/mempalace/develop/hooks/antigravity/INVESTIGATION.md ；许可：https://raw.githubusercontent.com/MemPalace/mempalace/main/LICENSE <br>（2）https://github.com/wxtsky/CodeIsland ；README：https://raw.githubusercontent.com/wxtsky/CodeIsland/HEAD/README.md ；Issue #215：https://github.com/wxtsky/CodeIsland/issues/215 ；许可：https://raw.githubusercontent.com/wxtsky/CodeIsland/main/LICENSE |
| 已读 | 两个仓库的 README、`LICENSE` 全文、`MemPalace` 的 Antigravity 集成核查文档、`CodeIsland` Issue #215 与提交说明、GitHub API 元数据 |
| 许可证据 | 两者均为 MIT License（分别为 Copyright (c) 2026 MemPalace Contributors 与 Copyright (c) 2026 wxtsky），GitHub API `license.spdx_id` 均为 `MIT`。 |
| 可借鉴机制 | 两个项目均针对独立版 **Google Antigravity App 2.x**（`com.google.antigravity`）做了实机集成核查，验证了：Antigravity 2.x 的 `hooks.json`（位于 `~/.gemini/config/hooks.json` 或插件目录 `hooks.json`）在生命周期事件载荷中提供 `conversationId` 与 `transcriptPath`，且 `mcp_config.json` 可直接向 Antigravity App 暴露本地 `stdio` MCP 工具。2026-11-11 进一步核查 `CodeIsland` 源码（`Sources/CodeIslandBridge/main.swift`、`Tests/CodeIslandCoreTests/AntigravityHookContractTests.swift`，当时约 2,567 星）确认：Antigravity 的阻塞式 `PreToolUse` 若遇到空输出会拒绝工具调用，但非阻塞事件（`PostInvocation`、`Stop`、`PostToolUse`）无需返回决策即可静默观察会话上下文并通过本地 Unix Socket 传给主进程。 |
| 复用边界 | MIT 许可。`CodeIsland` 与本项目同为纯 Swift 技术栈，可在保留 MIT 版权与许可声明的前提下参考其非阻塞 Hook 桥接模式，实施时仍以 Google Antigravity 官方文档为准。 |

## 2026-11-11 补充调研：高星纯 Swift 原生底座、网页薄剪藏与两阶段工作流对照

读取日期：2026-11-11，时区 Asia/Shanghai。以下条目围绕用户「站在高星成熟开源项目基础上做、采用纯 macOS 原生 UI、拒绝跨栈胶水拼接」的要求补充核查，逐一读取了仓库 README、`LICENSE`、GitHub API 元数据及核心源码结构。

### 13. p0deje/Maccy（macOS 原生瞬时捕获、非激活浮窗与 SwiftData 标杆）

| 项 | 内容 |
| --- | --- |
| 链接 | 仓库：https://github.com/p0deje/Maccy ；README：https://raw.githubusercontent.com/p0deje/Maccy/HEAD/README.md ；许可：https://raw.githubusercontent.com/p0deje/Maccy/HEAD/LICENSE |
| 已读 | README、`LICENSE` 全文、GitHub API 仓库元数据（读取时 22,272 星），以及仓库内 `Maccy/FloatingPanel.swift`、`Maccy/Storage.swift`、`Maccy/Models/HistoryItem.swift`、`Maccy/Accessibility.swift`、`Maccy/Views/ContentView.swift` |
| 许可证据 | `LICENSE` 为 MIT License，Copyright (c) 2025 Alex Rodionov；GitHub API `license.spdx_id` 为 `MIT`。 |
| 它是什么 | 纯 `Swift + SwiftUI / AppKit + SwiftData` 编写的轻量级 macOS 原生剪贴板历史与瞬时检索工具。 |
| 可借鉴机制 | 1. `FloatingPanel.swift` 使用 `.nonactivatingPanel` 窗口标志位，呼出或触发反馈时不抢夺前台应用（如 Antigravity 或浏览器）的输入焦点，并在 `ContentView.swift` 原生支持 `GlassEffectView` 与 `VisualEffectView` 毛玻璃材质。<br>2. `Storage.swift` 仅用数十行代码将 `SwiftData` `ModelContainer` 落盘到本地 `Application Support` 下的单文件 SQLite，无需任何外部数据库进程。<br>3. 原生支持多选条目（`MultipleSelectionListView.swift`）、来源应用识别与按期自动清理，可直接映射为本项目的「近 72 小时热窗口卡片池」。 |
| 复用边界 | 标准 MIT 许可，与本项目选定的 MIT 协议及纯 Swift 技术栈完全兼容。若借用或改写具体源码片段，须完整保留原作者版权与 MIT 许可声明。 |

### 14. obsidianmd/obsidian-clipper（浏览器划选提取与原生 URL Scheme 静默投递标杆）

| 项 | 内容 |
| --- | --- |
| 链接 | 仓库：https://github.com/obsidianmd/obsidian-clipper ；README：https://raw.githubusercontent.com/obsidianmd/obsidian-clipper/HEAD/README.md ；许可：https://raw.githubusercontent.com/obsidianmd/obsidian-clipper/HEAD/LICENSE |
| 已读 | README、`LICENSE` 全文、GitHub API 仓库元数据（读取时 5,522 星）、`src/` 目录结构及 `src/utils/obsidian-note-creator.ts` |
| 许可证据 | `LICENSE` 为 MIT License，Copyright (c) 2024 Obsidian；GitHub API `license.spdx_id` 为 `MIT`。 |
| 它是什么 | Obsidian 官方开源的跨浏览器（Chrome、Safari、Firefox、Edge）网页高亮与 Markdown 剪藏扩展，纯 TypeScript 实现。 |
| 可借鉴机制 | 选区清洗转 Markdown、Shadow DOM 处理，以及 `obsidian-note-creator.ts` 中的原生客户端投递方式：通过自定义 URL Scheme 附带 `&silent=true`（大文本经剪贴板与 URI 双通道兜底）直接唤醒桌面原生应用静默落盘，使桌面端无需常驻监听本地 HTTP 端口即可接收网页聊天选段。 |
| 复用边界 | 标准 MIT 许可，可在保留 Obsidian 版权与 MIT 声明的前提下裁剪参考其选区提取与 URL Scheme 投递模块，用于 v0.2 浏览器薄扩展（适配 ChatGPT、Claude、Gemini）。 |

### 15. glushchenko/fsnotes、MarkEdit-app/MarkEdit 与 johnbean393/Sidekick（macOS 原生 Markdown 与本地材料对话参考）

| 项 | 内容 |
| --- | --- |
| 链接 | （1）https://github.com/glushchenko/fsnotes ；许可：https://raw.githubusercontent.com/glushchenko/fsnotes/HEAD/LICENSE <br>（2）https://github.com/MarkEdit-app/MarkEdit ；许可：https://raw.githubusercontent.com/MarkEdit-app/MarkEdit/HEAD/LICENSE <br>（3）https://github.com/johnbean393/Sidekick ；README：https://raw.githubusercontent.com/johnbean393/Sidekick/HEAD/README.md ；许可：https://raw.githubusercontent.com/johnbean393/Sidekick/HEAD/LICENSE |
| 已读 | 三个仓库的 README、`LICENSE` 全文与 GitHub API 仓库元数据（读取时分别为 7,567 星、5,967 星、3,324 星） |
| 许可证据 | 三者均为标准 MIT License（分别为 Copyright (c) 2018 Oleksandr Glushchenko、Copyright (c) 2023 MarkEdit.app、Copyright (c) 2024 Xi Nai Lai），GitHub API `license.spdx_id` 均为 `MIT`。 |
| 可借鉴机制 | `fsnotes` 与 `MarkEdit` 验证了 macOS 原生应用直接读写普通本地 `.md` 文件的透明存储与排版体验；`Sidekick` 展示了在纯 SwiftUI 原生界面中围绕用户选定的本地材料流式对话并附带原文引用的交互组织。 |
| 复用边界 | 三者均为 MIT 许可，与本项目兼容；本项目主要参考其本地 `.md` 草稿管理与 SwiftUI 多栏交互结构，不整包引入 `Sidekick` 内置的本地推理引擎重依赖。 |

### 16. codexu/note-gen、lfnovo/open-notebook、MODSetter/SurfSense 与 tisfeng/Easydict（高星产品思路对照与协议边界）

| 项 | 内容 |
| --- | --- |
| 链接 | （1）https://github.com/codexu/note-gen ；中文说明：https://raw.githubusercontent.com/codexu/note-gen/HEAD/README.zh-CN.md ；许可：https://raw.githubusercontent.com/codexu/note-gen/HEAD/LICENSE <br>（2）https://github.com/lfnovo/open-notebook ；许可：https://raw.githubusercontent.com/lfnovo/open-notebook/HEAD/LICENSE <br>（3）https://github.com/MODSetter/SurfSense ；许可：https://raw.githubusercontent.com/MODSetter/SurfSense/HEAD/LICENSE <br>（4）https://github.com/tisfeng/Easydict ；许可：https://raw.githubusercontent.com/tisfeng/Easydict/HEAD/LICENSE |
| 已读 | 四个仓库的 README、`LICENSE`、GitHub API 元数据与顶层源码构成（读取时分别为 12,997 星、41,825 星、16,827 星、15,272 星） |
| 许可证据 | `note-gen` 与 `Easydict` 均为 **GPL-3.0**；`open-notebook` 为 **MIT**；`SurfSense` 为 **Apache-2.0**。 |
| 关键取舍与边界 | 1. **`note-gen`（GPL-3.0，仅借鉴产品两阶段思想，零代码复用）**：其「先无负担记录碎片，再勾选相关记录用 AI 整理为本地 Markdown 文稿」的两阶段主线与本项目高度契合；但其实测语言构成为约 9.86 MB TypeScript（Next.js WebView）加 0.99 MB Rust（Tauri 壳），并非 macOS 原生 UI，且协议为 GPL-3.0。为保持纯正 SwiftUI 原生体验与 MIT 协议，**严禁复制或衍生其任何源码**。<br>2. **`Easydict`（GPL-3.0，零代码复用）**：虽为 macOS 原生划选取词标杆，但协议为 GPL-3.0，本项目采用 MIT 协议故不引用其源码。<br>3. **`open-notebook`（MIT）与 `SurfSense`（Apache-2.0）**：验证了「勾选素材、对话推演（A）、文档编辑（C）」的工作台交互，但二者后端依赖 Python 与容器化数据库，体量过重，仅作三栏交互对照而不引入其重后端。 |

## 立项文档结构所依据的规范

这些是文档怎么组织的依据，不是产品功能来源。

| 规范 | 链接 | 已读内容 | 在本项目中的用法 |
| --- | --- | --- | --- |
| GitHub Docs：About READMEs | https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes | 2026-11-10 阅读该页：README 应说明项目做什么、为何有用、如何开始、在哪里获得帮助、谁维护；较长文档不宜全部塞进 README；仓库内文件应使用相对链接。 | 根目录 README 只做入口，细节分到 `docs/`，文档之间用相对路径互链。 |
| GitHub Docs：贡献指南 | https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/setting-guidelines-for-repository-contributors | 2026-11-10 依据该页公开说明：可在仓库根、`docs/` 或 `.github/` 放置贡献指南，说明如何提交有用的修改，减少不合格贡献。 | 将人与 agent 的规则写在 [contributing.md](contributing.md)，不另建空的 `.github` 或 CI。 |
| Diátaxis | https://www.diataxis.fr/start-here/ | 2026-11-10 阅读 “Start here”：教程、操作指南、参考、解释四种文档应分开，避免在同一页里既讲原理又写操作步骤。 | 需求与解释、来源参考、里程碑验收（如何检查）分开存放。本阶段没有用户教程，因为还没有可运行产品。 |
| Choose a License：No License | https://choosealicense.com/no-permission/ | 2026-11-10 阅读该页：未附许可时，作品默认受版权保护，他人不能假定可以复制、分发或修改；作者也可在 README 中明确写「暂不提供许可」，以免被当成遗漏。 | M0 立项阶段依此标注许可待定；2026-11-11 用户已拍板采用 MIT License（同时继续对无许可的第三方仓库按该规则保持零代码复用）。 |
| 《通用数据保护条例》第 5 条 | 正式文本：https://eur-lex.europa.eu/eli/reg/2016/679/oj ；便于核对条文的转载：https://gdpr-info.eu/art-5-gdpr/ | 2026-11-10 阅读第 5 条原则：合法公正透明、目的限制、数据最小化、准确性、存储期限、完整性与保密、问责。 | 仅作为 [privacy.md](privacy.md) 的设计参考，**不构成本项目已符合 GDPR 的声明**，也不预先假定适用法域。 |

## 对 Coding-Rewind 的对照结论

- **捕获动作与心理模型**：与需求最接近的公开机制是「用户划选 → 一键留下选段 → 保留原文和来源 → 急着推进当前主线时先不切走开新对话（借鉴 `tangent` 的延迟分叉思路，但落到跨应用的近 2～3 天暂存池）」。`threadmark`、`Glasp`、`Superpower` 验证了选段留存与回链；`rewind-for-x` 验证了「本机保存 + 出处 + 可清空」，但其自动全量记时间线与本项目的「主观选段暂存」不同。
- **不强迫标题与标签**：在对照项目里并不普遍（如 AUI Bookmarks 保存时强制命名）。本项目坚持「一秒塞入」，标题、标签、批注只能是事后可选补充。
- **双端汇聚与纯 Swift 单主线底座**：2026-11-11 拍板采用 **macOS 原生 `Swift + SwiftUI / AppKit + SwiftData`** 与 **MIT License**。桌面端借鉴 `Maccy`（`.nonactivatingPanel` 不抢焦点浮窗与单文件 `SwiftData`）与 `CodeIsland`（纯 Swift 非阻塞 Antigravity Hook 桥接），网页端借鉴 `obsidian-clipper`（`coding-rewind://stash?...&silent=true` 静默 URL Scheme 投递），全链路共用同一 `Clip` 模型，避免把 WebView 与原生壳拼成胶水代码。
- **从静态归档走向 A+C 互动成文**：借鉴 `note-gen` 的「先碎片暂存、后勾选成文」两阶段逻辑，以及 `Sidekick`、`open-notebook` 与 `NotebookLM` 的「勾选若干卡片组成上下文追问 AI（场景 A）+ 对照卡片在旁写本地 `.md` 草稿（场景 C）」工作流，同时通过极薄本地 `stdio` MCP 反哺 Antigravity App 的 `Knowledge Work` 界面。
- **本地优先与许可红线**：本地存放、可导出、可删除是共同的隐私基线；对 GPL-3.0（`note-gen`、`Easydict`、`Bridgecontext`）、AGPL-3.0（`hypratia`）、Commons Clause（`bAInder`）及无许可仓库（`canvas-chat`）严格保持零代码复用，确保本项目 MIT 许可边界绝对干净。
