// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import KeyboardShortcuts
import SwiftUI

public enum AppCommand: Equatable, Sendable {
    case toggleHUD
    case presentHUDAndFocus
    case captureSelection
    case captureSelectionHotkey
    case launchConversation
    case launchIn(ConversationHost)
    case copyDraftAndWakeHost
    case sendConversationDraft
    case refreshHotStream
    case openMemosWeb
    case installOrRepairPlugin
    case installOrRepairDSHPlugin
    case requestAccessibility
    case resetAccessibility
    case openSettings
    case checkForUpdates
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
        shortcuts: AppShortcuts,
        language: AppLanguage = .zhHans,
        onCommand: @escaping @MainActor (AppCommand) -> Void
    ) -> NSMenu {
        shortcuts.resetBoundMenuItems()
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "Coding Rewind", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Coding Rewind")
        appMenu.addItem(makeCommandMenuItem(title: AppStrings.aboutApp(in: language), command: .showAbout, handler: onCommand))
        appMenu.addItem(makeCommandMenuItem(title: AppStrings.checkForUpdatesMenu(in: language), command: .checkForUpdates, handler: onCommand))
        appMenu.addItem(.separator())
        appMenu.addItem(makeCommandMenuItem(title: AppStrings.settingsEllipsis(in: language), command: .openSettings, keyEquivalent: ",", handler: onCommand))
        appMenu.addItem(makeCommandMenuItem(title: AppStrings.installOrRepairAntigravityPlugin(in: language), command: .installOrRepairPlugin, handler: onCommand))
        appMenu.addItem(makeCommandMenuItem(title: AppStrings.installOrRepairDSHPlugin(in: language), command: .installOrRepairDSHPlugin, handler: onCommand))
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(title: AppStrings.hideApp(in: language), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: AppStrings.hideOthers(in: language), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: AppStrings.showAll(in: language), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAllItem)

        appMenu.addItem(.separator())
        appMenu.addItem(makeCommandMenuItem(title: AppStrings.quitApp(in: language), command: .quit, keyEquivalent: "q", handler: onCommand))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let actionsTitle = AppStrings.actionsMenuTitle(in: language)
        let actionsMenuItem = NSMenuItem(title: actionsTitle, action: nil, keyEquivalent: "")
        let actionsMenu = NSMenu(title: actionsTitle)
        let toggleItem = makeCommandMenuItem(title: ShortcutAction.toggleHUD.title(in: language), command: .toggleHUD, handler: onCommand)
        shortcuts.bindMenuItem(toggleItem, to: .toggleHUD)
        actionsMenu.addItem(toggleItem)
        let captureItem = makeCommandMenuItem(title: ShortcutAction.captureSelection.title(in: language), command: .captureSelection, handler: onCommand)
        shortcuts.bindMenuItem(captureItem, to: .captureSelection)
        actionsMenu.addItem(captureItem)
        actionsMenu.addItem(
            makeCommandMenuItem(
                title: AppStrings.startChatInSelectedApp(in: language),
                command: .launchConversation,
                keyEquivalent: "\r",
                modifiers: [.command],
                handler: onCommand
            )
        )
        for host in ConversationHost.allCases {
            actionsMenu.addItem(makeCommandMenuItem(
                title: AppStrings.startChatInHost(host, in: language),
                command: .launchIn(host),
                handler: onCommand
            ))
        }
        actionsMenu.addItem(
            makeCommandMenuItem(
                title: AppStrings.syncNow(in: language),
                command: .refreshHotStream,
                keyEquivalent: "r",
                modifiers: [.command],
                handler: onCommand
            )
        )
        actionsMenu.addItem(.separator())
        actionsMenu.addItem(makeCommandMenuItem(title: AppStrings.openMemosWeb(withArrow: false, in: language), command: .openMemosWeb, handler: onCommand))
        actionsMenuItem.submenu = actionsMenu
        mainMenu.addItem(actionsMenuItem)

        let editTitle = AppStrings.editMenuTitle(in: language)
        let editMenuItem = NSMenuItem(title: editTitle, action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: editTitle)
        let undoItem = NSMenuItem(title: AppStrings.undo(in: language), action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: AppStrings.redo(in: language), action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: AppStrings.cut(in: language), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: AppStrings.copy(in: language), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: AppStrings.paste(in: language), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: AppStrings.selectAll(in: language), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowTitle = AppStrings.windowMenuTitle(in: language)
        let windowMenuItem = NSMenuItem(title: windowTitle, action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: windowTitle)
        windowMenu.addItem(NSMenuItem(title: AppStrings.closeWindow(in: language), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(makeCommandMenuItem(title: AppStrings.bringHUDToFront(in: language), command: .presentHUDAndFocus, handler: onCommand))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }
}

@MainActor
public final class StatusItemIcon {
    public static let pointSize = NSSize(width: 18, height: 18)
    private static var cachedBaseTemplateImage: NSImage?

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
        if bundle == .main, let cached = cachedBaseTemplateImage {
            return cached
        }
        let image: NSImage
        if let url1x = bundle.url(forResource: "MenuBarIcon", withExtension: "png"),
           let data1x = try? Data(contentsOf: url1x),
           let rep1x = NSBitmapImageRep(data: data1x) {
            rep1x.size = pointSize
            let loaded = NSImage(size: pointSize)
            loaded.addRepresentation(rep1x)
            if let url2x = bundle.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
               let data2x = try? Data(contentsOf: url2x),
               let rep2x = NSBitmapImageRep(data: data2x) {
                rep2x.size = pointSize
                loaded.addRepresentation(rep2x)
            }
            loaded.isTemplate = true
            image = loaded
        } else {
            image = renderFallbackTemplateImage()
        }
        if bundle == .main {
            cachedBaseTemplateImage = image
        }
        return image
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

    private struct IconRenderKey: Equatable {
        let hasPendingOutbox: Bool
        let isDark: Bool
    }

    private let shortcuts: AppShortcuts
    private let snapshotProvider: @MainActor () -> MenuStatusSnapshot
    private let onCommand: @MainActor (AppCommand) -> Void
    private var appearanceObservation: NSKeyValueObservation?
    private var isPoppingUpMenu = false
    private var lastIconRenderKey: IconRenderKey?

    public init(
        shortcuts: AppShortcuts,
        language: AppLanguage = .zhHans,
        snapshotProvider: @escaping @MainActor () -> MenuStatusSnapshot,
        onCommand: @escaping @MainActor (AppCommand) -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: 28)
        self.menu = NSMenu(title: "Coding Rewind")
        self.shortcuts = shortcuts
        self.snapshotProvider = snapshotProvider
        self.onCommand = onCommand
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self

        if let button = statusItem.button {
            button.setAccessibilityLabel("Coding Rewind")
            button.toolTip = AppStrings.statusItemTooltip(in: language)
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

    public func updateLanguage(_ language: AppLanguage) {
        statusItem.button?.toolTip = AppStrings.statusItemTooltip(in: language)
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
        let lang = snapshot.language
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

        let toggleItem = makeCommandMenuItem(title: snapshot.toggleHUDTitle, command: .toggleHUD, handler: onCommand)
        shortcuts.applyMenuShortcut(to: toggleItem, for: .toggleHUD)
        menu.addItem(toggleItem)
        let captureItem = makeCommandMenuItem(
            title: ShortcutAction.captureSelection.title(in: lang),
            command: .captureSelection,
            handler: onCommand
        )
        shortcuts.applyMenuShortcut(to: captureItem, for: .captureSelection)
        menu.addItem(captureItem)
        menu.addItem(
            makeCommandMenuItem(
                title: snapshot.launchTitle,
                command: .launchConversation,
                keyEquivalent: "\r",
                modifiers: [.command],
                handler: onCommand
            )
        )
        for host in ConversationHost.allCases {
            menu.addItem(makeCommandMenuItem(
                title: AppStrings.startChatInHost(host, in: lang),
                command: .launchIn(host),
                handler: onCommand
            ))
        }
        menu.addItem(
            makeCommandMenuItem(
                title: AppStrings.syncNow(in: lang),
                command: .refreshHotStream,
                keyEquivalent: "r",
                modifiers: [.command],
                handler: onCommand
            )
        )

        if !snapshot.recentCards.isEmpty {
            let recentTitle = AppStrings.recentClips(in: lang)
            let recentRoot = NSMenuItem(title: recentTitle, action: nil, keyEquivalent: "")
            let recentMenu = NSMenu(title: recentTitle)
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

        let isMemosConfigured: Bool = {
            if case .configured = snapshot.connection { return true }
            return false
        }()
        menu.addItem(
            makeCommandMenuItem(
                title: AppStrings.openMemosWeb(withArrow: true, in: lang),
                command: .openMemosWeb,
                isEnabled: isMemosConfigured,
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: AppStrings.installOrRepairAntigravityPlugin(in: lang),
                command: .installOrRepairPlugin,
                state: snapshot.isPluginReady ? .on : .off,
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: AppStrings.installOrRepairDSHPlugin(in: lang),
                command: .installOrRepairDSHPlugin,
                state: snapshot.isDSHPluginReady ? .on : .off,
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: AppStrings.accessibilityStatusMenu(isTrusted: snapshot.isAccessibilityTrusted, in: lang),
                command: .requestAccessibility,
                state: snapshot.isAccessibilityTrusted ? .on : .off,
                handler: onCommand
            )
        )
        menu.addItem(
            makeCommandMenuItem(
                title: AppStrings.settingsEllipsis(in: lang),
                command: .openSettings,
                keyEquivalent: ",",
                modifiers: [.command],
                handler: onCommand
            )
        )

        menu.addItem(.separator())
        menu.addItem(
            makeCommandMenuItem(
                title: AppStrings.quitApp(in: lang),
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
        let effective = statusItem.button?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance
        let isDark = effective.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = IconRenderKey(hasPendingOutbox: snapshot.pendingOutboxCount > 0, isDark: isDark)
        if key == lastIconRenderKey && statusItem.button?.image != nil {
            return
        }
        lastIconRenderKey = key
        statusItem.button?.image = StatusItemIcon.makeImage(
            pendingOutboxCount: snapshot.pendingOutboxCount,
            appearance: effective
        )
        statusItem.button?.imagePosition = .imageOnly
    }
}

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: AppCoordinator
    private let loginItemController: LoginItemController?
    private let permissionState: AccessibilityPermissionState
    public let connectionDraft: SettingsConnectionDraft
    public let navigationModel: SettingsNavigationModel
    private let permissionPollInterval: Duration
    private var permissionPollTask: Task<Void, Never>?
    private var hasCenteredOnce = false

    public init(
        coordinator: AppCoordinator,
        appearance: AppAppearancePreferences,
        shortcuts: AppShortcuts,
        loginItemController: LoginItemController? = nil,
        updater: AppUpdater? = nil,
        permissionState: AccessibilityPermissionState = AccessibilityPermissionState(),
        connectionDraft: SettingsConnectionDraft? = nil,
        navigationModel: SettingsNavigationModel = SettingsNavigationModel(),
        permissionPollInterval: Duration = .seconds(1),
        onCommand: @escaping @MainActor (AppCommand) -> Void
    ) {
        let draft = connectionDraft ?? SettingsConnectionDraft(memosURL: coordinator.connectionSettings.memosURL)
        self.coordinator = coordinator
        self.loginItemController = loginItemController
        self.permissionState = permissionState
        self.connectionDraft = draft
        self.navigationModel = navigationModel
        self.permissionPollInterval = permissionPollInterval

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsLayout.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = AppStrings.settingsWindowTitle(in: appearance.effectiveLanguage)
        window.isReleasedWhenClosed = false
        let rootView = SettingsRootView(
            coordinator: coordinator,
            appearance: appearance,
            shortcuts: shortcuts,
            loginItemController: loginItemController,
            updater: updater,
            permissionState: permissionState,
            connectionDraft: draft,
            navigationModel: navigationModel,
            onCommand: onCommand,
            onClose: { [weak window] in
                window?.close()
            }
        )
        window.contentView = NSHostingView(rootView: rootView)
        window.setContentSize(SettingsLayout.contentSize)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func updateLanguage(_ language: AppLanguage) {
        window?.title = AppStrings.settingsWindowTitle(in: language)
        connectionDraft.updateLanguage(language)
    }

    public func show(page: SettingsPage? = nil) {
        let wasClosed = (window?.isVisible != true)
        if let page {
            navigationModel.selectedPage = page
        }
        coordinator.refreshAllSettingsState()
        loginItemController?.refresh()
        permissionState.refresh()
        if wasClosed {
            connectionDraft.reset(memosURL: coordinator.connectionSettings.memosURL)
        }
        if !hasCenteredOnce {
            window?.center()
            hasCenteredOnce = true
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.window?.isVisible == true {
                try? await Task.sleep(for: self.permissionPollInterval)
                guard !Task.isCancelled && self.window?.isVisible == true else { break }
                self.permissionState.refresh()
                self.loginItemController?.refresh()
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        permissionPollTask?.cancel()
        permissionPollTask = nil
    }

    public func refreshPermissions() {
        permissionState.refresh()
        loginItemController?.refresh()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        coordinator.refreshAllSettingsState()
        permissionState.refresh()
        loginItemController?.refresh()
    }
}
