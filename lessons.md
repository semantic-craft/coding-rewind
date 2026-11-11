# 项目教训

实现、评审或验收前阅读相关条目；用户纠正、返工或漏验暴露可复用教训后补记。
已有教训如下；后续沿用文末模板补记。

### 浏览器剪藏不得借自定义 URL 协议中转

**浏览器扩展保存片段时必须由后台 Service Worker 直连服务端 HTTP 接口，不使用自定义 URL Scheme 唤醒桌面应用。**

- 标签：#浏览器扩展 #协议边界 #焦点管理
- 起因与后果：v0.1 提交 `194cdc0` 预设 `coding-rewind://stash` 协议接收口并在 `Info.plist` 注册 `CFBundleURLTypes`，浏览器触发自定义协议会弹出系统打开确认框并抢夺前台窗口焦点，违背零打断顺手暂存的核心目标。
- 修复与证据：v0.2 删除 `StashURLCommand.swift` 及 `Info.plist` 中的自定义协议声明，新增 [extensions/web-clipper](extensions/web-clipper) 由 Manifest V3 后台直连 `usememos/memos` 的 `/api/v1/memos` 接口，页面内仅渲染 2.2 秒 Shadow DOM 轻提示且完全不切走输入焦点。
- 正确做法 `Done right`：网页端采集统一通过扩展后台 `fetch` 直连 `Memos` 实例并维护 `chrome.storage.local` 离线重放队列，桌面端不注册输入型 URL Scheme。
- 验证点：检查 `Sources/` 与 [build-app-bundle.sh](scripts/build-app-bundle.sh) 不存在 `coding-rewind://` 或 `CFBundleURLSchemes`，运行 `./scripts/check` 通过浏览器扩展测试。
- 复发记录：`Seen 1x (2026-11-11)`，v0.1 提交 `194cdc0` 架构走查检出。

### 宿主插件与钩子不得指向临时构建目录

**写入外部宿主配置的二进制与脚本路径必须落在固定安装目录，严禁引用 `.build/` 或临时构建目录。**

- 标签：#安装路径 #宿主集成 #门禁
- 起因与后果：v0.1 提交 `194cdc0` 在安装 Antigravity 插件与钩子时允许直接传入 `.build/` 下的构建产物路径，一旦清理构建缓存或移除临时工作区，宿主每轮对话结束触发钩子都会因可执行文件丢失而报错。
- 修复与证据：v0.2 参照 MIT 项目 `wxtsky/CodeIsland` 改为在安装或修复插件时将 `coding-rewind-hook` 与 [memos-mcp-bridge.sh](scripts/memos-mcp-bridge.sh) 拷入 `~/Library/Application Support/CodingRewind/bin/` 并赋予 `0755` 权限，同时在 [scripts/check](scripts/check) 加入静态门禁拦截非构建脚本引用 `.build/CodingRewind.app`。
- 正确做法 `Done right`：所有供宿主长期调用的辅助二进制与桥接脚本先拷入 `Application Support` 固定目录再写入宿主配置，并由 [scripts/check](scripts/check) 静态阻断 `.build/` 与 `/tmp/` 路径泄漏。
- 验证点：运行 `./scripts/check` 确认静态路径门禁与 `swift test` 全部通过，核对插件安装测试断言生成的命令路径位于固定 `bin/` 目录。
- 复发记录：`Seen 1x (2026-11-11)`，v0.1 提交 `194cdc0` 宿主接线审查检出。

### 选区回退必须投递复制按键并完整还原剪贴板

**辅助功能未读到选中文本时，必须先完整备份剪贴板全部条目并投递模拟复制事件，确认计数递增后再读取且在退出时无条件还原。**

- 标签：#macOS原生 #剪贴板 #选区捕获
- 起因与后果：v0.1 提交 `194cdc0` 在 `kAXSelectedTextAttribute` 未取到文本时没有模拟 `⌘C`，而是直接读取 `NSPasteboard.general` 现有字符串，导致用户在未选中文本或 Electron 特殊视图中按下热键时静默把旧剪贴板内容当成新片段入库。
- 修复与证据：v0.2 在 [MacOSSelectionAndHotkeys.swift](Sources/CodingRewindApp/MacOSSelectionAndHotkeys.swift) 参照 MIT 项目 `tisfeng/SelectedTextKit` 与 `p0deje/Maccy` 重写回退逻辑，先快照全部 `NSPasteboardItem` 原始类型字节与 `changeCount`，投递 `CGEvent` 模拟 `⌘C` 后在 120 毫秒上限内轮询 `changeCount` 增长，并在 `defer` 块无条件恢复备份条目。
- 正确做法 `Done right`：优先读取辅助功能选区属性，回退剪贴板时严格以 `changeCount` 递增作为复制成功证据，未递增一律视作无选区并给出提示，绝不误存旧剪贴板且绝不污染用户原有剪贴板。
- 验证点：查看 [MacOSSelectionAndHotkeys.swift](Sources/CodingRewindApp/MacOSSelectionAndHotkeys.swift) 确认包含 `changeCount` 对比与 `defer` 快照还原，运行 `./scripts/check` 通过单元测试。
- 复发记录：`Seen 1x (2026-11-11)`，v0.1 提交 `194cdc0` 代码走查检出。

### Antigravity 插件清单与钩子结构必须严格对齐官方规范

**生成 Antigravity 2.x 的 `plugin.json` 与 `hooks.json` 时必须使用官方规定的纯字符串提示词数组与扁平处理器数组，并直接读取标准输入载荷。**

- 标签：#宿主契约 #Antigravity #钩子
- 起因与后果：v0.1 提交 `194cdc0` 在 [AntigravityIntegration.swift](Sources/CodingRewindCore/AntigravityIntegration.swift) 中将 `PostInvocation` 与 `Stop` 误写成嵌套 `hooks` 对象结构，并将 `plugin.json` 的 `suggestedPrompts` 误写成带 `title` 与 `prompt` 的对象数组，钩子还舍弃 `stdin` 现成的 `lastUserInput` 转而逆向猜日志，导致宿主无法正常加载提示词与钩子。
- 修复与证据：v0.2 对照 Antigravity 2.x 官方文档将插件内 `hooks.json` 的 `PostInvocation` 与 `Stop` 改为扁平命令处理器数组，将 `suggestedPrompts` 改为 3 条纯字符串数组，并在 [AntigravityHookRunner.swift](Sources/CodingRewindCore/AntigravityHookRunner.swift) 直接提取 `stdin` 的 `lastUserInput`、`conversationId` 及 `transcriptPath` 最近 4 轮对话写入 `active_turn.json`。
- 正确做法 `Done right`：宿主扩展配置只写官方文档明确支持的字段与层级，优先读取宿主标准输入提供的结构化字段，并用测试固定 JSON Schema。
- 验证点：运行 `./scripts/check` 执行 `swift test`，确认 `plugin.json` 的 `suggestedPrompts` 为 `[String]` 且 `hooks.json` 为扁平处理器数组。
- 复发记录：`Seen 1x (2026-11-11)`，v0.1 提交 `194cdc0` 宿主规范核查检出。

### 单一事实源优先于双库同步与手写胶水服务

**上游开源后端已原生具备存储、事件与 MCP 接口时，直接以其为唯一事实源，不自建重复本地业务数据库与协议胶水层。**

- 标签：#架构收敛 #单一事实源 #凭据隔离
- 起因与后果：v0.1 提交 `194cdc0` 在本机维护了 `StashStore` SQLite FTS5、`WritingStudioViews` 草稿舱及手写 `RewindMCPServer` 约两千行代码，再叠加上云需求就会退化成双库双向同步与脆弱胶水层，同时在 MCP 配置中极易暴露明文访问令牌。
- 修复与证据：v0.2 移除本地业务 SQLite、自建编辑器与手写 `rewind-mcp`，统一以阿里云轻量服务器上的原版 `usememos/memos` 为唯一事实源，由约百行标准库 Python 编写的 [enricher.py](deploy/vps/enricher/enricher.py) 幂等补齐语境抬头，本机仅保留 `hot_cache.json` 与 `outbox.jsonl` 离线缓冲，并通过 macOS Keychain 与 [memos-mcp-bridge.sh](scripts/memos-mcp-bridge.sh) 向原生 `/mcp` 注入令牌。
- 正确做法 `Done right`：客户端只保留轻量选区捕获、72 小时毛玻璃速览浮窗与 `agentapi new-conversation` 拉起动作，持久化与 MCP 工具统一复用 `usememos/memos`；开发与验收开启 `CODING_REWIND_QA=1` 隔离至 `com.codingrewind.memos.qa`，禁止在任何 JSON 配置文件写入明文令牌。
- 验证点：运行 `./scripts/check` 确认无本地业务 SQLite 目标与明文凭据残留，且后端、前端与扩展三端契约测试全部通过。
- 复发记录：`Seen 1x (2026-11-11)`，v0.1 提交 `194cdc0` 架构收敛评审检出。

## 记录模板

复制下列模板新增条目，已有同类条目则更新原条。未知的提交、原因或验收结果明确写待核实。

```markdown
### <教训标题>

**<一句话说明下次应遵守的规则。>**

- 标签：#验收 #凭据
- 起因与后果：<触发条件、原因、用户可感知的影响；关联 issue 或引入提交，未知则写待核实。>
- 修复与证据：<修复提交或 PR、回归检查与实际验收证据；区分已验证和未验证的部分。>
- 正确做法 `Done right`：<下次的具体做法；链接到防复发代码、检查或所属规范。>
- 验证点：<写明之后怎么核对这条已改到位，含文件、命令与预期结果。>
- 复发记录：`Seen 1x (YYYY-MM-DD)`，<每次独立发生的证据；修复提交数与重试次数不计入。>
```
