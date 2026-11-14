// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import CodingRewindCore

@MainActor
enum NativeChatBacklink {
    private struct BrowserTab {
        let id: Int32
        let url: String
    }

    static func capture(host: NativeChatHost, application: AXUIElement, window: AXUIElement) async -> URL? {
        let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        let usesChrome = browser.flatMap { Bundle(url: $0)?.bundleIdentifier } == AppBundleID.chrome
        guard host == .chatGPT || usesChrome else { return nil }
        let before = usesChrome ? browserTabs() : []
        guard let before else { return nil }
        let originalWebAreas = descendants(window).filter { AXSupport.role($0) == "AXWebArea" }
        let originalCloseButtons = descendants(window).filter(isCloseTabButton)
        let previousIDs = Set(before.map(\.id))
        var pid: pid_t = 0
        guard AXUIElementGetPid(application, &pid) == .success,
              let source = NSRunningApplication(processIdentifier: pid) else { return nil }
        let button: AXUIElement?
        switch host {
        case .gemini:
            button = descendants(window).first { AXSupport.identifier($0) == "more_button" }
        case .chatGPT:
            button = descendants(window).first {
                AXSupport.role($0) == "AXPopUpButton" && AXSupport.title($0) == "Chat actions" && !isSidebarElement($0, window: window)
            }
        }
        guard let button else { return nil }
        source.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
        defer {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier == pid || front.bundleIdentifier == AppBundleID.chrome {
                source.activate()
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
            }
        }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        let labels = host == .gemini ? ["在浏览器中打开", "Open in browser"] : ["Open on chatgpt.com"]
        var item: AXUIElement?
        for _ in 0..<10 {
            item = menuElements(application: application, window: window).first {
                AXSupport.role($0) == "AXMenuItem" && labels.contains(AXSupport.title($0) ?? "")
            }
            if item != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let item else {
            if let menu = menuElements(application: application, window: window).first(where: {
                AXSupport.role($0) == "AXMenu" && !AXSupport.children($0).isEmpty
            }) {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
            return nil
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if host == .chatGPT {
                let nodes = descendants(window)
                let opened = nodes.filter { node in
                    AXSupport.role(node) == "AXWebArea" && !originalWebAreas.contains { CFEqual($0, node) }
                }
                let urls = opened.compactMap { node -> URL? in
                    conversationURL(AXSupport.urlString(node) ?? "", host: host)
                }
                if urls.count == 1 {
                    let closeButtons = nodes.filter { node in isCloseTabButton(node) && !originalCloseButtons.contains { CFEqual($0, node) } }
                    if closeButtons.count == 1 { AXUIElementPerformAction(closeButtons[0], kAXPressAction as CFString) }
                    return urls[0]
                }
            }
            guard usesChrome else { continue }
            guard let tabs = browserTabs() else { return nil }
            let candidates = tabs.filter { !previousIDs.contains($0.id) && conversationURL($0.url, host: host) != nil }
            guard candidates.count <= 1 else { return nil }
            if let tab = candidates.first, let url = conversationURL(tab.url, host: host) {
                close(tab)
                source.activate()
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
                for _ in 0..<10 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                       let focused = AXSupport.focusedWindow(application), CFEqual(focused, window) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return url
            }
        }
        return nil
    }

    private static func isCloseTabButton(_ node: AXUIElement) -> Bool {
        guard AXSupport.role(node) == "AXButton", let title = AXSupport.title(node) else { return false }
        return title.hasPrefix("Close ") && title.hasSuffix(" tab")
    }

    private static func menuElements(application: AXUIElement, window: AXUIElement) -> [AXUIElement] {
        AXSupport.children(application).filter {
            AXSupport.role($0) != kAXWindowRole || CFEqual($0, window)
        }.flatMap(descendants)
    }

    static func conversationURL(_ raw: String, host: NativeChatHost) -> URL? {
        guard let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil else { return nil }
        let components = parts.path.split(separator: "/")
        switch host {
        case .gemini:
            guard parts.host == "gemini.google.com", components.count == 2, components[0] == "app", !components[1].isEmpty else { return nil }
        case .chatGPT:
            guard parts.host == "chatgpt.com", components.count >= 2,
                  let index = components.firstIndex(of: "c"), index + 1 == components.count - 1,
                  UUID(uuidString: String(components[index + 1])) != nil else { return nil }
        }
        return url
    }

    private static func browserTabs() -> [BrowserTab]? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: AppBundleID.chrome).first != nil else { return [] }
        let script = """
        tell application id "\(AppBundleID.chrome)"
            set resultRows to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set end of resultRows to {id of t, URL of t}
                end repeat
            end repeat
            return resultRows
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil else { return nil }
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { index in
            guard let row = result.atIndex(index), let id = row.atIndex(1), let url = row.atIndex(2)?.stringValue else { return nil }
            return BrowserTab(id: id.int32Value, url: url)
        }
    }

    private static func close(_ tab: BrowserTab) {
        let escapedURL = tab.url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application id "\(AppBundleID.chrome)"
            repeat with w in windows
                repeat with t in tabs of w
                    if id of t is \(tab.id) and URL of t is "\(escapedURL)" then
                        close t
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    private static func isSidebarElement(_ node: AXUIElement, window: AXUIElement) -> Bool {
        var parent = AXSupport.parent(node)
        while let current = parent, !CFEqual(current, window) {
            if ["AXList", "AXOutline", "AXButton"].contains(AXSupport.role(current) ?? "") ||
                (AXSupport.subrole(current)?.lowercased().contains("navigation") == true) ||
                AXSupport.string(current, "AXDOMIdentifier") == "app-shell-sidebar" ||
                AXSupport.subrole(current) == "AXLandmarkComplementary" { return true }
            parent = AXSupport.parent(current)
        }
        return false
    }

    private static func descendants(_ root: AXUIElement) -> [AXUIElement] {
        if AXSupport.role(root) == kAXMenuBarRole { return [] }
        return [root] + AXSupport.children(root).flatMap(descendants)
    }
}
