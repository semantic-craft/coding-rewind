# 里程碑与可执行验收

本文件只定义各阶段交付目标与可复查的验收标准。需求依据见 [requirements.md](requirements.md)，架构与线级契约见 [architecture.md](architecture.md)，数据与凭据边界见 [privacy.md](privacy.md)。

## M0　立项规范与来源核查

**目标**

在 `~/Projects/coding-rewind/` 建立结构清晰的立项文档体系，完整保存用户需求原话、核实对照来源与开源协议边界。

**可执行验收**

1. 仓库包含 `README.md`、`LICENSE`、`docs/requirements.md`、`docs/sources.md`、`docs/architecture.md`、`docs/privacy.md`、`docs/milestones.md` 与 `docs/contributing.md`，所有相对内链均可解析。
2. 用户 2026-11-10 立项正本与口述补充原样保留，决定、方向、建议与待决层级清晰可辨。
3. [sources.md](sources.md) 明确区分标准 `MIT` 上游项目、Copyleft 或无许可排除项目以及闭源商业产品。

## M1　统一架构收敛与治理门禁

**目标**

确立单实例原版 `usememos/memos` 后端加轻量边缘端的无胶水架构，落盘仓库级 [AGENTS.md](../AGENTS.md)、[lessons.md](../lessons.md) 与统一验证入口 [scripts/check](../scripts/check)。

**可执行验收**

1. 清理冗余本地业务 SQLite、自建富文本写作舱、自定义 URL Scheme 与手写 MCP 可执行目标，全仓不存在已废弃模块残留。
2. 根目录具备 [AGENTS.md](../AGENTS.md) 与记录 6 项真实历史缺陷的 [lessons.md](../lessons.md)。
3. 在仓库任意目录运行 `./scripts/check` 可自动拦截硬编码 `.build/CodingRewind.app` 配置路径、`/tmp` 构建或验收路径、明文令牌前缀及私人 IP 地址。

## M2　双端零打扰选段暂存与离线缓冲

**目标**

在桌面端 **Google Antigravity App 2.x** 与网页端 ChatGPT、Claude、Gemini 实现一键无感暂存，完整附带会话上下文并支持断网队列幂等重放。

**可执行验收**

1. 桌面端按下 `⌃⌥S` 时优先经 `kAXSelectedTextAttribute` 读取选区，回退模拟 `⌘C` 时校验 `changeCount` 递增并在 `defer` 完整恢复全部 `NSPasteboardItem`，无选区时不误存旧剪贴板。
2. `coding-rewind-hook` 在 `PostInvocation` 与 `Stop` 事件中从标准输入提取 `lastUserInput`、`conversationId` 与 `transcript.jsonl` 最近 4 轮问答，原子更新 `active_turn.json` 且退出码为 0。
3. 浏览器扩展 `extensions/web-clipper` 从 ChatGPT、Claude、Gemini 页面提取选区 Markdown、清洗后的会话标题、前序提问与最近 4 轮对话，由后台直连 `POST /api/memos?memoId=<clientClipId>` 与评论接口，右上角显示 2.2 秒轻提示且不抢焦点、不弹协议确认框。
4. 目标不可达时，桌面端写入 `outbox.jsonl`、网页端写入 `chrome.storage.local` 离线队列，恢复连接后通过相同 `memoId` 幂等冲刷且不产生重复记录。

## M3　云端 AI 脉络定锚、72 小时浮窗回顾与数据可控

**目标**

在自托管 `usememos/memos` 上自动补齐片段语境抬头并逐字保护原文，在 macOS 毛玻璃浮窗中流畅回顾近 72 小时热流卡片，保障数据可导出与可删除。

**可执行验收**

1. `deploy/vps/enricher` 同时通过 Standard Webhooks HMAC-SHA256 验签测试与内网轮询自愈测试，对带 `#rewind/has-ctx` 的新片段在评论未到时等待最多 15 秒，调用兼容模型生成 `Title`、`Session`、`Context`、`Keywords` 引用头并将标签翻转为 `#rewind/ready`。
2. 对比增强前后的片段正文，包含代码块、数学公式与链接在内的用户选中原文必须 100% 逐字一致，对已是 `#rewind/ready` 的记录重复运行零额外模型调用。
3. 按下 `⌃⌥R` 唤出启用 `LSUIElement` 与 `.nonactivatingPanel` 的毛玻璃浮窗，正确展示近 72 小时内未标记 `#rewind/synthesized` 的卡片及其状态徽标，离线状态下基于 `hot_cache.json` 瞬时打开。
4. 用户可通过自托管 `Memos` 网页端或标准 REST 接口导出单条及全部记录，删除记录后刷新浮窗不再残留旧条目。

## M4　自然语言检索与 Antigravity 互动成文

**目标**

打通从毛玻璃浮窗和原生 `/mcp` 到 **Google Antigravity App 2.x** 的推演追问与对照写稿闭环，全链路凭据经钥匙串隔离保护。

**可执行验收**

1. 在浮窗勾选多张卡片按下 `⌘Return`，客户端经官方 sidecar 调用 `agentapi new-conversation`，传入含脉络抬头、原文与回链的提示词，并以成功回执和真实桌面会话共同验收。
2. 插件安装器将辅助二进制拷入 `~/Library/Application Support/CodingRewind/bin/`，生成的 `plugin.json` 中 `suggestedPrompts` 为纯字符串数组，`hooks.json` 中 `PostInvocation` 与 `Stop` 为扁平处理器数组。
3. `scripts/memos-mcp-bridge.sh` 在 `CODING_REWIND_QA=1` 下严格隔离至 `com.codingrewind.memos.qa` 钥匙串服务，不落盘明文令牌即可将 `Memos` 原生 `/mcp` 接入 Antigravity 供 `/rewind` 检索与成文引用。
4. 运行 `./scripts/check` 与 `./scripts/build-app-bundle.sh` 全部退出码为 0。

## 远期候选边界

自动暂存与相关时主动提示不属于已立项里程碑。日后若经用户单独批准，须另设独立里程碑明确开关机制、新增采集范围与清理验证方法。

## 桌面入口与设置验收

后续修复按 [代码质量与验收标准](code-quality.md) 检查。首次启动默认显示 Dock，隐藏设置立即生效且重启保持。菜单栏系统许可关闭时，从 Finder 重开仍能找到设置中的恢复说明。菜单、HUD 与 `⌘,` 只打开一个设置窗口。连接字段的环境来源、非法地址反馈和保存后的读回应分别验证。
