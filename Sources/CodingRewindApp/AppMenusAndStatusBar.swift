// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import SwiftUI

public enum AppCommand: Equatable, Sendable {
    case toggleHUD
    case presentHUDAndFocus
    case captureSelectionFromMenu
    case captureSelectionHotkey
    case launchInAntigravity
    case refreshHotStream
    case openMemosWeb
    case installOrRepairPlugin
    case requestAccessibility
    case openSettings
    case selectRecentCard(String)
    case showAbout
    case quit
}

@MainActor
private final class CommandActionBox: NSObject {
    let command: AppCommand
    let handler: @MainActor (AppCommand) -> Void

    init(command: AppCommand, handler: @escaping @MainActor (AppCommand) -> Void) {
        self.command = command
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler(command)
    }
}

@MainActor
private func makeCommandMenuItem(
    title: String,
    command: AppCommand,
    keyEquivalent: String = "",
    modifiers: NSEvent.ModifierFlags = [.command],
    state: NSControl.StateValue = .off,
    isEnabled: Bool = true,
    handler: @escaping @MainActor (AppCommand) -> Void
) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: keyEquivalent)
    if !keyEquivalent.isEmpty {
        item.keyEquivalentModifierMask = modifiers
    }
    item.state = state
    item.isEnabled = isEnabled
    if isEnabled {
        let box = CommandActionBox(command: command, handler: handler)
        item.target = box
        item.action = #selector(CommandActionBox.invoke(_:))
        item.representedObject = box
    }
    return item
}

@MainActor
public enum MainMenuBuilder {
    public static func buildMainMenu(
        onCommand: @escaping @MainActor (AppCommand) -> Void
    ) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "Coding Rewind", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Coding Rewind")
        appMenu.addItem(makeCommandMenuItem(title: "关于 Coding Rewind", command: .showAbout, handler: onCommand))
        appMenu.addItem(.separator())
        appMenu.addItem(makeCommandMenuItem(title: "设置…", command: .openSettings, keyEquivalent: ",", handler: onCommand))
        appMenu.addItem(makeCommandMenuItem(title: "安装或检查 Antigravity 插件", command: .installOrRepairPlugin, handler: onCommand))
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(title: "隐藏 Coding Rewind", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAllItem)

        appMenu.addItem(.separator())
        appMenu.addItem(makeCommandMenuItem(title: "退出 Coding Rewind", command: .quit, keyEquivalent: "q", handler: onCommand))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let actionsMenuItem = NSMenuItem(title: "操作", action: nil, keyEquivalent: "")
        let actionsMenu = NSMenu(title: "操作")
        actionsMenu.addItem(
            makeCommandMenuItem(
                title: "切换 Rewind 浮窗",
                command: .toggleHUD,
                keyEquivalent: "r",
                modifiers: [.control, .option],
                handler: onCommand
            )
        )
        actionsMenu.addItem(
            makeCommandMenuItem(
                title: "捕获当前选段",
                command: .captureSelectionFromMenu,
                keyEquivalent: "s",
                modifiers: [.control, .option],
                handler: onCommand
            )
        )
        actionsMenu.addItem(
            makeCommandMenuItem(
                title: "在 Antigravity 开聊",
                command: .launchInAntigravity,
                keyEquivalent: "\r",
                modifiers: [.command],
                handler: onCommand
            )
        )
        actionsMenu.addItem(
            makeCommandMenuItem(
                title: "立即同步热流",
                command: .refreshHotStream,
                keyEquivalent: "r",
                modifiers: [.command],
                handler: onCommand
            )
        )
        actionsMenu.addItem(.separator())
        actionsMenu.addItem(makeCommandMenuItem(title: "打开 Memos 网页", command: .openMemosWeb, handler: onCommand))
        actionsMenuItem.submenu = actionsMenu
        mainMenu.addItem(actionsMenuItem)

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        let undoItem = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(makeCommandMenuItem(title: "前置 Rewind 浮窗", command: .presentHUDAndFocus, handler: onCommand))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }
}

@MainActor
public final class StatusItemIcon {
    public static let pointSize = NSSize(width: 18, height: 18)

    public static func makeImage(
        pendingOutboxCount: Int,
        appearance: NSAppearance? = nil,
        bundle: Bundle = .main
    ) -> NSImage {
        let baseTemplate = loadBaseTemplateImage(bundle: bundle)
        guard pendingOutboxCount > 0 else {
            return baseTemplate
        }

        let effective = appearance ?? NSApplication.shared.effectiveAppearance
        let isDark = effective.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fgColor = isDark
            ? CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.96)
            : CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.88)
        let amberColor = CGColor(srgbRed: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)

        let badged = NSImage(size: pointSize)
        for scale in [1, 2] {
            let px = 18 * scale
            guard let ctx = makeBitmapContext(pixelsWide: px, pixelsHigh: px) else { continue }
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

            var proposedRect = NSRect(origin: .zero, size: pointSize)
            if let baseCG = baseTemplate.cgImage(forProposedRect: &proposedRect, context: nil, hints: [.ctm: AffineTransform(scale: CGFloat(scale))]) {
                ctx.draw(baseCG, in: CGRect(x: 0, y: 0, width: 18, height: 18))
            } else {
                drawVectorGlyph(in: ctx, strokeColor: .black)
            }

            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(fgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 18, height: 18))

            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: 11.6, y: 11.6, width: 6.8, height: 6.8))

            ctx.setBlendMode(.normal)
            ctx.setFillColor(amberColor)
            ctx.fillEllipse(in: CGRect(x: 12.5, y: 12.5, width: 5.0, height: 5.0))

            if let cgImage = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                rep.size = pointSize
                badged.addRepresentation(rep)
            }
        }
        badged.isTemplate = false
        return badged
    }

    public static func loadBaseTemplateImage(bundle: Bundle = .main) -> NSImage {
        if let url1x = bundle.url(forResource: "MenuBarIcon", withExtension: "png"),
           let data1x = try? Data(contentsOf: url1x),
           let rep1x = NSBitmapImageRep(data: data1x) {
            rep1x.size = pointSize
            let image = NSImage(size: pointSize)
            image.addRepresentation(rep1x)
            if let url2x = bundle.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
               let data2x = try? Data(contentsOf: url2x),
               let rep2x = NSBitmapImageRep(data: data2x) {
                rep2x.size = pointSize
                image.addRepresentation(rep2x)
            }
            image.isTemplate = true
            return image
        }
        return renderFallbackTemplateImage()
    }

    public static func renderFallbackTemplateImage() -> NSImage {
        let image = NSImage(size: pointSize)
        for scale in [1, 2] {
            let px = 18 * scale
            guard let ctx = makeBitmapContext(pixelsWide: px, pixelsHigh: px) else { continue }
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            drawVectorGlyph(in: ctx, strokeColor: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            if let cgImage = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                rep.size = pointSize
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        return image
    }

    private static func makeBitmapContext(pixelsWide: Int, pixelsHigh: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: pixelsWide * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func drawVectorGlyph(in ctx: CGContext, strokeColor: CGColor) {
        let card = CGMutablePath()
        card.move(to: CGPoint(x: 4.0, y: 2.5))
        card.addQuadCurve(to: CGPoint(x: 2.5, y: 4.0), control: CGPoint(x: 2.5, y: 2.5))
        card.addLine(to: CGPoint(x: 2.5, y: 13.0))
        card.addQuadCurve(to: CGPoint(x: 4.0, y: 14.5), control: CGPoint(x: 2.5, y: 14.5))
        card.addLine(to: CGPoint(x: 12.1, y: 14.5))
        card.addLine(to: CGPoint(x: 15.5, y: 11.1))
        card.addLine(to: CGPoint(x: 15.5, y: 4.0))
        card.addQuadCurve(to: CGPoint(x: 14.0, y: 2.5), control: CGPoint(x: 15.5, y: 2.5))
        card.closeSubpath()
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(1.35)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(card)
        ctx.strokePath()

        ctx.move(to: CGPoint(x: 12.1, y: 14.5))
        ctx.addLine(to: CGPoint(x: 12.1, y: 11.1))
        ctx.addLine(to: CGPoint(x: 15.5, y: 11.1))
        ctx.strokePath()

        ctx.move(to: CGPoint(x: 5.1, y: 8.8))
        ctx.addLine(to: CGPoint(x: 12.2, y: 8.8))
        ctx.move(to: CGPoint(x: 5.1, y: 6.0))
        ctx.addLine(to: CGPoint(x: 9.4, y: 6.0))
        ctx.strokePath()
    }
}

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    public let statusItem: NSStatusItem
    public let menu: NSMenu

    private let snapshotProvider: @MainActor () -> MenuStatusSnapshot
    private let onCommand: @MainActor (AppCommand) -> Void
    private var appearanceObservation: NSKeyValueObservation?
    private var isPoppingUpMenu = false

    public init(
        snapshotProvider: @escaping @MainActor () -> MenuStatusSnapshot,
        onCommand: @escaping @MainActor (AppCommand) -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: 28)
        self.menu = NSMenu(title: "Coding Rewind")
        self.snapshotProvider = snapshotProvider
        self.onCommand = onCommand
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self

        if let button = statusItem.button {
            button.setAccessibilityLabel("Coding Rewind")
            button.toolTip = "Coding Rewind — 左键打开菜单，右键或 ⌥点击切换浮窗"
            button.target = self
            button.action = #selector(handleStatusButtonClick(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshIcon()
                }
            }
        }
        refreshIcon()
    }

    public var anchorFrame: NSRect? {
        statusItem.button?.window?.frame
    }

    public func refreshIcon() {
        let snapshot = snapshotProvider()
        applyIcon(for: snapshot)
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        guard !isPoppingUpMenu else { return }
        let event = NSApplication.shared.currentEvent
        let isRightClick = event?.type == .rightMouseDown
            || event?.type == .rightMouseUp
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        let isOptionClick = event?.modifierFlags.contains(.option) == true

        if isRightClick || isOptionClick {
            onCommand(.toggleHUD)
            return
        }

        isPoppingUpMenu = true
        defer {
            statusItem.menu = nil
            isPoppingUpMenu = false
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let snapshot = snapshotProvider()
        applyIcon(for: snapshot)
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: snapshot.headerTitle, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        titleItem.attributedTitle = NSAttributedString(
            string: snapshot.headerTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        menu.addItem(titleItem)

        let subtitleItem = NSMenuItem(title: snapshot.headerSubtitle, action: nil, keyEquivalent: "")
        subtitleItem.isEnabled = false
        subtitleItem.attributedTitle = NSAttributedString(
            string: snapshot.headerSubtitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menu.addItem(subtitleItem)

        menu.addItem(.separator())

        menu.addItem(
            makeCommandMenuItem(
                title: snapshot.toggleHUDTitle,
                command: .toggleHUD,
                keyEquivalent: "r",
                modifiers: [.control, .option],
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: "捕获当前选段",
                command: .captureSelectionFromMenu,
                keyEquivalent: "s",
                modifiers: [.control, .option],
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: snapshot.launchTitle,
                command: .launchInAntigravity,
                keyEquivalent: "\r",
                modifiers: [.command],
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: "立即同步热流",
                command: .refreshHotStream,
                keyEquivalent: "r",
                modifiers: [.command],
                handler: onCommand
            )
        )

        if !snapshot.recentCards.isEmpty {
            let recentRoot = NSMenuItem(title: "近期热卡", action: nil, keyEquivalent: "")
            let recentMenu = NSMenu(title: "近期热卡")
            recentMenu.autoenablesItems = false
            for card in snapshot.recentCards.prefix(5) {
                recentMenu.addItem(
                    makeCommandMenuItem(
                        title: "\(card.titlePreview) · #\(card.sourcePlatform)",
                        command: .selectRecentCard(card.id),
                        state: card.isChecked ? .on : .off,
                        handler: onCommand
                    )
                )
            }
            recentRoot.submenu = recentMenu
            menu.addItem(recentRoot)
        }

        menu.addItem(.separator())

        let isMemosConnected: Bool = {
            if case .connected = snapshot.connection { return true }
            return false
        }()
        menu.addItem(
            makeCommandMenuItem(
                title: "打开 Memos 网页 ↗",
                command: .openMemosWeb,
                isEnabled: isMemosConnected,
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: snapshot.isPluginReady ? "Antigravity 插件：已就绪（点击重检）" : "安装 Antigravity 插件…",
                command: .installOrRepairPlugin,
                state: snapshot.isPluginReady ? .on : .off,
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: snapshot.isAccessibilityTrusted ? "辅助功能权限：已授权" : "辅助功能权限：点击授权…",
                command: .requestAccessibility,
                state: snapshot.isAccessibilityTrusted ? .on : .off,
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: "设置…",
                command: .openSettings,
                keyEquivalent: ",",
                modifiers: [.command],
                handler: onCommand
            )
        )

        menu.addItem(.separator())
        menu.addItem(makeCommandMenuItem(title: "关于 Coding Rewind", command: .showAbout, handler: onCommand))
        menu.addItem(
            makeCommandMenuItem(
                title: "退出 Coding Rewind",
                command: .quit,
                keyEquivalent: "q",
                modifiers: [.command],
                handler: onCommand
            )
        )
    }

    public func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func applyIcon(for snapshot: MenuStatusSnapshot) {
        statusItem.button?.image = StatusItemIcon.makeImage(
            pendingOutboxCount: snapshot.pendingOutboxCount,
            appearance: statusItem.button?.effectiveAppearance
        )
        statusItem.button?.imagePosition = .imageOnly
    }
}

@MainActor
public final class SettingsWindowController: NSWindowController {
    private let coordinator: AppCoordinator
    private let onInstallPlugin: @MainActor () -> Void
    private let onRequestAccessibility: @MainActor () -> Void
    private let hostingView: NSHostingView<SettingsFormView>
    private var hasCenteredOnce = false

    public init(
        coordinator: AppCoordinator,
        onInstallPlugin: @escaping @MainActor () -> Void,
        onRequestAccessibility: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        self.onInstallPlugin = onInstallPlugin
        self.onRequestAccessibility = onRequestAccessibility

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 468, height: 324),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Coding Rewind 设置"
        window.level = .floating
        window.isReleasedWhenClosed = false

        let placeholderView = SettingsFormView(
            coordinator: coordinator,
            onInstallPlugin: onInstallPlugin,
            onRequestAccessibility: onRequestAccessibility,
            onClose: {}
        )
        self.hostingView = NSHostingView(rootView: placeholderView)
        super.init(window: window)

        self.hostingView.rootView = makeRootView()
        window.contentView = self.hostingView
        window.setContentSize(NSSize(width: 468, height: 324))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show() {
        coordinator.refreshPluginStatus()
        hostingView.rootView = makeRootView()
        if !hasCenteredOnce {
            window?.center()
            hasCenteredOnce = true
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeRootView() -> SettingsFormView {
        SettingsFormView(
            coordinator: coordinator,
            onInstallPlugin: onInstallPlugin,
            onRequestAccessibility: onRequestAccessibility,
            onClose: { [weak self] in
                self?.window?.close()
            }
        )
    }
}
