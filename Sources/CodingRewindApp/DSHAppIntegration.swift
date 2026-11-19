// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Darwin
import Foundation

@MainActor
public enum DSHAppIntegration {
    public static func bundledPluginDirectoryURL(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
        fileManager: FileManager = .default
    ) -> URL? {
        let bundled = bundleURL
            .appendingPathComponent("Contents/Resources/dsh-plugin", isDirectory: true)
            .appendingPathComponent(DSHIntegration.pluginName, isDirectory: true)
        if DSHIntegration.isValidSourcePluginDirectory(bundled, fileManager: fileManager) {
            return bundled
        }

        let searchRoots = [
            executableURL.deletingLastPathComponent(),
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        ]
        for start in searchRoots {
            var cursor = start.standardizedFileURL
            for _ in 0..<8 {
                let candidate = cursor
                    .appendingPathComponent("dsh-plugin", isDirectory: true)
                    .appendingPathComponent(DSHIntegration.pluginName, isDirectory: true)
                if DSHIntegration.isValidSourcePluginDirectory(candidate, fileManager: fileManager) {
                    return candidate
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        return nil
    }

    public static func resolveDSHBinaryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppBundleID.dsh)
        return DSHIntegration.resolveDSHBinaryURL(
            environment: environment,
            applicationURL: appURL
        )
    }

    public static func wakeDSH() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppBundleID.dsh) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            return
        }
        if let url = URL(string: "dsh://open") {
            _ = NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    public static func activateDSH(orderOutHUD: (() -> Void)? = nil) -> Bool {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppBundleID.dsh) {
            orderOutHUD?()
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppBundleID.dsh)
                .first(where: { !$0.isTerminated }) {
                NSApplication.shared.yieldActivation(to: running)
                _ = running.activate()
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            return true
        }
        if let url = URL(string: "dsh://open") {
            orderOutHUD?()
            return NSWorkspace.shared.open(url)
        }
        return false
    }
}

@MainActor
public final class DSHCaptureBridgeWatcher {
    private let store: DSHCaptureBridgeStore
    private let pollInterval: Duration
    private let handler: @MainActor (DSHCaptureBridgeRequest) async -> DSHCaptureBridgeReceipt
    private let onProcessed: (@MainActor () -> Void)?

    private var directorySource: DispatchSourceFileSystemObject?
    private var pollTask: Task<Void, Never>?
    private var isRunning = false
    private var isDraining = false
    private var needsAnotherPass = false

    public init(
        store: DSHCaptureBridgeStore,
        pollInterval: Duration = .milliseconds(250),
        handler: @escaping @MainActor (DSHCaptureBridgeRequest) async -> DSHCaptureBridgeReceipt,
        onProcessed: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.pollInterval = pollInterval
        self.handler = handler
        self.onProcessed = onProcessed
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let fd = open(store.requestsDirectory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename],
                queue: DispatchQueue.main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.drainOnce()
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            directorySource = source
        }

        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainOnce()
            while !Task.isCancelled && self.isRunning {
                try? await Task.sleep(for: self.pollInterval)
                guard !Task.isCancelled && self.isRunning else { break }
                await self.drainOnce()
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        directorySource?.cancel()
        directorySource = nil
    }

    public func drainOnce() async {
        guard isRunning else { return }
        if isDraining {
            needsAnotherPass = true
            return
        }
        isDraining = true
        defer { isDraining = false }

        repeat {
            needsAnotherPass = false
            let pending = (try? store.pendingRequests()) ?? []
            var handledAny = false
            for request in pending {
                guard isRunning else { return }
                let receipt = await handler(request)
                try? store.consumeAndRecordReceipt(receipt)
                handledAny = true
            }
            if handledAny {
                onProcessed?()
            }
        } while needsAnotherPass && isRunning
    }
}
