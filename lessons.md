# 项目教训

实现、评审或验收前阅读相关条目；用户纠正、返工或漏验暴露可复用教训后补记。
已有教训如下；后续沿用文末模板补记。

### 浏览器剪藏不得借自定义 URL 协议中转

**浏览器扩展保存片段时必须由后台 Service Worker 直连服务端 HTTP 接口，不使用自定义 URL Scheme 唤醒桌面应用。**

- 标签：#浏览器扩展 #协议边界 #焦点管理
- 起因与后果：v0.1 提交 `194cdc0` 预设 `coding-rewind://stash` 协议接收口并在 `Info.plist` 注册 `CFBundleURLTypes`，浏览器触发自定义协议会弹出系统打开确认框并抢夺前台窗口焦点，违背零打断顺手暂存的核心目标。
- 修复与证据：v0.2 删除 `StashURLCommand.swift` 及 `Info.plist` 中的自定义协议声明，新增 [extensions/web-clipper](extensions/web-clipper) 由 Manifest V3 后台直连 `usememos/memos` 的 `/api/memos` 接口，页面内仅渲染 2.2 秒 Shadow DOM 轻提示且完全不切走输入焦点。
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
- 修复与证据：v0.2 在 [MacOSSelection.swift](Sources/CodingRewindApp/MacOSSelection.swift) 参照 MIT 项目 `tisfeng/SelectedTextKit` 与 `p0deje/Maccy` 重写回退逻辑，先快照全部 `NSPasteboardItem` 原始类型字节与 `changeCount`，投递 `CGEvent` 模拟 `⌘C` 后在有界窗口内检查 `changeCount` 增长，并在 `defer` 块无条件恢复备份条目。
- 正确做法 `Done right`：优先读取辅助功能选区属性，回退剪贴板时严格以 `changeCount` 递增作为复制成功证据，未递增一律视作无选区并给出提示，绝不误存旧剪贴板且绝不污染用户原有剪贴板。
- 验证点：查看 [MacOSSelection.swift](Sources/CodingRewindApp/MacOSSelection.swift) 确认包含 `changeCount` 对比与 `defer` 快照还原，运行 `./scripts/check` 通过单元测试。
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

### Memos 26.10+ 移除 `/api/v1` 前缀导致模拟测试未覆盖真实版本路由变更

**对接固定版本的外部开源后端时，必须以目标真实容器实例核对 HTTP 路由契约，不能仅凭自建模拟桩认定接口路径有效。**

- 标签：#验收 #契约
- 起因与后果：选用原生内置 `/mcp` 的 `neosmemo/memos:26.11.0` 时，`Memos` 自 `26.10+` 起已移除 REST 路由中的 `/v1` 前缀，请求 `/api/v1/memos` 直接返回 `HTTP 410 Gone`；由于桌面端、网页扩展与增强器的单元测试均针对手写模拟桩断言 `/api/v1/memos`，单测全绿却掩盖了真实容器路由变更。
- 修复与证据：上线前针对真实 `neosmemo/memos:26.11.0` 容器联调检出 `410 Gone`，同步将 [MemosClient.swift](Sources/CodingRewindCore/MemosClient.swift)、[enricher.py](deploy/vps/enricher/enricher.py)、[memos_payload.mjs](extensions/web-clipper/memos_payload.mjs) 与 [options.js](extensions/web-clipper/options.js) 三端请求路径统一切换至 `/api/memos`，兼容剥离用户误贴的 `/api/memos` 或 `/api/v1/memos` 地址后缀，并在 [scripts/check](scripts/check) 增加静态门禁阻断 `/api/v1/memos` 回归。
- 正确做法 `Done right`：升级或锁定外部后端镜像标签时先对真实容器跑通端到端契约探测，再将已移除的旧路由写入 [scripts/check](scripts/check) 静态门禁防止回退。
- 验证点：运行 `./scripts/check` 确认静态路由门禁与三端单元测试全部通过，且在 `Sources/`、`deploy/` 与 `extensions/` 非地址清洗行写入 `/api/v1/memos` 会被立即阻断。
- 复发记录：`Seen 1x (2026-11-11)`，上线前针对真实 `neosmemo/memos:26.11.0` 实例联调检出。

### `LSUIElement` 菜单栏应用必须响应打开重入并挂载主菜单与规格化图标

**启用 `LSUIElement` 的 macOS 状态栏应用必须在首次启动与 `applicationShouldHandleReopen` 时显式呈递主界面，同时挂载 `NSApp.mainMenu` 与独立 `NSStatusItem` 模板图标。**

- 标签：#macOS原生 #菜单栏 #图标规格 #验收
- 起因与后果：v0.2 提交 `36cc88b` 在启用 `LSUIElement` 隐藏 Dock 图标的同时，将启动展示限定于 `--show-hud` 参数且未实现 `applicationShouldHandleReopen(_:hasVisibleWindows:)`，导致用户从 Finder 或 Spotlight 打开 `CodingRewind.app` 时窗口数为 `0`；叠加 SwiftUI `MenuBarExtra` 缺少 `NSApp.mainMenu` 导致输入框 `⌘V`/`⌘C` 失效、`Info.plist` 缺失 `CFBundleIconFile` 及默认系统图标在刘海屏右区缺乏辨识度，造成用户点击无响应。
- 修复与证据：移除 `MenuBarExtra`，在 [CodingRewindAppMain.swift](Sources/CodingRewindApp/CodingRewindAppMain.swift) 与 [AppMenusAndStatusBar.swift](Sources/CodingRewindApp/AppMenusAndStatusBar.swift) 改用纯 AppKit 生命周期、`NSStatusItem` + `NSMenu` 状态菜单与完整四栏 `NSApp.mainMenu`，默认启动与重入均唤出浮窗（仅 `--background` 静默驻留），新增 [QuickPeekHUDViews.swift](Sources/CodingRewindApp/QuickPeekHUDViews.swift) 基于 `auxiliaryTopRightArea` 的刘海安全锚定及独立设置窗口，并通过 [verify-app-icon.swift](scripts/verify-app-icon.swift) 接入 [scripts/check](scripts/check) 校验 `824/1024` 圆角矩形与 `MenuBarIcon` 模板像素边界。
- 正确做法 `Done right`：`LSUIElement` 应用统一使用 AppKit `NSApplicationDelegate` 管理启动/重入窗口反馈、显式注册编辑与操作主菜单以打通响应链快捷键，并将 `AppIcon.icns`（与系统 `Mail.app` 误差 `<= 1 px`）和 `@1x/@2x` 菜单栏模板校验纳入 `./scripts/check`。
- 验证点：运行 `./scripts/check` 通过全部 6 项门禁；通过 `open ~/Applications/CodingRewind.app` 实机验证首次启动与关闭浮窗后二次打开均呈递窗口，且 AX 树包含主菜单与 `Coding Rewind` 状态栏项。
- 复发记录：`Seen 1x (2026-11-11)`，用户实机启动反馈无响应后复现定位。

### 状态标签只属于首行，网络等待不能覆盖新队列

**只解析和更新首行状态标签；离线发送完成后重读队列，仅移除已成功发送且内容未变的条目。**

- 标签：#原文保真 #离线队列 #并发
- 起因与后果：2026-11-12 对 `1d36ca0` 的本机审查发现，全文替换状态标签会改写选区中的同名文字，全文查找归档标签会隐藏正常卡片；网络请求等待期间的新入队条目可能被旧快照覆盖。
- 修复与证据：首行标签处理与队列提交分别收敛到 [DomainModels.swift](Sources/CodingRewindCore/DomainModels.swift) 和 [MemosClient.swift](Sources/CodingRewindCore/MemosClient.swift)，回归在 [CodingRewindCoreTests.swift](Tests/CodingRewindCoreTests/CodingRewindCoreTests.swift)。
- 正确做法 `Done right`：原文保持独立于元数据的字节序列；队列同步读改写以文件事务保护，网络等待不持锁，提交时核对最新条目与发送快照。
- 验证点：运行 `./scripts/check`，覆盖正文内同名标签、UTF-8 原文、并发入队、同 ID 更新及交错刷新。
- 复发记录：`Seen 1x (2026-11-12)`，本机质量审查检出。

### 跨应用快捷键占用须用独立进程验证

**Carbon 同进程重复注册和跨进程占用语义不同，冲突验收必须包含真实独立进程，并区分共享与独占注册。**

- 标签：#macOS原生 #快捷键 #验收
- 起因与后果：2026-11-12 Hyper 快捷键实现中，同进程占用测试能得到 `-9878`，但 GUI 验收发现上游 `RegisterEventHotKey` 的零选项允许不同应用共享组合，不能据此声称跨应用冲突检测有效。
- 修复与证据：库内唯一注册调用改用 `kEventHotKeyExclusive`，初次注册及恢复均报告实际 OSStatus；[AppShortcutsTests.swift](Tests/CodingRewindAppTests/AppShortcutsTests.swift) 使用独立 [ShortcutConflictFixture](Tests/Support/ShortcutConflictFixture/main.swift) 验证共享占用可被独占注册优先处理，独占占用返回 `-9878`，释放后重试恢复。
- 正确做法 `Done right`：依据系统 API 真实能力描述冲突范围，不从已存配置推断生效，也不承诺枚举其他应用所有绑定；跨进程行为不能只用同进程夹具证明。
- 验证点：运行 `./scripts/check`，确认跨进程共享/独占两种情况、初次失败、恢复失败及重试全部通过。
- 复发记录：`Seen 1x (2026-11-12)`，隔离 GUI 验收检出。

### CLI 文件存在不等于宿主环境可用

**验证宿主 CLI 时必须从实际桌面启动环境执行操作，不能只检查可执行文件存在。**

- 标签：#宿主契约 #Antigravity #验收
- 起因与后果：2026-11-12 实测 Antigravity 2.31.2 的 `agentapi` 虽存在，普通外部进程调用仍报 `ANTIGRAVITY_LS_ADDRESS is not set`，不能据此承诺直接创建会话。
- 修复与证据：[AppCoordinator.swift](Sources/CodingRewindCore/AppCoordinator.swift) 的回退提示改为复制上下文并打开应用，明确需要新建会话后粘贴发送；运行环境边界见 [README.md](README.md#在-antigravity-接聊)。实机已验证浮窗勾选卡片、完整复制上下文并在 Antigravity 新会话发送。
- 正确做法 `Done right`：先验证宿主提供的运行环境和真实操作结果。本次后续实现使用官方 `coding-rewind/launcher` sidecar，从已安装 HUD 触发并核对宿主新会话；普通桌面进程不直调 CLI，不把入口发现当作集成完成。
- 验证点：运行 `./scripts/check`，由 [ConversationHandoffTests.swift](Tests/CodingRewindCoreTests/ConversationHandoffTests.swift) 覆盖结构化回执、重复提交、崩溃恢复与过期清理；从已安装 HUD 核对新会话、原文、失败不归档、应用重启及 sidecar 原位升级。未知结果不自动重发，成功回执不能冒充前台已切换。
- 复发记录：`Seen 1x (2026-11-12)`，桌面接聊实机验收检出。

### 菜单栏许可与 Dock 激活策略分别验收

**菜单栏对象存在不代表系统允许显示；Dock 的目标策略已经生效时，重复设置返回 false 不能当成失败。**

- 标签：#macOS原生 #菜单栏 #验收
- 起因与后果：2026-11-13 实机中，CodingRewind 仍在运行，但系统“菜单栏”的 CodingRewindApp-native 开关关闭；同时应用固定使用 accessory 策略，用户找不到入口。修复后隔离重启又检出，同为 accessory 的重复 setActivationPolicy 返回 false，设置误报失败。
- 修复与证据：恢复系统开关并读回；[AppAppearancePreferences.swift](Sources/CodingRewindApp/AppAppearancePreferences.swift) 默认显示 Dock，以当前策略判定无需切换的成功情况；设置提供系统菜单栏恢复入口。[AppAppearancePreferencesTests.swift](Tests/CodingRewindAppTests/AppAppearancePreferencesTests.swift) 的真实 AppKit 回归在修复前断言失败，修复后通过。
- 正确做法 `Done right`：先核对正在运行的实际可执行文件在系统菜单栏列表中的许可，再核对 Dock 激活策略。应用不循环覆盖系统选择。设置、启动和持久化共用一个偏好所有者。
- 验证点：运行 [scripts/check](scripts/check)，再按 [代码质量标准](docs/code-quality.md) 验证已安装包的图标、设置入口和重启；[verify-app-presence.swift](scripts/verify-app-presence.swift) 只证明激活策略，屏幕图标仍需单独核验。
- 复发记录：`Seen 1x (2026-11-13)`，用户反馈和隔离应用重启验收检出。

### 网页选区转换必须保留源页面的换行规则

**克隆选区会丢失祖先 CSS，不能把所有文本节点的换行都折叠为空格。**

- 标签：#原文保真 #Gemini #验收
- 起因与后果：2026-11-13 真实 Gemini 回答的 span 使用 pre-wrap；带加粗、代码的三行选区保存后变为一行，上下文评论也丢失换行。
- 修复与证据：[extractors.mjs](extensions/web-clipper/extractors.mjs) 将源文本节点的换行规则映射到克隆节点；[test_extractors.mjs](extensions/web-clipper/test_extractors.mjs) 先失败后通过，真实页面重验见 [验收记录](docs/acceptance-2026-11-13.md)。
- 正确做法 `Done right`：选区与上下文共用转换规则；同时验证 normal 空白折叠行为没有变化。
- 验证点：运行 `./scripts/check`，从真实页面保存并比较 pending、ready 和上下文中的原文。
- 复发记录：`Seen 1x (2026-11-13)`，真实页面剪藏验收检出。

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
