# Coding-Rewind

本仓库是 **Coding-Rewind** 的产品规范与统一全栈实现，采用 [MIT License](LICENSE)。

当前发布版本为 `v0.7.0`，同步更新 macOS 桌面应用与 Chrome 网页扩展，包含 DSH（DeepSeek Harness）双向集成、安全加固与精简状态栏菜单、来源开头留底与 W3C `#:~:text=` 精确锚点、浮窗停靠式“脉络”抽屉与可编辑接聊草稿框、云端直连 DeepSeek 官方 `deepseek-flash`（`DeepSeek-V4.1-Flash`）自动摘要、应用内自动更新、中英双语界面、全网划词暂存胶囊、默认 `⌃⌥⇧⌘S`（`Hyper+S`）捕获快捷键、浮窗片段归档与删除管理，以及单二进制 `coding-rewind`（CLI + 7 工具读写领域 MCP 服务与权限开关）。下载入口为 [GitHub Releases](https://github.com/semantic-craft/coding-rewind/releases)。macOS 包面向 Apple Silicon，最低 macOS 14。公开包不包含个人 Memos 地址、令牌或 1Password 配置。桌面端无须配置即可在本机暂存片段并开始对话，首次桌面捕获需授予辅助功能权限；如需跨设备同步、网页剪藏持久化与自动 AI 摘要，可在“云端同步”按需配置自托管 Memos 服务。

当前版本仍有 Antigravity 会话归属、Chrome 扩展生命周期、多卡接聊和引用成文的实机覆盖待完成，见 [issue #14](https://github.com/semantic-craft/coding-rewind/issues/14)。当前状态见 [开发进度](progress/index.html)。修复和后续验收遵循 [代码质量标准](docs/code-quality.md)。

桌面应用版本为 0.7.0，build 10；Chrome 扩展显示版本为 0.7.0，内部版本为 0.7.0.0。扩展继续通过解压文件加载，未发布到 Chrome 应用商店。升级时解压新版扩展包，用其中的文件覆盖原扩展目录，在 `chrome://extensions/` 中点击“重新加载”，再刷新已打开的聊天网页。沿用原目录可保留扩展 ID 与已保存的配置；不要移除后重新添加。

## 这是什么

在使用独立桌面端 **Google Antigravity App 2.x、DSH（DeepSeek Harness）、ChatGPT、Gemini** 或网页版 ChatGPT、Claude、Gemini 聊天时，经常会撞见接下来两三天马上要用、带来灵感的对话段落。当下正在推进主线任务，不想立刻切走新开对话分叉，存进重型笔记库太重，贴进系统备忘录又会丢掉提问语境且难以继续追问成文。

**Coding-Rewind** 是介于系统备忘录与正式笔记库之间的近期灵感暂存、AI 脉络定锚与互动成文工具。它跨 **Antigravity App 2.x、DSH 桌面端与主流网页版 AI 聊天** 顺手暂存好段落，由云端自动补齐会话脉络摘要并原样锁住选中原文，在近 72 小时热窗口里用非激活毛玻璃浮窗随时回看。勾选卡片后可在 Antigravity 或 DSH 展开接聊草稿并发送或预填卡片标识与完整上下文，继续推演或对照写稿，还可在读写权限下由宿主 AI 将结论笔记挂回原卡片或暂存新提纲回流至浮窗。

立项需求正本来自用户 t4624u 于 2026-11-10 的记录：

> 待开发工具构想：针对与 AI 聊天过程中好用的高质量对话片段、提示词或思路，开发一个支持收集、归档与便捷回顾的功能/工具，把好用的片段系统存起来复用。

用户于 2026-11-10 在本仓库会话中的一手口述补充如下，完整原话见 [docs/requirements.md](docs/requirements.md)：

> 主要就是很多东西我觉得对我来讲，比如这个东西非常好，接下来马上就要用了，但是我又不想马上开个新对话，差不多是这么一个东西。比如说它有些段落 然后某些段落呢，我觉得挺好的，接下来想用但一直又不知道放哪，但我很确定要用，所以我就是想要存起来，就是这么一个东西。

## 架构概览与组件构成

项目拒绝双数据库双向同步与半原生半网页胶水层，围绕阿里云轻量应用服务器上的单实例原版 `usememos/memos` 构建极薄边缘端：

- **单一事实源后端 `deploy/vps/`**，直接运行官方固定版本 `neosmemo/memos:26.11.0` 容器承接 `/api/memos` REST 存储，旁挂约百行纯 Python 3 标准库编写的幂等语境增强器 `rewind-enricher`，结合前文 4 轮对话生成标题、会话主题、脉络摘要与关键词引用头，100% 保留用户选中原文不改动。
- **macOS 原生状态栏、毛玻璃浮窗与三栏资料库 `Sources/CodingRewindApp/` 与 `Sources/CodingRewindCore/`**，基于 Swift 6、AppKit（`NSStatusItem` + `NSMenu` + 主菜单）与 SwiftUI 实现轻量状态栏、悬浮面板与三栏式 **Coding Rewind 资料库**窗口（`⌘0` 打开资料库 / Open Library 或点击 Dock 图标呼出，支持 `⌥1` Bento 卡片墙与 `⌥2` 会话时间轴视图切换、未落位收件箱快速分拣与右侧持久出处检视栏），吸收 MIT 项目 `p0deje/Maccy`、`usememos/memos`、`raycast/extensions`、`GaimsDevSoftware/linuxpop`、`tisfeng/SelectedTextKit` 与 `wxtsky/CodeIsland` 的成熟做法，在 Antigravity、ChatGPT 与 Gemini 桌面端划选对话正文时自动在选区附近弹出非激活“暂存”胶囊，在 DSH 桌面端由轻量插件在选区下方渲染闭合 Shadow DOM“暂存”胶囊，默认使用 `⌃⌥⇧⌘S`（`Hyper+S`）捕获选段、`⌃⌥R` 唤出 72 小时热流浮窗，支持离线队列幂等重放。浮窗内置停靠式“脉络”预览抽屉（点击卡片 `脉络` 按钮或按 `⌘I` 展开，三级 `Esc` 逐层收起），原地查看完整选中原文、会话或网页开头留底、紧邻提问、近期轮次与 AI 笔记；按来源平台诚实提供网页直达跳转（含失败反馈）、DSH 原会话直达跳转（未就绪时回退复制会话 ID）与 Antigravity 会话 ID 一键复制/唤醒，支持单条或批量归档（`⌘E`）与删除（`⌘⌫` 底部行内确认，`⌥⌘⌫` 或按住 `Option` 点击直接删除），`⌘Return` 将勾选卡片连同卡片 ID 交给浮窗选定的 Antigravity 或 DSH 并支持推演后闭环回写，接聊方式见下文。
- **DSH（DeepSeek Harness）零依赖桌面插件 `dsh-plugin/coding-rewind-dsh/`**，随应用包分发并在安装或修复时暂存至 `~/Library/Application Support/CodingRewind/dsh-plugin/coding-rewind-dsh/`，通过 `dsh plugin --profile desktop add` 接入 `~/.dsh/profiles/desktop`，支持从 DSH 聊天选区下方一键暂存（保留代码块、会话 ID、首轮开场提问与近 4 轮上下文，`#source/dsh`）、在浮窗一键回跳原 DSH 会话，以及将浮窗草稿追加预填进 DSH 当前或最近工作区的空白新会话输入框（不自动发送），全程不接触 Memos 凭据。
- **单二进制 Agent CLI 与内嵌 MCP `Sources/CodingRewindCLI/`**，应用包内嵌并同步安装至固定路径 `~/Library/Application Support/CodingRewind/bin/coding-rewind`，与桌面端共用 `CodingRewindCore` 查询与写入层、凭据解析及 `hot_cache.json`/`outbox.jsonl`/`local_notes.json` 离线与本机回退，既提供 `list`、`search`、`get`、`create`、`update`、`note`、`archive`、`delete` 八个命令行子命令，也通过 `coding-rewind mcp` 提供受只读/读写权限门控的 7 个高信噪比领域工具（`list_snippets`、`search_snippets`、`get_snippet`、`archive_snippet`、`create_snippet`、`update_snippet_metadata`、`append_snippet_note`）标准 `stdio` MCP 服务（绝不向 Agent MCP 暴露物理删除工具），默认聚焦近 72 小时未归档片段并支持按需查询 `>72h` 历史与 `#rewind/synthesized` 已归档片段。
- **Antigravity 2.x 上下文与官方插件**，桌面捕获从选区所属聊天页面（支持 `http://127.0.0.1:<port>/c/<uuid>` 与 `https://127.0.0.1/c/<uuid>`）确认会话编号，只读取该会话的官方 transcript，提取会话 ID、整个会话首轮开场提问（`Session Opening`）、紧邻提问与最近 4 轮对话；插件安装器向 `~/.gemini/config/plugins/coding-rewind/` 写入 `plugin.json`、`coding-rewind/launcher` sidecar 配置与引导调用 `coding-rewind` 领域工具的 `/rewind` 技能。
- **ChatGPT 与 Gemini App 剪藏**，在 ChatGPT 与 Gemini 桌面端选中对话文本后点击选区上方的“暂存”胶囊，或按 `⌃⌥⇧⌘S`（`Hyper+S`），自动保存来源、私有会话链接、会话首轮开场提问（窗口无前序折叠缺口时）、紧邻提问与截止选中消息的最多四个用户轮。通过当前窗口的辅助功能树和系统复制读取内容，不读取其他会话日志。回链使用应用自带的打开会话入口，完成后关闭本次打开的浏览器标签。Gemini 的回链读取目前支持默认浏览器为 Google Chrome。
- **网页端薄剪藏扩展 `extensions/web-clipper/`**，Manifest V3 无依赖扩展，吸收 MIT 项目 `mem0ai/mem0-chrome-extension`、`revivalstack/ai-chat-exporter`、`pionxzh/chatgpt-exporter`、`obsidianmd/obsidian-clipper`、`crimx/ext-saladict`、`floating-ui/floating-ui`、`kepano/defuddle`、`mixmark-io/turndown` 与 `ChatGPTBox-dev/chatGPTBox` 经验，在任意 `http(s)` 网页及 ChatGPT、Claude、Gemini 页面支持选区就近的单动作“暂存”胶囊（含手势门控、可编辑区避让、生效范围与排除域名设置）、右键菜单及 `⌃⌥⇧⌘S`（`Hyper+S`）或 `Alt+Shift+S` 快捷键，按需提取去行号代码块与富文本 Markdown（聊天页附带会话 ID、首轮开场提问及前序 4 轮对话；普通网页提取标题、导语及开头数行正文 `Page Lead`，并生成 W3C `#:~:text=...` 精确回跳原句高亮链接）后后台直连 Memos API，胶囊内原位切换保存反馈或右上角展示 2.2 秒轻提示，不弹自定义协议确认框也不抢焦点。

## 无选区时暂存

- **桌面。** 从菜单栏打开「快速暂存…」，或在 Coding Rewind 中按 `⌘N`。可直接输入想法、粘贴代码或链接。用「选择文件…」保存本机文件，用「粘贴截图」保存剪贴板里的 PNG 或 TIFF。单个原件最大 8 MiB。图片 OCR、PDF 的文字层和 UTF-8 文件文本可用于检索。在资料库或速览的「脉络」中点「存储原件…」还原原始文件。
- **Chrome。** 在网页空白处右键，可保存页面链接，也可保存网页正文。正文保留可见的段落和代码，较长内容会截断并提示。保存 AI 对话仍用划词暂存。
- **Git。** 在仓库里将想保存的文本传入 CLI。下面的命令验证提交中的文件及行号，生成固定在该提交上的 GitHub 或 GitLab 链接。远端打开链接需要提交已经推送。

```sh
git show HEAD:Sources/Worker.swift | sed -n '42,57p' |
  coding-rewind create --stdin --git-file Sources/Worker.swift --git-lines 42-57
```

`--git-file` 相对于仓库根目录。传入 `--git-root` 可指定另一个检出目录。传入 `--git-commit` 可替换默认的 HEAD，参数须为完整提交 ID。

## 在 Antigravity 接聊

在“设置 → 插件与权限”中点击 Antigravity 分区的“安装或修复插件”。安装器将 `coding-rewind-sidecar` 与 `coding-rewind` 放入固定的 `~/Library/Application Support/CodingRewind/bin/` 目录，注册并启用 `coding-rewind/launcher`。Antigravity 管理该 sidecar 进程，并提供调用 `agentapi` 所需的运行环境。

在浮窗勾选片段，将对话应用选为 Antigravity，按 `⌘Return` 或点击“开始对话”，浮窗会先展开可编辑的接聊草稿框（按 `Esc` 可返回片段列表），预填每张卡片的标识（中文 `- 卡片 ID`、英文 `- Clip ID`）、片段原文、已有对话上下文和来源；当 AI 接入权限处于读写模式（`read_write`）时，提示词末尾还会引导宿主 AI 在整理推演后按需调用 `append_snippet_note` 将结论挂回原卡片，或调用 `create_snippet` 将新生成的提纲草稿暂存回浮窗（只读模式下省略该回写提示）。在草稿框自由增删指令后，按 `⌘Return` 或点击主按钮“复制并唤醒 Antigravity”即可将修改后的文本复制到剪贴板并唤醒 Antigravity 粘贴发送；若希望直接自动建会话，也可点击草稿框旁的“直接新建对话”，由 sidecar 创建新会话并在收到会话编号后显示成功、清除本次勾选。

请求期间重复点击不会再建会话。进程中断或超时导致结果不明时，应用保留原请求编号，重启后查询该请求，不自动重发。收到明确的未知结果后，可先核对 Antigravity，再点击“已检查 Antigravity，清除待确认请求”恢复。“发送后归档”只在确认创建成功后执行，归档失败仍保留片段供重试，也可点击“暂不归档，保留片段”。

新会话出现在 Antigravity 的 sidecar 专属项目中。当前官方接口能创建并发送，但没有已核实的按会话编号自动切换正文接口，因此应用只唤起 Antigravity，不猜测 deep link。点击新会话即可继续，无须粘贴或再次发送。

[官方 sidecar 文档](https://antigravity.google/docs/sidecars)说明宿主运行环境、项目配置和 `agentapi`。普通外部进程直接调用 CLI 不能替代 sidecar。交接请求和宿主事件的留存范围见 [隐私说明](docs/privacy.md#4-一键接聊的短期请求与宿主记录)。

## 在 DSH 接聊

安装并打开 **DeepSeek Harness**（`com.deepseek.dsh`），在“设置 → 插件与权限”点击 DSH 分区的“安装或修复插件”，安装器会将零依赖插件 `coding-rewind-dsh` 暂存到 `~/Library/Application Support/CodingRewind/dsh-plugin/coding-rewind-dsh/` 并经 `dsh plugin --profile desktop add` 注册到 `~/.dsh/profiles/desktop`（首次安装或更新后请重启 DeepSeek Harness Desktop 使插件生效）。

在浮窗的对话应用选择器中选择 **DSH**，勾选片段后按 `⌘Return` 展开可编辑草稿框：选中 DSH 时主按钮（`⌘Return`）为 **填入 DSH 新会话**，插件自动定位 DSH 当前打开或最近使用的工作区（无可用工作区时回退默认工作区），复用其空白会话并以 `whenDraftExists: 'append'` 将草稿追加填入输入框（**不自动发送**，也不覆盖未发草稿），随后激活 DeepSeek Harness 窗口供选择模型、模式并手动回车发送；次按钮保留 **复制并唤醒 DSH** 作为未装插件时的兜底。首次默认目标仍是 Antigravity，若旧配置存有 `"codex"` 启动时自动平滑迁移为 `"dsh"`。

在 DSH 聊天正文划选文本时，选区下方（避让 DSH 原生顶部引用浮层）自动弹出闭合 Shadow DOM“暂存”胶囊，也可按 `⌃⌥⇧⌘S`（`Hyper+S`）捕获选区并由插件快照补齐会话 ID、首轮开场提问与近 4 轮对话上下文（`#source/dsh`）。在浮窗点击 `#source/dsh` 卡片的 **打开原对话** 按钮可直接切回该 DSH 会话；若 DSH 未运行或插件未就绪，自动诚实回退为复制会话 ID 并提示。

已有请求优先于新的目标、片段选择与归档偏好。等待超时或进程中断后不会自动重发，也不会归档。勾选 **填入后归档** 时，仅在 DSH 插件确认草稿已成功写入输入框并返回会话编号后才归档所选卡片；归档失败可点击“重试归档”只处理剩余片段。开发或排障时可用绝对路径环境变量 `CODING_REWIND_DSH_BIN` 指定 `dsh` CLI，用 `CODING_REWIND_DSH_HOME` 隔离测试用 `DSH_HOME`。

## Coding Agent CLI 与内嵌 MCP 接入

打开已安装的 `CodingRewind.app` 或执行“安装或修复 Antigravity 插件”后，单二进制工具固定安装在 `~/Library/Application Support/CodingRewind/bin/coding-rewind`，应用自动更新时会原位刷新：

- **命令行直接调用（适合终端与 Coding Agent，共 8 个子命令）**：
  - `coding-rewind list [--window 72h|all|<N>h] [--status active|ready|pending|synthesized|all] [--source <platform>] [--limit 1..500] [--data-dir <path>] [--json]`
  - `coding-rewind search <query> [--window 72h|all|<N>h] [--status active|ready|pending|synthesized|all] [--source <platform>] [--limit 1..500] [--data-dir <path>] [--json]`
  - `coding-rewind get <id> [--no-context|--with-context] [--data-dir <path>] [--json]`（返回片段详情、对话上下文及按时间排序的 `notes`）
  - `coding-rewind create (--text <markdown> | --stdin) [--title <t>] [--session <s>] [--context <c>] [--keywords <k1,k2>] [--tag <tag>...] [--source <platform>] [--source-title <st>] [--source-url <u>] [--data-dir <path>] [--json]`（默认标记 `#source/agent`，来源标签支持 `antigravity|dsh|chatgpt|claude|gemini|macos|web|agent`）
  - `coding-rewind update <id> [--title <t>] [--session <s>] [--context <c>] [--keywords <k1,k2>] [--add-tag <tag>...] [--remove-tag <tag>...] [--archive | --unarchive] [--data-dir <path>] [--json]`（仅改写首行标签与顶部引用块元数据 `Title`、`Session`、`Context`、`Keywords`，100% 逐字节原样保留正文原文）
  - `coding-rewind note <id> (--text <markdown> | --stdin) [--author <name>] [--data-dir <path>] [--json]`（通过首行带 `<!-- rewind-note-v1 -->` 的 `PRIVATE` 评论追加 AI 笔记，与 `<!-- rewind-context-v1 -->` 严格隔离；未配置 Memos 的纯本机模式下存入 `<dataDir>/local_notes.json`）
  - `coding-rewind archive <id> [--data-dir <path>] [--json]`
  - `coding-rewind delete <id> [--data-dir <path>] [--json]`（严格保留给人工终端操作，绝不通过 MCP 向 AI 暴露；仅删除尚未同步的离线队列项或经云端 `DELETE` 确认的已同步片段，离线状态下拒绝删除已同步片段）
- **内嵌领域 MCP 服务（`coding-rewind mcp`）**：通过标准 `stdio` JSON-RPC 2.0 固定暴露 7 个领域工具：`list_snippets`、`search_snippets`、`get_snippet`、`archive_snippet`、`create_snippet`、`update_snippet_metadata`、`append_snippet_note`（替代通用 Memos 远端 41 个低信噪比工具与外部 Node 桥接进程，绝不向 Agent 暴露物理删除能力）。默认返回近 72 小时未归档片段；需要调阅更早历史或已归档片段时传入 `window: "all"` 或 `status: "synthesized"` / `"all"`。未配置云端或离线时自动回退读写本机 `hot_cache.json`、`outbox.jsonl` 与 `local_notes.json`。
- **只读与读写权限门控**：`<dataDir>/config.json` 持久化 `ai_access_mode`（`"read_only"` | `"read_write"`，默认 `"read_write"`，与 `memos_url` 互不覆盖且绝不存储任何令牌），可通过环境变量 `CODING_REWIND_AI_ACCESS=read_only|read_write` 覆盖（非空非法值按故障关闭降级为 `read_only`）。`coding-rewind mcp` 在每次工具调用时实时解析权限，切换设置无须重启 MCP 进程；处于 `read_only` 时立即拒绝全部 4 个写入工具（`create_snippet`、`update_snippet_metadata`、`append_snippet_note`、`archive_snippet`），仅放行 3 个读取工具。
- **跨宿主零明文接线**：可在桌面端“设置 → 插件与权限 → AI 接入与权限”中点击“复制 MCP 配置”一键粘贴至 Claude Desktop、Cursor、DSH、Antigravity 等客户端，也可在 `~/.config/agent-mcp/servers.json` 中注册后运行 `mcp-sync apply` 统一同步，无需在任何 JSON 配置文件写入访问令牌：

```json
{
  "coding-rewind": {
    "command": "${HOME}/Library/Application Support/CodingRewind/bin/coding-rewind",
    "args": ["mcp"]
  }
}
```

## 快速验证与构建

需要 Swift 6.2 或更新版本。在仓库根目录运行统一门禁脚本执行静态边界检查、Swift 测试、VPS 增强器测试、网页扩展测试、脚本语法检查与图标规格校验：

```bash
./scripts/check
```

使用 release 配置构建并校验 ad-hoc 签名的原生菜单栏应用包 `.build/CodingRewind.app`：

```bash
./scripts/build-app-bundle.sh
```

安装或升级时使用 `ditto` 复制应用包，以保留签名元数据。公开发布压缩包与 `SHA256SUMS.txt` 通过 `./scripts/package-release.sh` 生成，自动启用 `SKIP_DEVELOPER_CREDENTIALS=1` 排除本机开发凭据配置。

本机开发可显式构建一个使用 1Password CLI 的启动包。构建参数只传非密钥引用，真实引用仅留在本机产物，不提交到仓库：

```bash
CODING_REWIND_MEMOS_TOKEN_REFERENCE='op://vault/item/password' \
  ./scripts/build-app-bundle.sh
```

该模式仍以原生程序作为应用入口，启动时通过 `op read` 读取包内配置的凭据引用，并以 `0600` 权限幂等同步到 `~/Library/Application Support/CodingRewind/DeveloperCredentials.plist`，因此后续通过应用内自动更新替换为不含开发配置的公开版本后，仍能无缝沿用同一 1Password 引用。双击已安装的包也走同一入口，无须设置全局环境变量。构建时发现 `op` 的绝对路径，也可用 `CODING_REWIND_OP_BIN` 显式指定。令牌不写配置或钥匙串；认证失败、空值、含空白或未解析的引用会阻止初始化，不回退到个人钥匙串。未设置引用的常规构建保持已有凭据方式。原生入口保留应用签名与用途说明的绑定，用于向系统申请 CodingRewind 的浏览器自动化授权。

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
2. **双端无感采集与脉络保真**，同时覆盖 Antigravity、DSH（DeepSeek Harness）、ChatGPT、Gemini 桌面端与任意 `http(s)` 网页及 ChatGPT、Claude、Gemini 网页端，聊天页自动附带原问题、出处链接与近期轮次脉络，普通网页保留选段原文与出处链接。
3. **交回主力宿主推演与闭环回写**，浮窗只做毫秒级速览、检索筛选与多选勾选，长对话追问与对照写稿直接交给用户主力使用的 Antigravity App 2.x、DSH 等宿主完成，并由单二进制 `coding-rewind` 提供 8 个 CLI 子命令与受只读/读写权限门控的 7 个领域 MCP 工具（不暴露物理删除），让 AI 整理出的笔记与新提纲直接回流浮窗，不重复造本地富文本编辑器。
4. **明确不做**，不做默认全量聊天自动采集，不做相关时主动弹窗打扰，不在配置文件写入明文密钥，也不引入任何 GPL、AGPL、Commons Clause 或无许可代码。

## 桌面入口与设置

应用与 Chrome 扩展均支持 **跟随系统 / 简体中文 / English** 多语言显示，切换语言后菜单、片段浮窗、划词胶囊与设置窗口立即生效，无须重启应用；云端 `rewind-enricher` 默认按剪藏正文与对话脉络自动选择中文或英文摘要（可通过 `REWIND_SUMMARY_LANGUAGE` 固定为 `zh-Hans` 或 `en`），底层 Memos 标签与引用块字段名在各语言下保持统一。

应用默认显示 Dock 图标，在“设置 → 通用”提供显示语言、登录时自动打开（`SMAppService` 登录项后台静默启动，不自动弹出浮窗）、Dock 图标显示、系统菜单栏入口以及“选中文本时显示暂存胶囊”开关；在“设置 → 插件与权限”集中管理辅助功能授权、Antigravity 与 DSH 插件安装修复，以及“AI 接入与权限”（`AI Access & Permissions`）分区，展示本机 MCP 服务状态、只读与读写权限切换开关（立即写入 `<dataDir>/config.json` 的 `ai_access_mode`；若由环境变量 `CODING_REWIND_AI_ACCESS` 接管则自动禁用开关并标明来源）以及面向 Claude Desktop、Cursor、DSH、Antigravity 等宿主的一键“复制 MCP 配置”按钮；在“设置 → 关于”提供版本与构建号、MIT 许可证、仓库与更新日志链接、手动“检查更新”以及“自动检查更新”开关（后台定期从 GitHub Releases 下载并经 `SHA256SUMS.txt` 与 `SecStaticCode` 代码签名及 `TeamIdentifier` 防降级校验后一键重启替换，签名权限不兼容时自动转为引导前往 GitHub 手动查看以保护辅助功能授权）。点击 Dock 图标或按 `⌘0`（打开资料库 / Open Library）可打开三栏资料库窗口（支持 `⌥1` 卡片墙与 `⌥2` 会话时间轴视图切换），全局 `⌃⌥R` 继续独立开关 72 小时速览浮窗。右侧状态栏菜单仅保留高频控制，并在缺少辅助功能权限或当前宿主插件异常时条件展示提醒入口，插件与权限管理统一位于“设置 → 插件与权限”。菜单栏“设置…”、顶部应用主菜单的“关于 Coding Rewind”与“检查更新…”、浮窗齿轮和 `⌘,` 都指向同一设置窗口（“关于”与“检查更新…”位于设置或顶部应用菜单，不再出现在右侧菜单栏状态项下拉菜单中）。设置分为通用、云端同步、快捷键、插件与权限、关于；通用开关、AI 读写权限开关、自动更新开关与快捷键修改立即保存，云端同步设置单独保存。

如果菜单栏图标消失，先从 Finder 打开应用，再进入“设置 → 通用 → 打开系统菜单栏设置”。在系统的“允许在菜单栏中显示”列表开启 CodingRewind。应用不会反复覆盖系统的隐藏选择。

不配置云端同步时，桌面端仍可在本机暂存片段、查看近 72 小时卡片并交付 Antigravity 或 DSH 开始对话；按需部署自托管 Memos（步骤见 [deploy/vps/README.md](deploy/vps/README.md)）后，可启用跨设备同步、网页剪藏持久化与自动 AI 摘要。在桌面端“设置 → 云端同步”或 Chrome 扩展设置页输入服务地址后，可点击地址旁的“打开后台拿令牌 ↗”按钮直达 Memos 网页获取访问令牌。已保存的访问令牌不会回填明文到输入框，仅调整地址时留空即可保留现有令牌。点击保存后，若服务地址与可用令牌（含已保存的令牌）均已就绪，客户端会自动调用 `/api/memos?pageSize=1` 验证服务连通性与 JSON 响应并直接在设置页显示结果；任一缺失则跳过网络探测。云端同步页会标明由启动环境管理的地址或令牌并禁用对应编辑；立即同步的反馈显示在“最近操作”中，菜单中的“已配置”只表示地址有效，不代表服务已经连通。
