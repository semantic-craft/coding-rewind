// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation

public struct LaunchOptions: Equatable, Sendable {
    public var storageRootPath: String?
    public var seedSyntheticDemo: Bool = false
    public var simulateCaptureError: Bool = false
    public var showHUD: Bool = false
    public var showStudio: Bool = false
    public var openChatDrawer: Bool = false
    public var verifyUIArtifactsDirectory: String?

    public static func parse(arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--storage-root":
                if index + 1 < arguments.count {
                    options.storageRootPath = arguments[index + 1]
                    index += 1
                }
            case "--seed-synthetic-demo":
                options.seedSyntheticDemo = true
            case "--simulate-capture-error":
                options.simulateCaptureError = true
            case "--show-hud", "--open-hud":
                options.showHUD = true
            case "--show-studio", "--open-studio":
                options.showStudio = true
            case "--open-chat-drawer", "--open-drawer":
                options.openChatDrawer = true
                options.showStudio = true
            case "--verify-ui-artifacts":
                if index + 1 < arguments.count {
                    options.verifyUIArtifactsDirectory = arguments[index + 1]
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
        return options
    }
}

@MainActor
public final class CodingRewindAppDelegate: NSObject, NSApplicationDelegate {
    public var coordinator: AppCoordinator?
    public var hudPanel: QuickPeekHUDPanel?
    public var studioWindowController: WritingStudioWindowController?
    public var shortcutMonitor: GlobalShortcutMonitor?
    private var statusItem: NSStatusItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse(arguments: CommandLine.arguments)
        do {
            let paths: StoragePaths
            if let root = options.storageRootPath, !root.isEmpty {
                let rootURL = URL(fileURLWithPath: root, isDirectory: true)
                paths = try StoragePaths(
                    appSupportDirectoryURL: rootURL.appendingPathComponent("AppSupport", isDirectory: true),
                    antigravityConfigDirectoryURL: rootURL.appendingPathComponent("GeminiConfig", isDirectory: true)
                )
            } else {
                paths = try StoragePaths.defaultUserPaths()
            }

            let stash = try StashStore(location: .sqliteFile(paths.stashDatabaseURL), mode: .readWrite)
            let drafts = try DraftStore(directoryURL: paths.draftsDirectoryURL)
            let activeTurns = try ActiveTurnStore(directoryURL: paths.runtimeDirectoryURL)

            let coord = AppCoordinator(
                paths: paths,
                stash: stash,
                drafts: drafts,
                activeTurns: activeTurns,
                capturer: MacOSAccessibilitySelectionCapturer()
            )
            coord.onCopyTextToPasteboard = { text in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
            coord.onOpenExternalURL = { url in
                NSWorkspace.shared.open(url)
            }
            self.coordinator = coord

            let studioWC = WritingStudioWindowController(
                coordinator: coord,
                onInstallPlugin: { [weak self] in
                    self?.installOrRepairAntigravityIntegration()
                }
            )
            self.studioWindowController = studioWC

            let hud = QuickPeekHUDPanel(
                coordinator: coord,
                onRequestOpenStudio: { [weak self] openDrawer in
                    guard let self, let coord = self.coordinator else { return }
                    Task { @MainActor in
                        await coord.openStudioWithCheckedClips(openChatDrawer: openDrawer)
                        self.studioWindowController?.presentStudio()
                    }
                }
            )
            self.hudPanel = hud

            setupStatusItem()
            setupGlobalShortcuts()

            Task { @MainActor in
                if options.seedSyntheticDemo {
                    await seedDemoIfNeeded(into: stash, coordinator: coord)
                }
                await coord.refreshHUDClips()
                if options.simulateCaptureError {
                    coord.simulateFailedCaptureBanner()
                }
                if options.showStudio {
                    await coord.openStudioWithCheckedClips(openChatDrawer: options.openChatDrawer)
                    if options.openChatDrawer {
                        await coord.submitStudioPrompt(
                            "梳理不抢焦点 HUD 与 Antigravity 2.x 非阻塞钩子的成文提纲",
                            insertDirectlyIntoDraft: false
                        )
                    }
                    self.studioWindowController?.presentStudio()
                }
                if let verifyDir = options.verifyUIArtifactsDirectory, !verifyDir.isEmpty {
                    await self.runInProcessUIVerification(outputDirectoryPath: verifyDir, coordinator: coord)
                    NSApplication.shared.terminate(nil)
                    return
                }
                if options.showHUD || (!options.showStudio) {
                    self.hudPanel?.presentNonActivating()
                }
            }
        } catch {
            NSLog("CodingRewindApp startup error: \(error.localizedDescription)")
        }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard let coord = coordinator else { return }
        for url in urls {
            Task { @MainActor in
                let isSilent = (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name.lowercased() == "silent" })?
                    .value?
                    .lowercased() == "true")
                await coord.handleIncomingURL(url, clipboardReader: {
                    NSPasteboard.general.string(forType: .string)
                })
                self.hudPanel?.presentNonActivating()
                if !isSilent {
                    self.studioWindowController?.presentStudio()
                }
            }
        }
    }

    private func seedDemoIfNeeded(into stash: StashStore, coordinator: AppCoordinator) async {
        let existing = (try? await stash.clips(matching: ClipQuery(text: nil, scope: .all, limit: 10))) ?? []
        if existing.isEmpty {
            if let seeds = try? SyntheticDemoSeed.makeDemoClips() {
                for seed in seeds {
                    _ = try? await stash.capture(seed)
                }
            }
        }
        await coordinator.refreshHUDClips()
        for clip in coordinator.hudClips.prefix(2) {
            coordinator.checkedClipIDs.insert(clip.id)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Coding-Rewind")
            button.title = " Rewind"
        }

        let menu = NSMenu()
        let toggleHUDItem = NSMenuItem(
            title: "切换速览浮窗 (Gear 1 · ⌃⌥Space)",
            action: #selector(handleToggleHUDMenuAction),
            keyEquivalent: ""
        )
        toggleHUDItem.target = self
        menu.addItem(toggleHUDItem)

        let captureItem = NSMenuItem(
            title: "静默捕获当前选段 (⌃⌥S)",
            action: #selector(handleCaptureSelectionMenuAction),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let openStudioItem = NSMenuItem(
            title: "打开递进写作舱 (Gear 2 · ⌘↵)",
            action: #selector(handleOpenStudioMenuAction),
            keyEquivalent: ""
        )
        openStudioItem.target = self
        menu.addItem(openStudioItem)

        let openDrawerItem = NSMenuItem(
            title: "打开写作舱并展开右侧对话栏",
            action: #selector(handleOpenStudioWithDrawerMenuAction),
            keyEquivalent: ""
        )
        openDrawerItem.target = self
        menu.addItem(openDrawerItem)

        menu.addItem(.separator())

        let pluginItem = NSMenuItem(
            title: "安装/检查 Antigravity 2.x 插件与 MCP",
            action: #selector(handleInstallPluginMenuAction),
            keyEquivalent: ""
        )
        pluginItem.target = self
        menu.addItem(pluginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Coding-Rewind",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    private func setupGlobalShortcuts() {
        let monitor = GlobalShortcutMonitor(
            onCaptureSelection: { [weak self] in
                guard let self, let coord = self.coordinator else { return }
                Task { @MainActor in
                    await coord.captureSelectionFromHotkey()
                    self.hudPanel?.presentNonActivating()
                }
            },
            onToggleHUD: { [weak self] in
                self?.hudPanel?.toggleQuickPeek()
            }
        )
        monitor.register()
        self.shortcutMonitor = monitor
    }

    private func installOrRepairAntigravityIntegration() {
        guard let coord = coordinator else { return }
        let bundleURL = Bundle.main.bundleURL
        let helpersDir = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        let hookURL: URL
        let mcpURL: URL
        if FileManager.default.isExecutableFile(atPath: helpersDir.appendingPathComponent("coding-rewind-hook").path) {
            hookURL = helpersDir.appendingPathComponent("coding-rewind-hook")
            mcpURL = helpersDir.appendingPathComponent("rewind-mcp")
        } else {
            hookURL = executableDir.appendingPathComponent("coding-rewind-hook")
            mcpURL = executableDir.appendingPathComponent("rewind-mcp")
        }

        coord.installOrVerifyAntigravityPlugin(
            binaries: AntigravityIntegration.BinaryLocations(
                antigravityBridgeExecutableURL: hookURL,
                rewindMCPExecutableURL: mcpURL
            )
        )
    }

    @objc private func handleToggleHUDMenuAction() {
        hudPanel?.toggleQuickPeek()
    }

    @objc private func handleCaptureSelectionMenuAction() {
        guard let coord = coordinator else { return }
        Task { @MainActor in
            await coord.captureSelectionFromHotkey()
            self.hudPanel?.presentNonActivating()
        }
    }

    @objc private func handleOpenStudioMenuAction() {
        guard let coord = coordinator else { return }
        Task { @MainActor in
            await coord.openStudioWithCheckedClips(openChatDrawer: false)
            self.studioWindowController?.presentStudio()
        }
    }

    @objc private func handleOpenStudioWithDrawerMenuAction() {
        guard let coord = coordinator else { return }
        Task { @MainActor in
            await coord.openStudioWithCheckedClips(openChatDrawer: true)
            self.studioWindowController?.presentStudio()
        }
    }

    @objc private func handleInstallPluginMenuAction() {
        installOrRepairAntigravityIntegration()
    }

    private func captureWindowPNG(_ window: NSWindow, to outputURL: URL) throws {
        guard let contentView = window.contentView else {
            throw NSError(domain: "CodingRewindUIVerify", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing contentView"])
        }
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(domain: "CodingRewindUIVerify", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not allocate bitmapImageRep"])
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CodingRewindUIVerify", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try pngData.write(to: outputURL, options: .atomic)
    }

    private func runInProcessUIVerification(outputDirectoryPath: String, coordinator: AppCoordinator) async {
        let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard let hud = self.hudPanel, let studioWC = self.studioWindowController, let studioWin = studioWC.window else {
            return
        }

        hud.presentNonActivating()
        coordinator.simulateFailedCaptureBanner()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let hudPNG = outDir.appendingPathComponent("native-gear1-hud-m25-banner.png")
        try? captureWindowPNG(hud, to: hudPNG)

        coordinator.dismissBanner()
        await coordinator.openStudioWithCheckedClips(openChatDrawer: false)
        studioWC.presentStudio()
        let drawerBeforeToggle = coordinator.studioState?.isChatDrawerPresented ?? true
        try? await Task.sleep(nanoseconds: 250_000_000)
        let studioCleanPNG = outDir.appendingPathComponent("native-gear2-studio-clean.png")
        try? captureWindowPNG(studioWin, to: studioCleanPNG)

        coordinator.toggleChatDrawer()
        let drawerAfterToggle = coordinator.studioState?.isChatDrawerPresented ?? false
        await coordinator.submitStudioPrompt(
            "对比这两条暂存卡片在零阻塞与索引清零上的设计共性",
            insertDirectlyIntoDraft: false
        )
        if let assistantReply = coordinator.studioState?.chatConversation.last {
            await coordinator.insertIntoDraft(
                assistantReply.text,
                citing: Set(assistantReply.citedClipIDs)
            )
        }
        await coordinator.saveActiveDraft()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let studioDrawerPNG = outDir.appendingPathComponent("native-gear2-studio-drawer-open.png")
        try? captureWindowPNG(studioWin, to: studioDrawerPNG)

        let draftURL = coordinator.studioState?.activeDraft.fileURL
        let draftExists = draftURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let draftBytes = (draftURL.flatMap { try? Data(contentsOf: $0).count }) ?? 0

        let report: [String: Any] = [
            "hudIsNonActivatingPanel": hud.styleMask.contains(.nonactivatingPanel),
            "hudIsFloatingPanel": hud.isFloatingPanel,
            "hudWidth": Int(hud.frame.width),
            "hudHeight": Int(hud.frame.height),
            "hudVisibleClipCount": coordinator.hudClips.count,
            "studioWidth": Int(studioWin.frame.width),
            "studioHeight": Int(studioWin.frame.height),
            "pinnedClipCount": coordinator.studioState?.pinnedClips.count ?? 0,
            "isChatDrawerPresentedBeforeToggle": drawerBeforeToggle,
            "isChatDrawerPresentedAfterToggle": drawerAfterToggle,
            "chatTurnCount": coordinator.studioState?.chatConversation.count ?? 0,
            "draftPath": draftURL?.path ?? "",
            "draftExistsOnDisk": draftExists,
            "draftByteCount": draftBytes
        ]
        if let reportData = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? reportData.write(to: outDir.appendingPathComponent("native-ui-verification.json"), options: .atomic)
        }
    }
}

@main
struct CodingRewindAppMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = CodingRewindAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
