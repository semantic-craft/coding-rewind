// SPDX-License-Identifier: MIT

import AppKit
import Carbon
import CodingRewindCore
import Foundation
import Observation
import ServiceManagement

public struct LaunchContext: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case interactive
        case commandLineBackground
        case systemLoginItem
        case relaunchedAfterUpdate
    }

    public static let restartedAfterUpdateFlag = "--restarted-after-update"
    public static let backgroundFlag = "--background"

    public let reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }

    public var shouldPresentHUDOnInitialLaunch: Bool {
        reason == .interactive
    }

    @MainActor
    public static func captureCurrent(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appleEventDescriptor: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> LaunchContext {
        _ = environment
        if arguments.contains(restartedAfterUpdateFlag) {
            return LaunchContext(reason: .relaunchedAfterUpdate)
        }
        if arguments.contains(backgroundFlag) {
            return LaunchContext(reason: .commandLineBackground)
        }
        if let descriptor = appleEventDescriptor,
           descriptor.eventClass == AEEventClass(kCoreEventClass),
           descriptor.eventID == AEEventID(kAEOpenApplication),
           descriptor.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == DescType(keyAELaunchedAsLogInItem) {
            return LaunchContext(reason: .systemLoginItem)
        }
        return LaunchContext(reason: .interactive)
    }
}

public enum LoginItemUnavailableReason: Equatable, Sendable {
    case qaIsolated
    case unbundledExecutable
}

public enum LoginItemState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable(LoginItemUnavailableReason)

    public var isToggleOn: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unavailable:
            return false
        }
    }
}

@MainActor
public protocol LoginItemBackend {
    func currentState() -> LoginItemState
    func setEnabled(_ enabled: Bool) throws -> LoginItemState
    func openSystemSettings()
}

@MainActor
public struct SMAppServiceBackend: LoginItemBackend {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public func currentState() -> LoginItemState {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    public func setEnabled(_ enabled: Bool) throws -> LoginItemState {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
        return currentState()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
public final class InMemoryLoginItemBackend: LoginItemBackend {
    public var state: LoginItemState
    public var approvalRequiredOnEnable: Bool
    public var simulatedError: (any Error)?
    public private(set) var openSettingsCallCount = 0

    public init(
        initialState: LoginItemState = .disabled,
        approvalRequiredOnEnable: Bool = false,
        simulatedError: (any Error)? = nil
    ) {
        self.state = initialState
        self.approvalRequiredOnEnable = approvalRequiredOnEnable
        self.simulatedError = simulatedError
    }

    public func currentState() -> LoginItemState {
        state
    }

    public func setEnabled(_ enabled: Bool) throws -> LoginItemState {
        if case .unavailable = state {
            return state
        }
        if let simulatedError {
            throw simulatedError
        }
        if enabled {
            state = approvalRequiredOnEnable ? .requiresApproval : .enabled
        } else {
            state = .disabled
        }
        return state
    }

    public func openSystemSettings() {
        openSettingsCallCount += 1
    }
}

@MainActor
@Observable
public final class LoginItemController {
    public private(set) var state: LoginItemState
    private var lastErrorDetail: String?
    public var language: AppLanguage {
        didSet {
            if let lastErrorDetail {
                errorMessage = Self.formatError(detail: lastErrorDetail, in: language)
            }
        }
    }
    public private(set) var errorMessage: String?
    private let backend: any LoginItemBackend

    public init(backend: any LoginItemBackend, language: AppLanguage = .zhHans) {
        self.backend = backend
        self.language = language
        self.state = backend.currentState()
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        language: AppLanguage = .zhHans
    ) -> LoginItemController {
        if environment[StoragePaths.qaEnvironmentKey] == "1" {
            return LoginItemController(
                backend: InMemoryLoginItemBackend(initialState: .disabled),
                language: language
            )
        }
        if bundleURL.pathExtension.lowercased() != "app" {
            return LoginItemController(
                backend: InMemoryLoginItemBackend(initialState: .unavailable(.unbundledExecutable)),
                language: language
            )
        }
        return LoginItemController(backend: SMAppServiceBackend(), language: language)
    }

    public func refresh() {
        state = backend.currentState()
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            state = try backend.setEnabled(enabled)
            lastErrorDetail = nil
            errorMessage = nil
        } catch {
            state = backend.currentState()
            let detail = error.localizedDescription
            lastErrorDetail = detail
            errorMessage = Self.formatError(detail: detail, in: language)
        }
    }

    public func openSystemSettings() {
        backend.openSystemSettings()
    }

    private static func formatError(detail: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return "无法更新开机自启动设置：\(detail)"
        case .en:
            return "Could not update Launch at Login: \(detail)"
        }
    }
}
