// SPDX-License-Identifier: MIT

import Foundation

public enum SyntheticDemoSeed {
    public static func makeDemoClips(referenceDate: Date = Date()) throws -> [NewClip] {
        [
            try NewClip(
                excerpt: "[SYNTHETIC-DEMO] NSPanel 配合 .nonactivatingPanel 与 NSVisualEffectView 材质可以在不打断当前 Google Antigravity 2.31 窗口焦点的前提下，完成选段一键暂存与近 72 小时热窗速览。",
                promptContext: .captured("[SYNTHETIC-DEMO] 如何在 macOS 上做一个既能随时浮出速览、又不抢当前 Coding Agent 焦点的暂存面板？"),
                source: .antigravity(
                    conversationId: "synthetic-demo-conv-001",
                    workspacePath: "/tmp/synthetic-coding-rewind-workspace",
                    locator: "conversation://synthetic-demo-conv-001"
                ),
                capturedAt: referenceDate.addingTimeInterval(-1800),
                annotation: ClipAnnotation(
                    title: "Variant 2 两挡渐进式浮窗与写作舱",
                    tags: ["synthetic-demo", "macos-hig", "nspanel"],
                    userNote: "第一挡保持轻量不抢焦点，勾选多条后按 Cmd+Return 展开第二挡递进写作舱。"
                )
            ),
            try NewClip(
                excerpt: "[SYNTHETIC-DEMO] Antigravity 2.x 的生命周期钩子仅注册 PascalCase 的 PostInvocation 与 Stop，严禁使用 PreToolUse，且必须在 50ms 内向 stdout 输出空 JSON 对象 {} 并以状态码 0 退出，绝不能输出 decision: continue 以免触发无限循环。",
                promptContext: .captured("[SYNTHETIC-DEMO] Antigravity App 2.31.0 的 hooks.json 与插件 mcp_config.json 有哪些必须遵守的宿主约束？"),
                source: .antigravity(
                    conversationId: "synthetic-demo-conv-002",
                    workspacePath: "/tmp/synthetic-coding-rewind-workspace",
                    locator: "conversation://synthetic-demo-conv-002"
                ),
                capturedAt: referenceDate.addingTimeInterval(-5400),
                annotation: ClipAnnotation(
                    title: "Antigravity 2.x 钩子非阻塞契约",
                    tags: ["synthetic-demo", "antigravity-hook", "mcp"],
                    userNote: "mcp_config.json 中唯有 args 支持展开 ${PLUGIN_ROOT}，因此使用 /bin/sh 包装脚本启动 rewind-mcp。"
                )
            ),
            try NewClip(
                excerpt: "[SYNTHETIC-DEMO] SQLite3 开启 WAL 模式与 FTS5 虚拟表后，主程序以读写模式在单事务中同步维护 clips 与 clips_fts，而 stdio MCP 服务以只读模式并发读取，删除单条或清空全部时同步清零倒排索引。",
                promptContext: .captured("[SYNTHETIC-DEMO] 本地自然语言检索和删除怎样确保被删掉的原文不会残留在搜索索引里？"),
                source: .web(
                    site: .claude,
                    url: "https://claude.ai/chat/synthetic-demo-003",
                    pageTitle: "[SYNTHETIC-DEMO] Claude Web 架构推演"
                ),
                capturedAt: referenceDate.addingTimeInterval(-14400),
                annotation: ClipAnnotation(
                    title: "SQLite WAL + FTS5 同步擦除保证",
                    tags: ["synthetic-demo", "sqlite-wal", "privacy"],
                    userNote: "配合 NaturalLanguage 分词与双字切分，离线支持中英文自然表述召回。"
                )
            ),
            try NewClip(
                excerpt: "[SYNTHETIC-DEMO] 当通过跨应用全局快捷键或网页端协议捕获选段但未能拿到触发提问时，必须将 promptContext 显式记为 .missing 并在卡片上标明「原问题缺失」，绝不编造虚假提问。",
                promptContext: .missing,
                source: .web(
                    site: .chatgpt,
                    url: "https://chatgpt.com/c/synthetic-demo-004",
                    pageTitle: "[SYNTHETIC-DEMO] ChatGPT Web 选段摘录"
                ),
                capturedAt: referenceDate.addingTimeInterval(-28800),
                annotation: ClipAnnotation(
                    title: nil,
                    tags: ["synthetic-demo"],
                    userNote: nil
                )
            )
        ]
    }
}
