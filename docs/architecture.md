# 纯 Swift 原生单主线架构与待决边界

2026-11-11 用户拍板采用 **macOS 原生 `Swift 6 + SwiftUI / AppKit + SQLite3 WAL/FTS5`**、**MIT License** 以及 **方案 2（非激活 HUD 速览浮窗加递进写作舱，右上角带可选长对话侧栏开关）**，确立了「单一领域模型贯通到底、边缘感官极薄、拒绝跨栈胶水拼接」的架构准绳。

需求背景见 [requirements.md](requirements.md)，对照来源见 [sources.md](sources.md)，数据如何进出见 [privacy.md](privacy.md)。

## 设计约束（已记录，不是技术选型）

来自需求正本、2026-11-10 用户一手直述与已记录方向：

- **对象与时间尺度**：对象是 AI 对话里确定近期（尤其 **未来 1～3 天**）用得上的好段落、提示词或灵感片段，介于系统备忘录与正式 Notes 之间，不是全量聊天备份。
- **捕获零打断**：在主线任务进行中选中片段即可一键暂存；**不强迫当场新开对话分叉、不在原对话里插入无关保存指令污染上下文、不强迫填写标题或标签**。
- **目标双场景与宿主边界**：必须同时围绕独立桌面端 **Google Antigravity App 2.x**（`com.google.antigravity`，无 IDE 外壳、**不支持 VS Code `.vsix` 界面插件**，但支持原生 `plugin.json` / `mcp_config.json` / `hooks.json` / `skills/`）与 **网页版 AI 聊天** 设计。
- **保留语境**：每条记录要能看到原文、原问题（能取则取，缺失如实标明）和出处。
- **回顾、找回与 A+C 互动成文**：默认突出展示近 2～3 天热窗口片段，支持自然语言找回，并同时支持 **A（勾选暂存片段继续向 AI 追问推演）** 与 **C（对照暂存片段撰写草稿/思考，由 AI 辅助整理）**。
- **非目标**：不做默认全量采集；「自动暂存」「相关时提示」仍是候选。

## 已拍板的单主线架构（决定，2026-11-11）

为避免把不同技术栈的项目硬绑成胶水代码（例如同时维护 Next.js WebView 与 SwiftUI 两套状态），系统遵循**「唯一核心数据结构 + 单一原生宿主 + 极薄边缘感官」**原则。所有模块只围绕同一张灵感卡片（`Clip`）从暂存态流向成文态：

```text
[桌面端：Antigravity App 2.x]                    [网页端：ChatGPT / Claude / Gemini]
 全局热键静默取选区（不抢焦点）                   极薄浏览器扩展（参考 obsidian-clipper）
 + AntigravityBridge 非阻塞 Hook 关联原问题       调用 coding-rewind://stash?...&silent=true
        │                                                        │
        └───────────────────────────┬────────────────────────────┘
                                    ▼
             [唯一主脊椎：CodingRewindCore (Swift 6, MIT)]
              • Clip 值类型模型（SQLite3 WAL + FTS5 + NaturalLanguage 单事务落盘）
              • Draft 成文草稿（直接读写本地普通 .md 文件）
              • 纯函数按 72 小时窗口派生 hot / synthesized / archived 状态
                                    │
        ┌───────────────────────────┴────────────────────────────┐
        ▼                                                        ▼
[出口 1：CodingRewindApp（方案 2 双态原生界面）]  [出口 2：rewind-mcp 本地只读 stdio 服务]
 • 一档：QuickPeekHUDPanel（.nonactivatingPanel） 通过 ~/.gemini/config/plugins/coding-rewind/
 • 二档：递进写作舱（顶栏钉选卡片 + 内联 ⌘J 追问  供 Antigravity（含 Knowledge Work 界面）拉取卡片
   + 普通 .md 草稿区 + 右上角可选长对话侧栏开关）
```

### 1. 代码分层与高星 MIT 参考映射

整个桌面端收纳在同一个原生 Swift 工程内，各层共享同一个 `Clip` 类型，零跨语言序列化胶水：

- **`Core/`（纯领域模型与存储，不依赖 UI）**
  - `Clip.swift`：唯一一等公民结构，包含 `excerpt`（选中原文）、`promptContext`（触发该段回答的原问题，取不到时显式标为 `missing`）、`source`（枚举区分 Antigravity 会话与网页 URL）、`capturedAt` 及生命周期状态（`hot` 72 小时热窗、`synthesized` 已引用成文、`archived` 自然冷却）。
  - `StashStore.swift`：使用系统原生 `SQLite3` 开启 WAL 模式与 `secure_delete = ON`，在同一个 ACID 事务中维护 `clips` 表与 `clips_fts`（FTS5 虚拟表加 `NaturalLanguage` 中英文分词与词形还原）。主程序以 `.readWrite` 打开，`rewind-mcp` 以 `.readOnly` 打开，单条删除与全部清空同步擦除 FTS 索引并返回 `DeletionReceipt`。
  - `Draft.swift`：场景 C 产出的草稿直接读写用户可读的普通本地 `.md` 文件（参考 `glushchenko/fsnotes` 的本地文件夹透明模式），不锁进私有二进制库。
- **`Capture/`（两个静默感官入口，本身不存状态）**
  - **桌面全局热键 + Antigravity 2.x 会话关联（v0.1 第一刀）**：对 `com.google.antigravity` 先激活 Electron 辅助功能属性再读取 `kAXSelectedTextAttribute`（必要时瞬时快照并恢复剪贴板），配合 `.nonactivatingPanel` 显示成功提示或失败横幅，不抢走原窗口焦点。附属可执行 Target `AntigravityBridge`（产物 `coding-rewind-hook`）仅挂载非阻塞 `PostInvocation` 与 `Stop` 事件，过滤子代理环境变量，逆向扫描会话日志尾部提取最新用户提问，通过临时文件加 `rename(2)` 原子更新 `Runtime/` 快照并输出 `"{}\n"` 退出，即使主程序未启动也能在数毫秒内无锁完成。
  - **网页端协议接收口（v0.1 预留接口，v0.2 接扩展）**：参考 `obsidianmd/obsidian-clipper`（5.5k 星，MIT）的 `obsidian-note-creator.ts`，浏览器薄扩展提取 ChatGPT、Claude、Gemini 的选段与上一轮用户提问后，直接触发 `coding-rewind://stash?...&silent=true`。原生主程序通过 `onOpenURL` 静默入库，省去常驻 HTTP 端口。
- **`Views/`（Apple HIG 原生界面，具体布局由本轮三套原型拍板）**
  - 吸收 `Maccy` 的 `FloatingPanel`（支持 macOS `GlassEffectView` 与 `VisualEffectView` 毛玻璃材质、多选列表）以及 `johnbean393/Sidekick` 的本地材料注入对话模式，把 `codexu/note-gen`「先无负担记录、后勾选成文」的两阶段体验做成纯正苹果原生手感。
- **`Extensions/RewindMCP/`（反哺 Antigravity `Knowledge Work`，v0.1 第一刀）**
  - 同工程编译出的极薄本地 `stdio` MCP 可执行文件，直接只读访问同一个 `StashStore`，让用户在 Antigravity App 写作或推演时通过 `/rewind` 拉取近两三天攒下的片段。

## 一条记录至少应能表达什么

这是概念字段，不是数据库模式，也不是 API。实现时可以改名或拆分，但不能丢掉这些含义。

| 含义 | 说明 |
| --- | --- |
| 原文 | 用户选中并保存的那段文字，必须是原文，不能只存摘要。 |
| 原问题 | 引出该段回答或思路的用户问题 / 提示词。若当时无法取得，应留下「缺失」而不是补写一个假问题。 |
| 出处 | 来源产品、会话标识或可打开的链接，以及其他足以回到现场的信息。链接失效时，仍应能阅读已保存的原文。 |
| 保存时间 | 何时留下这条记录。 |
| 可选补充 | 标题、标签、用户笔记都可以有，但都不是保存的前提。 |
| 用户注释与原文的界限 | 对照 Superpower 功能页的提醒：注释是用户自己的话，不能和原文混成一段无法分辨的文字。 |

不在 MVP 里预设：完整会话副本、自动分类、评分、云端账号、多设备同步。

## 五条主路径

1. **零打扰暂存（收集）**：在 Antigravity App 2.x 或网页聊天中选中好段落 → 一键暂存（热键或页面轻量按钮） → 写入原文、原问题（自动关联或如实标缺失）、出处（App 会话/项目或网页 URL）和时间。全程不打断当前对话、不强迫开新会话、不弹必填标题或标签。
2. **近期热流回放（回顾）**：默认按「近 2～3 天」热窗口展开最近攒下的灵感卡片，打开或扫读即可同时看到原文、原问题与出处；链接或会话仍可用时支持跳回现场，失效时本地原文依然完整可读。
3. **自然语言找回**：当攒下的片段变多或超出最近几天时，用户可用平常的说法检索并找回相关卡片（具体检索技术路径待决，出机边界遵守 [privacy.md](privacy.md)）。
4. **片段互动推演（场景 A）**：勾选一或多张暂存卡片组成上下文，围绕它们继续追问、串联碰撞（在本机工作台中直接对话，或通过本地 MCP 拉入 Antigravity App 会话中展开）。
5. **对照草稿成文（场景 C）**：一边对照选中的暂存卡片与互动结论，一边在右侧草稿栏或 Antigravity `Knowledge Work` 文档中撰写思考与文章，由 AI 辅助整理定稿。

## 建议采用、但尚未决定的原则

- 默认本机存放，不把云同步或注册账号作为保存的前提。这与 `rewind-for-x`、`threadmark`、`kept`、`ContextVault` 的公开做法一致，也符合本阶段隐私红线。
- 默认只保存用户主动选中的片段及其必要问题语境，不在后台全量复制整段会话。`hooks.json` 若用于辅助关联 Antigravity 会话出处，也只为补齐用户所选片段的上下文服务，而非静默归档全部聊天。
- 保存失败时应明确提示用户（如轻提示音或状态栏反馈），而不是静默丢弃。
- 出处链接或 `conversationId` 是辅助定位，不是唯一载体：原会话被删或 URL 失效后，本地原文仍在。

## 已编码锁定的边界与后续可选扩展

1. **方案 2 双态原生界面已定稿**：一档为 `QuickPeekHUDPanel` 非激活速览浮窗，二档为 `WritingStudioWindow` 递进写作舱（含顶部可展开钉选卡片条、内联 `⌘J` 推演浮条、本地普通 `.md` 编辑区，以及右上角可选的 `ScenarioAChatDrawerView` 对话侧栏开关）。
2. **默认零外发隐私栅栏**：检索固定在进程内通过 `SQLite3` FTS5 与 `NaturalLanguage` 离线完成；场景 A 默认提供本地结构化提纲与 `/rewind` Antigravity MCP 交接指令，仅当用户显式构造带域名确认的 `RemoteEndpointConsent` 时才允许访问指定远端接口。
3. **v0.2 待接入项**：基于 `obsidian-clipper` 思路裁剪的浏览器薄扩展（对接 v0.1 已实现的 `coding-rewind://stash?...&silent=true` 接收器）。
