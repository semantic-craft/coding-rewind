# Coding-Rewind

本仓库是 **Coding-Rewind** 的产品规范与统一全栈实现，采用 [MIT License](LICENSE)。

当前候选版为 `v0.3.0-rc.1`。下载入口为 [GitHub Releases](https://github.com/semantic-craft/coding-rewind/releases)。macOS 包面向 Apple Silicon，最低 macOS 14，采用 ad-hoc 签名，尚未经过 Developer ID 签名或 Apple 公证。公开包不包含个人 Memos 地址、令牌或 1Password 配置。首次使用需配置自己的 Memos 服务并授予辅助功能权限。

当前版本仍有 Antigravity 会话归属、Chrome 扩展生命周期、多卡接聊和引用成文的实机覆盖待完成，见 [issue #14](https://github.com/semantic-craft/coding-rewind/issues/14)。当前状态见 [开发进度](progress/index.html)。修复和后续验收遵循 [代码质量标准](docs/code-quality.md)。

## 这是什么

在使用独立桌面端 **Google Antigravity App 2.x、ChatGPT、Gemini** 或网页版 ChatGPT、Claude、Gemini 聊天时，经常会撞见接下来两三天马上要用、带来灵感的对话段落。当下正在推进主线任务，不想立刻切走新开对话分叉，存进重型笔记库太重，贴进系统备忘录又会丢掉提问语境且难以继续追问成文。

**Coding-Rewind** 是介于系统备忘录与正式笔记库之间的近期灵感暂存、AI 脉络定锚与互动成文工具。它跨 **Antigravity App 2.x 与主流网页版 AI 聊天** 顺手暂存好段落，由云端自动补齐会话脉络摘要并原样锁住选中原文，在近 72 小时热窗口里用非激活毛玻璃浮窗随时回看。勾选卡片后可在 Antigravity 或 Codex 新建会话并发送完整上下文，继续推演或对照写稿。

立项需求正本来自用户 t4624u 于 2026-11-10 的记录：

> 待开发工具构想：针对与 AI 聊天过程中好用的高质量对话片段、提示词或思路，开发一个支持收集、归档与便捷回顾的功能/工具，把好用的片段系统存起来复用。

用户于 2026-11-10 在本仓库会话中的一手口述补充如下，完整原话见 [docs/requirements.md](docs/requirements.md)：

> 主要就是很多东西我觉得对我来讲，比如这个东西非常好，接下来马上就要用了，但是我又不想马上开个新对话，差不多是这么一个东西。比如说它有些段落 然后某些段落呢，我觉得挺好的，接下来想用但一直又不知道放哪，但我很确定要用，所以我就是想要存起来，就是这么一个东西。

## 架构概览与组件构成

项目拒绝双数据库双向同步与半原生半网页胶水层，围绕阿里云轻量应用服务器上的单实例原版 `usememos/memos` 构建极薄边缘端：

- **单一事实源后端 `deploy/vps/`**，直接运行官方固定版本 `neosmemo/memos:26.11.0` 容器承接 `/api/memos` REST 存储与原生 Streamable HTTP `/mcp` 服务，旁挂约百行纯 Python 3 标准库编写的幂等语境增强器 `rewind-enricher`，结合前文 4 轮对话生成标题、会话主题、脉络摘要与关键词引用头，100% 保留用户选中原文不改动。
- **macOS 原生状态栏与毛玻璃浮窗 `Sources/CodingRewindApp/` 与 `Sources/CodingRewindCore/`**，基于 Swift 6、AppKit（`NSStatusItem` + `NSMenu` + 主菜单）与 SwiftUI 实现轻量状态栏与悬浮面板，吸收 MIT 项目 `p0deje/Maccy`、`tisfeng/SelectedTextKit` 与 `wxtsky/CodeIsland` 的成熟做法，默认使用 `⌃⌥S` 捕获选段、`⌃⌥R` 唤出 72 小时热流浮窗，支持离线队列幂等重放。`⌘Return` 将勾选卡片交给浮窗选定的 Antigravity 或 Codex，接聊方式见下文。
- **Antigravity 2.x 上下文与官方插件**，桌面捕获从选区所属聊天页面确认会话编号，只读取该会话的官方 transcript，定位所选消息与对应提问；钥匙串桥接脚本在不落盘明文令牌的前提下将原生 `/mcp` 暴露给 Antigravity 的 `/rewind` 技能与 `Knowledge Work` 写作界面。
- **ChatGPT 与 Gemini App 剪藏**，选中文本后按 `⌃⌥S`，自动保存来源、私有会话链接、前序提问与截止选中消息的最多四个用户轮。通过当前窗口的辅助功能树和系统复制读取内容，不读取其他会话日志。回链使用应用自带的打开会话入口，完成后关闭本次打开的浏览器标签。Gemini 的回链读取目前支持默认浏览器为 Google Chrome。
- **网页端薄剪藏扩展 `extensions/web-clipper/`**，Manifest V3 无依赖扩展，吸收 MIT 项目 `mem0ai/mem0-chrome-extension`、`revivalstack/ai-chat-exporter` 与 `pionxzh/chatgpt-exporter` 经验，在 ChatGPT、Claude 与 Gemini 页面提取选区 Markdown 与前序 4 轮对话后后台直连 Memos API，右上角展示 2.2 秒轻提示，不弹自定义协议确认框也不抢焦点。

## 在 Antigravity 接聊

先在应用菜单或设置中点击“安装或检查 Antigravity 插件”。安装器将 `coding-rewind-sidecar` 放入固定的应用数据目录，注册并启用 `coding-rewind/launcher`。Antigravity 管理该进程，并提供调用 `agentapi` 所需的运行环境。

在浮窗勾选卡片，按 `⌘Return` 或点击“在 Antigravity 开聊”。应用会打开 Antigravity，由 sidecar 新建会话并发送卡片原文、已有脉络和出处。收到会话编号后才显示成功，同时清除本次勾选。要再次使用同一张卡片，请重新勾选。

请求期间重复点击不会再建会话。进程中断或超时导致结果不明时，应用保留原请求编号，重启后查询该请求，不自动重发。收到明确的未知结果后，可先核对 Antigravity，再点击“已核对 Antigravity，结束本次请求”恢复。“开聊后归档”只在确认创建成功后执行，归档失败仍保留卡片供重试，也可点击“结束接聊，保留未归档卡片”。

新会话出现在 Antigravity 的 sidecar 专属项目中。当前官方接口能创建并发送，但没有已核实的按会话编号自动切换正文接口，因此应用只唤起 Antigravity，不猜测 deep link。点击新会话即可继续，无须粘贴或再次发送。

[官方 sidecar 文档](https://antigravity.google/docs/sidecars)说明宿主运行环境、项目配置和 `agentapi`。普通外部进程直接调用 CLI 不能替代 sidecar。交接请求和宿主事件的留存范围见 [隐私说明](docs/privacy.md#4-一键接聊的短期请求与宿主记录)。

## 在 Codex 接聊

安装并登录 Codex，在浮窗的接聊应用选择器中选择 **Codex**，勾选卡片后按 `⌘Return`。应用创建真实新会话，发送与 Antigravity 相同的卡片原文、已有脉络和出处，并打开该会话供继续追问，无须粘贴或再次发送。首次默认目标仍是 Antigravity，之后保存所选应用。应用菜单与状态菜单也提供两种宿主的明确开聊动作。

Codex 接聊使用应用自带的官方 CLI，不需要安装 Antigravity 插件。找不到捆绑 CLI 时会检查 `~/.local/bin/codex`，开发或排障时可用绝对路径环境变量 `CODING_REWIND_CODEX_BIN` 指定。模型和审批沿用 Codex 自己的配置，新会话的工作目录为当前用户主目录。

应用先把提示词交给 Codex 的新会话队列，再唤醒 Codex 运行。只有从真实会话读回首轮用户消息、确认请求编号和完整原文字节一致后，才显示已发送并按已保存的“开聊后归档”意图归档。排队回执或打开应用本身不算发送成功。

已有请求优先于新的目标、选卡与归档偏好。等待超时或进程中断后不会自动重发，也不会归档。先到对应宿主核对，再使用浮窗中的结束请求动作。归档失败时再次点击开聊只处理剩余卡片。会话已发送而打开失败时，可点击 **打开已发送的 Codex 会话** 重试打开同一会话。

## 快速验证与构建

需要 Swift 6.2 或更新版本。在仓库根目录运行统一门禁脚本执行静态边界检查、Swift 测试、VPS 增强器测试、网页扩展测试、脚本语法检查与图标规格校验：

```bash
./scripts/check
```

使用 release 配置构建并校验 ad-hoc 签名的原生菜单栏应用包 `.build/CodingRewind.app`：

```bash
./scripts/build-app-bundle.sh
```

安装或升级时使用 `ditto` 复制应用包，以保留签名元数据。个人开发包可能含 `DeveloperCredentials.plist`，不要作为公开下载附件。

本机开发可显式构建一个使用 1Password CLI 的启动包。构建参数只传非密钥引用，真实引用仅留在本机产物，不提交到仓库：

```bash
CODING_REWIND_MEMOS_TOKEN_REFERENCE='op://vault/item/password' \
  ./scripts/build-app-bundle.sh
```

该模式仍以原生程序作为应用入口，启动时通过 `op read` 读取包内配置的凭据引用，再将令牌传入应用的内存配置。双击已安装的包也走同一入口，无须设置全局环境变量。构建时发现 `op` 的绝对路径，也可用 `CODING_REWIND_OP_BIN` 显式指定。令牌不写配置或钥匙串；认证失败、空值、含空白或未解析的引用会阻止初始化，不回退到个人钥匙串。未设置引用的常规构建保持已有凭据方式。原生入口保留应用签名与用途说明的绑定，用于向系统申请 CodingRewind 的浏览器自动化授权。

设置中的两个快捷键可录制含 ⌃、⌥ 或 ⌘ 的组合，包括 Hyper（⌃⌥⇧⌘），也支持 F 功能键。修改立即保存生效，清空即关闭，重启保持；恢复默认也会检查冲突。系统占用、应用动作重键和菜单常用键会被阻止，注册失败保留配置并显示“未生效”，可释放冲突后重试。Carbon 独占注册可检测其他独占绑定；系统不会报告所有应用的共享绑定。菜单与浮窗提示随配置更新。

快捷键采用固定版本 [KeyboardShortcuts 3.1.0](Vendor/KeyboardShortcuts/README.md)。`./scripts/check` 同时运行应用与库回归；打包会复制库的本地化资源。隔离验收构建用 `CODING_REWIND_QA=1 ./scripts/build-app-bundle.sh`，运行时也须设置 `CODING_REWIND_QA=1` 与独立 `CODING_REWIND_DATA_DIR`，快捷键偏好按数据目录落入稳定独立域，不访问日常快捷键配置。

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
2. **双端无感采集与脉络保真**，同时覆盖 Antigravity、ChatGPT、Gemini 桌面端与 ChatGPT、Claude、Gemini 网页端，自动附带原问题、出处链接与近期轮次脉络。
3. **交回主力宿主推演与成文**，浮窗只做毫秒级速览、检索筛选与多选勾选，长对话追问与对照写稿直接交给用户主力使用的 Antigravity App 2.x 或 Codex 完成，Antigravity 继续提供原生 `/mcp` 工具，不重复造本地富文本编辑器。
4. **明确不做**，不做默认全量聊天自动采集，不做相关时主动弹窗打扰，不在配置文件写入明文密钥，也不引入任何 GPL、AGPL、Commons Clause 或无许可代码。

## 桌面入口与设置

应用默认显示 Dock 图标，点击图标可重新打开速览浮窗。菜单栏、浮窗齿轮和 `⌘,` 都打开同一个设置窗口。设置分为通用、连接、快捷键、集成与权限；Dock 与快捷键修改立即保存，连接配置单独保存。

如果菜单栏图标消失，先从 Finder 打开应用，再进入“设置 → 通用 → 打开系统菜单栏设置”。在系统的“允许在菜单栏中显示”列表开启 CodingRewind。应用不会反复覆盖系统的隐藏选择。

连接页会标明由启动环境管理的地址或令牌，并禁用这些字段的编辑。保存反馈保留在当前页；立即同步的反馈显示在“最近操作”中。菜单中的“已配置”只表示地址有效，不代表服务已经连通。
