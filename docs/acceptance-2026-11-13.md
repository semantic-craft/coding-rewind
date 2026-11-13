# 2026-11-13 补充验收

按 [代码质量标准](code-quality.md) 核对真实操作、服务读回与原文保真。Claude 已由用户明确排除本轮，既有适配器保留。

| 路径 | 结果 | 证据与边界 |
| --- | --- | --- |
| 辅助功能 | 通过 | 用户授权后重启日常安装包，设置显示已授权 |
| TextEdit → HUD → Memos | 通过 | 三行合成测试文本完整保存，含末尾换行；AI 处理后仍一致 |
| 无选区 | 通过 | HUD 提示未选中非空文本，服务端记录数没有增加 |
| 系统剪贴板 | 部分通过 | 紧邻无选区捕获前后，系统文本和类型列表相同；没有逐项比较二进制内容 |
| Gemini 扩展剪藏 | 修复后通过 | 真实回答的 pre-wrap 换行原先丢失；重新加载扩展后，三行、加粗和行内代码在 pending、ready 与上下文评论中一致 |
| 当前 Codex MCP | 通过 | 实际调用 list/get/comments 读取上述新记录，核对 PRIVATE 和上下文标记 |
| TextEdit 全局快捷键 | 用户实机确认通过 | 2026-11-13 用户按 ⌃⌥⇧⌘K 后确认浮窗出现新卡片；此条为用户反馈，未对该次新卡片另做服务端读回 |
| Chrome 桌面捕获 | 通过 | Chrome 原生窗口选中独立三行文本，HUD 抓选段保存为 PRIVATE、source/macos、ready；服务端正文逐字一致，含中文、标点和末尾换行。未使用网页扩展保存 |
| Antigravity 自然语言 MCP | 通过 | coding-rewind 项目新会话内实际调用 memo_list_memos、memo_get_memo、memo_list_memo_comments；展开宿主工具参数与返回值，核对原文、PRIVATE 和上下文标记 |
| 导出删除 | 未验 | 本轮未执行 |

Gemini 回归保留了真实 DOM 的 span/b/code 结构，同时验证 normal 模式仍折叠换行。扩展 22 项测试与全仓 `./scripts/check` 通过。

剪贴板证据只采用系统剪贴板读取。浏览器自动化会话的 clipboard 属于另一份剪贴板，不作为 macOS 还原证据。测试记录为无敏感合成文本，留在私有 Memos 中；具体记录编号、截图和运行日志留在本机验收目录，不纳入公开仓库。

## Chrome 与 Antigravity 后续实测

被测日常应用的 SHA-256 为 `d064166743aa86a159967eaac0a384fff8103e986429cf11f709697ffa96553a`。本轮没有产品代码变更。

Chrome 使用本机 `chrome-selection.txt`，从原生窗口全选后点击桌面浮窗的“抓选段”。这证明 Chrome 桌面选区到 Memos 的路径；不是网页扩展剪藏，也不覆盖所有网站 DOM。自动化发送 Hyper K 未产生新记录，故 Chrome 快捷键仍未独立确认。TextEdit 的真实快捷键验收仍以用户反馈为准。

Antigravity 的只读指令要求从已加载 MCP 查询既有合成测试记录。已展开运行明细，看到服务器 coding-rewind 下的三次工具调用及正文、评论返回值。结果不依赖宿主回答的自述，也不以当前 Codex 的 MCP 调用代替。首次自动输入漏掉中文，已停止并用完整英文指令重新提交；该输入问题未归为产品故障。

本机证据保存在 `.scratch/chrome-antigravity-acceptance/`。截图、具体记录编号与宿主会话编号不进入公开仓库。系统剪贴板的完整二进制保真仍沿用上表的未覆盖边界。
