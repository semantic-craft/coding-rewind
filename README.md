# Coding-Rewind

本仓库是 **Coding-Rewind** 的产品规范与统一全栈实现，采用 [MIT License](LICENSE)。

## 这是什么

在使用独立桌面端 **Google Antigravity App 2.x** 或网页版 ChatGPT、Claude、Gemini 聊天时，经常会撞见接下来两三天马上要用、带来灵感的对话段落。当下正在推进主线任务，不想立刻切走新开对话分叉，存进重型笔记库太重，贴进系统备忘录又会丢掉提问语境且难以继续追问成文。

**Coding-Rewind** 是介于系统备忘录与正式笔记库之间的近期灵感暂存、AI 脉络定锚与互动成文工具。它跨 **Antigravity App 2.x 与主流网页版 AI 聊天** 顺手暂存好段落，由云端自动补齐会话脉络摘要并原样锁住选中原文，在近 72 小时热窗口里用非激活毛玻璃浮窗随时回看，勾选卡片即可一键拉起 Antigravity 新对话继续推演或对照写稿。

立项需求正本来自用户 t4624u 于 2026-11-10 的记录：

> 待开发工具构想：针对与 AI 聊天过程中好用的高质量对话片段、提示词或思路，开发一个支持收集、归档与便捷回顾的功能/工具，把好用的片段系统存起来复用。

用户于 2026-11-10 在本仓库会话中的一手口述补充如下，完整原话见 [docs/requirements.md](docs/requirements.md)：

> 主要就是很多东西我觉得对我来讲，比如这个东西非常好，接下来马上就要用了，但是我又不想马上开个新对话，差不多是这么一个东西。比如说它有些段落 然后某些段落呢，我觉得挺好的，接下来想用但一直又不知道放哪，但我很确定要用，所以我就是想要存起来，就是这么一个东西。

## 架构概览与组件构成

项目拒绝双数据库双向同步与半原生半网页胶水层，围绕阿里云轻量应用服务器上的单实例原版 `usememos/memos` 构建极薄边缘端：

- **单一事实源后端 `deploy/vps/`**，直接运行官方固定版本 `neosmemo/memos:26.11.0` 容器承接 `/api/memos` REST 存储与原生 Streamable HTTP `/mcp` 服务，旁挂约百行纯 Python 3 标准库编写的幂等语境增强器 `rewind-enricher`，结合前文 4 轮对话生成标题、会话主题、脉络摘要与关键词引用头，100% 保留用户选中原文不改动。
- **macOS 原生状态栏与毛玻璃浮窗 `Sources/CodingRewindApp/` 与 `Sources/CodingRewindCore/`**，基于 Swift 6、AppKit（`NSStatusItem` + `NSMenu` + 主菜单）与 SwiftUI 实现轻量状态栏与悬浮面板，吸收 MIT 项目 `p0deje/Maccy`、`tisfeng/SelectedTextKit` 与 `wxtsky/CodeIsland` 的成熟做法，支持 `⌃⌥S` 零抢焦点捕获、`⌃⌥R` 唤出 72 小时热流浮窗、离线队列幂等重放，以及 `⌘Return` 通过 `agentapi new-conversation` 把勾选卡片送入 Antigravity 开聊。
- **Antigravity 2.x 官方插件与钩子 `Sources/AntigravityBridge/` 与 `scripts/memos-mcp-bridge.sh`**，非阻塞 `PostInvocation` 与 `Stop` 钩子记录最新提问及最近 4 轮对话上下文，钥匙串桥接脚本在不落盘明文令牌的前提下将原生 `/mcp` 暴露给 Antigravity 的 `/rewind` 技能与 `Knowledge Work` 写作界面。
- **网页端薄剪藏扩展 `extensions/web-clipper/`**，Manifest V3 无依赖扩展，吸收 MIT 项目 `mem0ai/mem0-chrome-extension`、`revivalstack/ai-chat-exporter` 与 `pionxzh/chatgpt-exporter` 经验，在 ChatGPT、Claude 与 Gemini 页面提取选区 Markdown 与前序 4 轮对话后后台直连 Memos API，右上角展示 2.2 秒轻提示，不弹自定义协议确认框也不抢焦点。

## 快速验证与构建

在仓库任意目录运行统一门禁脚本执行静态边界检查、Swift 测试、VPS 增强器测试、网页扩展测试、脚本语法检查与图标规格校验：

```bash
./scripts/check
```

构建并签名校验原生菜单栏应用包 `.build/CodingRewind.app`：

```bash
./scripts/build-app-bundle.sh
```

工程约束与排障记录见根目录 [AGENTS.md](AGENTS.md) 与 [lessons.md](lessons.md)。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 代码导航、Memos 线级契约不变量、环境变量与 QA 隔离规则 |
| [lessons.md](lessons.md) | 已核实的工程教训、修复证据与自动化验证点 |
| [docs/requirements.md](docs/requirements.md) | 需求正本、用户一手决定、MVP 范围与非目标 |
| [docs/architecture.md](docs/architecture.md) | 统一 Memos 主干架构、数据契约、离线韧性与宿主集成细节 |
| [docs/sources.md](docs/sources.md) | 复用与参考的 MIT 上游清单及 GPL/AGPL/无许可排除依据 |
| [docs/privacy.md](docs/privacy.md) | 原文保护边界、钥匙串凭据隔离、数据导出与删除 |
| [docs/milestones.md](docs/milestones.md) | M0 至 M4 里程碑定义与可执行验收方法 |
| [docs/contributing.md](docs/contributing.md) | 人与 agent 协作准则 |

## 核心产品边界

1. **聚焦 72 小时热窗口**，服务近两三天马上要用的高质量对话片段，保存时不打断当前对话、不强迫当场开新会话、不要求手填标题或标签。
2. **双端无感采集与脉络保真**，同时覆盖独立桌面端 `com.google.antigravity` 与 ChatGPT、Claude、Gemini 网页端，自动附带原问题、出处链接与近期轮次脉络。
3. **交回主力宿主推演与成文**，浮窗只做毫秒级速览、检索筛选与多选勾选，长对话追问与对照写稿直接交给用户主力使用的 Antigravity App 2.x 及原生 `/mcp` 工具完成，不重复造本地富文本编辑器。
4. **明确不做**，不做默认全量聊天自动采集，不做相关时主动弹窗打扰，不在配置文件写入明文密钥，也不引入任何 GPL、AGPL、Commons Clause 或无许可代码。
