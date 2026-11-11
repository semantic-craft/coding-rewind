# Coding-Rewind

本仓库是 **Coding-Rewind** 的立项规范与 v0.1 纯 Swift 原生 macOS 工程实现，采用 [MIT License](LICENSE)。

## 这是什么

在使用桌面端 Coding Agent（主力为独立桌面应用 **Google Antigravity App 2.x**）或网页版 AI 聊天时，经常会撞见一些「接下来两三天马上要用、带来灵感」的对话段落：当下正忙于当前主线，**不想立刻开新对话分叉**，存进正式 Notes 太重，贴进系统备忘录又丢失语境且无法继续互动。

**Coding-Rewind** 要做的是一个介于系统备忘录与正式笔记库之间的**近期灵感暂存、回放与互动成文工具**：跨 **Antigravity App 2.x 与网页版聊天**顺手暂存好段落，在近两三天的热窗口里便捷回顾，并在写东西、深入思考时围绕这些片段继续对话推演或对照成文。

立项需求正本（用户 t4624u，2026-11-10）：

> 待开发工具构想：针对与 AI 聊天过程中好用的高质量对话片段、提示词或思路，开发一个支持收集、归档与便捷回顾的功能/工具，把好用的片段系统存起来复用。

一手场景补充（用户直述，2026-11-10，完整原话见 [docs/requirements.md](docs/requirements.md)）：

> 主要就是很多东西我觉得对我来讲，比如这个东西非常好，接下来马上就要用了，但是我又不想马上开个新对话，差不多是这么一个东西。比如说它有些段落 然后某些段落呢，我觉得挺好的，接下来想用但一直又不知道放哪，但我很确定要用，所以我就是想要存起来，就是这么一个东西。

项目名先用 **Coding-Rewind**。用户已表示可以接受备选名称，但在另作决定前以此名为准。

## 当前状态与构建方式

- 当前处于 v0.1 第一刀实现与验收阶段（覆盖 M1 拍板及 M2 至 M4 本机核心验收闭环）。
- 公开仓库与本机工作目录：`https://github.com/semantic-craft/coding-rewind`（本机工作路径 `~/Projects/coding-rewind/`）。
- 软件许可：[MIT License](LICENSE)（2026-11-11 用户拍板落盘）。
- 技术底座与界面骨架（2026-11-11 决定）：零第三方依赖的 **Swift 6 原生工程（`SwiftUI + AppKit + SQLite3 WAL/FTS5 + NaturalLanguage`）**，采用**方案 2（非激活 HUD 速览浮窗加递进写作舱，右上角附可选长对话侧栏开关）**，包含 `CodingRewindCore`、`CodingRewindApp`、`coding-rewind-hook`（`AntigravityBridge`）与 `rewind-mcp`（`RewindMCP`）四个 Target。
- 构建与测试命令：运行 `swift test` 执行离线行为测试与子进程集成测试，运行 `bash scripts/build-app-bundle.sh` 生成 `.build/CodingRewind.app`。

## 文档怎么读

入口就是这份 README。更长的说明按主题分开放在 `docs/`，避免把所有内容塞进一个文件。这种拆分参考了 [GitHub Docs：About READMEs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)（README 说明项目是什么、为何有用、如何开始；较长文档另置），以及 [Diátaxis](https://www.diataxis.fr/start-here/)（把「说明 / 参考 / 如何做」分开，不在同一页里混写）。

| 文档 | 内容 |
| --- | --- |
| [docs/requirements.md](docs/requirements.md) | 需求正本、已定方向、MVP、非目标；区分决定 / 建议 / 待决 |
| [docs/sources.md](docs/sources.md) | 指定来源与少量相关项目、许可与可复用边界、立项规范 |
| [docs/architecture.md](docs/architecture.md) | 纯 Swift 原生单主线架构、数据契约与仍待决边界 |
| [docs/privacy.md](docs/privacy.md) | 数据生命周期，以及导出、删除原则 |
| [docs/milestones.md](docs/milestones.md) | 分期目标与可执行验收 |
| [docs/contributing.md](docs/contributing.md) | 人与 agent 的协作规则 |

## 已确认的核心需求与产品方向（摘要）

以下综合 2026-11-10 用户一手直述（决定）与 2026-11-09 讨论方向（转述）；完整分级与出处见 [docs/requirements.md](docs/requirements.md)：

1. **近期热窗口暂存（2～3 天尺度）**：解决「马上要用、不想进重型 Notes、放系统备忘录又不好用」的中间态，捕获时**不强迫当场开新对话**，也不打断当前主线。
2. **围绕 Antigravity App 2.x + 网页版双场景设计**：桌面端针对独立应用 **Google Antigravity App 2.x**（`com.google.antigravity`，非 VS Code 分支的 IDE 版），同时覆盖网页版 AI 聊天。
3. **选段一键留存，不强迫标题或标签，保留原问题、原文与出处**。
4. **服务于写作与思考的「A + C」互动消费**：回顾时不仅能浏览和自然语言找回，还能 **（A）勾选暂存片段接着向 AI 追问推演**，以及 **（C）一边对照暂存片段一边写草稿、由 AI 辅助整理成文**。
5. **纯 macOS 原生 UI 与两步落地顺序**：主程序采用纯 Swift 原生界面（参考 `Maccy`、`CodeIsland` 等高星 MIT 项目，吸收 `note-gen` 先记录后成文的两阶段思路而不引入其 GPL 代码）；MVP 第一刀先跑通原生主程序与 Antigravity 2.x Hook 及 MCP 联动，第二刀接入支持 ChatGPT、Claude、Gemini 的浏览器薄扩展。

「自动暂存」和「相关时提示」只是候选，不是已定功能。更完整的分级见 [docs/requirements.md](docs/requirements.md)。

## 明确未做

v0.1 不做默认全量自动采集、相关时主动弹窗提示、未授权外发对话原文、复杂 CI 或制作 Page。浏览器端划选扩展排在 v0.2（v0.1 原生主程序已内置 `coding-rewind://stash?...&silent=true` 协议接收器）。
