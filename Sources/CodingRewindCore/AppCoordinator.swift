// SPDX-License-Identifier: MIT

import Foundation
import Observation

public protocol SelectionCapturing: Sendable {
    func captureFrontmostSelection() async throws -> CapturedSelection
}

public enum CaptureError: Error, LocalizedError, Equatable, Sendable {
    case accessibilityPermissionDenied
    case noFrontmostApplication
    case emptySelection
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "未获得 macOS 辅助功能 (Accessibility) 权限，无法读取当前窗口选中文本。"
        case .noFrontmostApplication:
            return "未检测到当前前台应用窗口。"
        case .emptySelection:
            return "当前未选中任何非空文本，请先高亮一段对话再按捕获快捷键。"
        case .persistenceFailed(let detail):
            return "保存片段到本地归档失败: \(detail)"
        }
    }
}

public struct SimulatedSelectionCapturer: SelectionCapturing {
    public let nextResult: Result<CapturedSelection, CaptureError>

    public init(nextResult: Result<CapturedSelection, CaptureError>) {
        self.nextResult = nextResult
    }

    public func captureFrontmostSelection() async throws -> CapturedSelection {
        try nextResult.get()
    }
}

public enum HUDBanner: Equatable, Sendable {
    case capturedToast(clipID: ClipID, excerptPreview: String, sourceLabel: String)
    case errorBanner(title: String, detail: String)
}

public struct StudioWorkspaceState: Equatable, Sendable {
    public var activeDraft: DraftDocument
    public var pinnedClips: [Clip]
    public var expandedClipIDs: Set<ClipID>
    public var isInlineSynthesisBarPresented: Bool
    public var inlinePromptText: String
    public var isChatDrawerPresented: Bool
    public var chatInputText: String
    public var chatConversation: [ChatTurn]
    public var synthesisBackend: SynthesisBackend
    public var isSynthesizing: Bool

    public init(
        activeDraft: DraftDocument,
        pinnedClips: [Clip],
        expandedClipIDs: Set<ClipID> = [],
        isInlineSynthesisBarPresented: Bool = true,
        inlinePromptText: String = "",
        isChatDrawerPresented: Bool = false,
        chatInputText: String = "",
        chatConversation: [ChatTurn] = [],
        synthesisBackend: SynthesisBackend = .localOutline,
        isSynthesizing: Bool = false
    ) {
        self.activeDraft = activeDraft
        self.pinnedClips = pinnedClips
        self.expandedClipIDs = expandedClipIDs
        self.isInlineSynthesisBarPresented = isInlineSynthesisBarPresented
        self.inlinePromptText = inlinePromptText
        self.isChatDrawerPresented = isChatDrawerPresented
        self.chatInputText = chatInputText
        self.chatConversation = chatConversation
        self.synthesisBackend = synthesisBackend
        self.isSynthesizing = isSynthesizing
    }
}

@MainActor
@Observable
public final class AppCoordinator {
    public let paths: StoragePaths
    public let stash: StashStore
    public let drafts: DraftStore
    public let activeTurns: ActiveTurnStore
    public var capturer: any SelectionCapturing
    public let synthesizer: StudioSynthesizer

    public var hudClips: [Clip] = []
    public var hudScope: ClipScope = .hot
    public var hudSearchText: String = ""
    public var checkedClipIDs: Set<ClipID> = []
    public var expandedHUDClipIDs: Set<ClipID> = []
    public var hudBanner: HUDBanner?
    public var studioState: StudioWorkspaceState?
    public var availableDrafts: [DraftDocument] = []
    public var antigravityStatusSummary: String = "未检测"
    public var onCopyTextToPasteboard: (@MainActor (String) -> Void)?
    public var onOpenExternalURL: (@MainActor (URL) -> Bool)?

    public init(
        paths: StoragePaths,
        stash: StashStore,
        drafts: DraftStore,
        activeTurns: ActiveTurnStore,
        capturer: any SelectionCapturing,
        synthesizer: StudioSynthesizer = StudioSynthesizer()
    ) {
        self.paths = paths
        self.stash = stash
        self.drafts = drafts
        self.activeTurns = activeTurns
        self.capturer = capturer
        self.synthesizer = synthesizer
    }

    public func captureSelectionFromHotkey() async {
        do {
            let selection = try await capturer.captureFrontmostSelection()
            let activeTurn = try? activeTurns.latestTurn(forFrontmostBundleID: selection.bundleIdentifier)
            let newClip = try NewClip.fromDesktopSelection(selection, activeAntigravityTurn: activeTurn)
            let saved = try await stash.capture(newClip)
            await refreshHUDClips()
            checkedClipIDs.insert(saved.id)
            hudBanner = .capturedToast(
                clipID: saved.id,
                excerptPreview: Self.previewText(saved.excerpt),
                sourceLabel: saved.source.displayBadge
            )
        } catch let captureErr as CaptureError {
            hudBanner = .errorBanner(
                title: "选段暂存未成功",
                detail: captureErr.errorDescription ?? "捕获失败"
            )
        } catch {
            hudBanner = .errorBanner(
                title: "选段暂存写入失败",
                detail: error.localizedDescription
            )
        }
    }

    public func simulateFailedCaptureBanner(
        reason: String = "本地归档数据库当前处于只读保护或未选中任何文本，本次暂存未写入。"
    ) {
        hudBanner = .errorBanner(
            title: "捕获失败可见性验证 (M2.5)",
            detail: reason
        )
    }

    public func dismissBanner() {
        hudBanner = nil
    }

    public func handleIncomingURL(_ url: URL, clipboardReader: () -> String? = { nil }) async {
        do {
            let command = try StashURLCommand.parse(url, clipboardText: clipboardReader)
            let saved = try await stash.capture(command.newClip)
            await refreshHUDClips()
            checkedClipIDs.insert(saved.id)
            hudBanner = .capturedToast(
                clipID: saved.id,
                excerptPreview: Self.previewText(saved.excerpt),
                sourceLabel: saved.source.displayBadge
            )
        } catch {
            hudBanner = .errorBanner(
                title: "URL 暂存请求失败",
                detail: error.localizedDescription
            )
        }
    }

    public func refreshHUDClips() async {
        do {
            let query = ClipQuery(
                text: hudSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hudSearchText,
                scope: hudScope,
                limit: 100
            )
            let results = try await stash.clips(matching: query)
            hudClips = results
            availableDrafts = (try? await drafts.listDrafts()) ?? []
        } catch {
            hudBanner = .errorBanner(
                title: "读取归档列表失败",
                detail: error.localizedDescription
            )
        }
    }

    public func toggleCheckmark(for clipID: ClipID) {
        if checkedClipIDs.contains(clipID) {
            checkedClipIDs.remove(clipID)
        } else {
            checkedClipIDs.insert(clipID)
        }
    }

    public func toggleHUDCardExpansion(for clipID: ClipID) {
        if expandedHUDClipIDs.contains(clipID) {
            expandedHUDClipIDs.remove(clipID)
        } else {
            expandedHUDClipIDs.insert(clipID)
        }
    }

    public func saveAnnotation(
        for clipID: ClipID,
        title: String?,
        tagsText: String,
        userNote: String?
    ) async {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let annotation = ClipAnnotation(title: title, tags: tags, userNote: userNote)
        do {
            let updated = try await stash.updateAnnotation(annotation, for: clipID)
            await refreshHUDClips()
            if var state = studioState,
               let idx = state.pinnedClips.firstIndex(where: { $0.id == clipID }) {
                state.pinnedClips[idx] = updated
                studioState = state
            }
        } catch {
            hudBanner = .errorBanner(
                title: "更新用户批注失败",
                detail: error.localizedDescription
            )
        }
    }

    public func toggleClipCooling(_ clip: Clip) async {
        do {
            if clip.lifecycle() == .archived {
                try await stash.reheat(clipIDs: [clip.id])
            } else {
                try await stash.cool(clipIDs: [clip.id])
            }
            await refreshHUDClips()
        } catch {
            hudBanner = .errorBanner(
                title: "切换片段热窗状态失败",
                detail: error.localizedDescription
            )
        }
    }

    public func openStudioWithCheckedClips(
        draftTitle: String? = nil,
        openChatDrawer: Bool = false
    ) async {
        await refreshHUDClips()
        let allClips = (try? await stash.clips(matching: ClipQuery(text: nil, scope: .all, limit: 200))) ?? hudClips
        var selectedClips = allClips.filter { checkedClipIDs.contains($0.id) }
        if selectedClips.isEmpty {
            selectedClips = Array(hudClips.prefix(2))
            for clip in selectedClips {
                checkedClipIDs.insert(clip.id)
            }
        }

        let resolvedTitle = draftTitle
            ?? selectedClips.first?.annotation.title
            ?? "近期灵感成文草稿"

        do {
            let existingDrafts = try await drafts.listDrafts()
            let draft: DraftDocument
            if let existing = studioState?.activeDraft {
                var updated = existing
                updated.pinnedClipIDs = selectedClips.map(\.id)
                draft = try await drafts.saveDraft(updated)
            } else if let matching = existingDrafts.first(where: { $0.title == resolvedTitle }) {
                var updated = matching
                updated.pinnedClipIDs = selectedClips.map(\.id)
                draft = try await drafts.saveDraft(updated)
            } else {
                draft = try await drafts.createDraft(
                    title: resolvedTitle,
                    pinnedClipIDs: selectedClips.map(\.id)
                )
            }

            let expandedSet: Set<ClipID> = selectedClips.first.map { [$0.id] } ?? []
            studioState = StudioWorkspaceState(
                activeDraft: draft,
                pinnedClips: selectedClips,
                expandedClipIDs: expandedSet,
                isInlineSynthesisBarPresented: true,
                inlinePromptText: "",
                isChatDrawerPresented: openChatDrawer,
                chatInputText: "",
                chatConversation: studioState?.chatConversation ?? [],
                synthesisBackend: studioState?.synthesisBackend ?? .localOutline,
                isSynthesizing: false
            )
            availableDrafts = (try? await drafts.listDrafts()) ?? []
        } catch {
            hudBanner = .errorBanner(
                title: "打开递进写作舱失败",
                detail: error.localizedDescription
            )
        }
    }

    public func toggleChatDrawer() {
        guard var state = studioState else { return }
        state.isChatDrawerPresented.toggle()
        studioState = state
    }

    public func setChatDrawerPresented(_ presented: Bool) {
        guard var state = studioState else { return }
        state.isChatDrawerPresented = presented
        studioState = state
    }

    public func togglePinnedClipExpansion(_ clipID: ClipID) {
        guard var state = studioState else { return }
        if state.expandedClipIDs.contains(clipID) {
            state.expandedClipIDs.remove(clipID)
        } else {
            state.expandedClipIDs.insert(clipID)
        }
        studioState = state
    }

    public func submitStudioPrompt(_ prompt: String, insertDirectlyIntoDraft: Bool = false) async {
        guard var state = studioState else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = trimmed.isEmpty ? "围绕已勾选片段梳理成文脉络与核心证据" : trimmed

        let userTurn = ChatTurn(
            role: .user,
            text: effectivePrompt,
            citedClipIDs: state.pinnedClips.map(\.id)
        )
        state.chatConversation.append(userTurn)
        state.isSynthesizing = true
        studioState = state

        do {
            let response = try await synthesizer.respond(
                StudioRequest(
                    pinnedClips: state.pinnedClips,
                    conversation: state.chatConversation,
                    draftMarkdown: state.activeDraft.markdownBody,
                    backend: state.synthesisBackend
                )
            )
            state.chatConversation.append(response.assistantTurn)
            state.isSynthesizing = false
            state.inlinePromptText = ""
            state.chatInputText = ""
            studioState = state

            if insertDirectlyIntoDraft {
                await insertIntoDraft(response.suggestedMarkdown, citing: response.citedClipIDs)
            }
        } catch {
            state.isSynthesizing = false
            studioState = state
            hudBanner = .errorBanner(
                title: "场景 A 推演失败",
                detail: error.localizedDescription
            )
        }
    }

    public func insertIntoDraft(_ markdown: String, citing clipIDs: Set<ClipID>) async {
        guard var state = studioState else { return }
        let citedClips = state.pinnedClips.filter { clipIDs.contains($0.id) }
        state.activeDraft.markdownBody = DraftStore.appendCitedMarkdown(
            into: state.activeDraft.markdownBody,
            insertedMarkdown: markdown,
            citedClips: citedClips
        )
        do {
            let saved = try await drafts.saveDraft(state.activeDraft)
            state.activeDraft = saved
            studioState = state
            if !clipIDs.isEmpty {
                try await stash.markSynthesized(clipIDs: clipIDs, draftID: saved.id)
                await refreshHUDClips()
            }
        } catch {
            hudBanner = .errorBanner(
                title: "保存 Markdown 草稿失败",
                detail: error.localizedDescription
            )
        }
    }

    public func updateDraftBody(_ newBody: String) {
        guard var state = studioState else { return }
        state.activeDraft.markdownBody = newBody
        studioState = state
    }

    public func saveActiveDraft() async {
        guard var state = studioState else { return }
        do {
            let saved = try await drafts.saveDraft(state.activeDraft)
            state.activeDraft = saved
            studioState = state
            let cited = Set(state.pinnedClips.map(\.id))
            if !cited.isEmpty {
                try await stash.markSynthesized(clipIDs: cited, draftID: saved.id)
            }
            await refreshHUDClips()
        } catch {
            hudBanner = .errorBanner(
                title: "保存草稿文件失败",
                detail: error.localizedDescription
            )
        }
    }

    public func copyAntigravitySlashCommand(for clips: [Clip]? = nil, instruction: String? = nil) -> String {
        let targetClips: [Clip]
        if let clips, !clips.isEmpty {
            targetClips = clips
        } else if let state = studioState, !state.pinnedClips.isEmpty {
            targetClips = state.pinnedClips
        } else {
            let checked = hudClips.filter { checkedClipIDs.contains($0.id) }
            targetClips = checked.isEmpty ? Array(hudClips.prefix(2)) : checked
        }
        let command = StudioSynthesizer.makeAntigravitySlashCommand(for: targetClips, instruction: instruction)
        onCopyTextToPasteboard?(command)
        if let first = targetClips.first {
            hudBanner = .capturedToast(
                clipID: first.id,
                excerptPreview: "已复制 /rewind 指令（含 \(targetClips.count) 条片段 ID）",
                sourceLabel: "Antigravity MCP"
            )
        }
        return command
    }

    @discardableResult
    public func openSourceOrigin(for clip: Clip) -> Bool {
        guard let url = clip.source.reopenURL else {
            hudBanner = .errorBanner(
                title: "原出处无外部链接",
                detail: "本地原文仍可完整阅读。"
            )
            return false
        }
        if let onOpenExternalURL {
            return onOpenExternalURL(url)
        }
        return false
    }

    public func exportClips(
        ids: Set<ClipID>?,
        format: ExportFormat,
        to destinationURL: URL
    ) async throws {
        let data = try await stash.exportClips(ids: ids, format: format)
        try AtomicFileWriter.writeData(data, to: destinationURL, permissions: 0o644)
    }

    public func deleteClip(id: ClipID) async {
        do {
            _ = try await stash.deleteClip(id: id)
            checkedClipIDs.remove(id)
            expandedHUDClipIDs.remove(id)
            if var state = studioState {
                state.pinnedClips.removeAll { $0.id == id }
                state.expandedClipIDs.remove(id)
                studioState = state
            }
            await refreshHUDClips()
        } catch {
            hudBanner = .errorBanner(
                title: "删除片段失败",
                detail: error.localizedDescription
            )
        }
    }

    public func deleteAllClips(confirmation: DeleteAllConfirmation) async {
        do {
            _ = try await stash.deleteAllClips(confirmation: confirmation)
            checkedClipIDs.removeAll()
            expandedHUDClipIDs.removeAll()
            if var state = studioState {
                state.pinnedClips.removeAll()
                state.expandedClipIDs.removeAll()
                studioState = state
            }
            await refreshHUDClips()
        } catch {
            hudBanner = .errorBanner(
                title: "清空全部归档失败",
                detail: error.localizedDescription
            )
        }
    }

    public func installOrVerifyAntigravityPlugin(binaries: AntigravityIntegration.BinaryLocations) {
        do {
            try AntigravityIntegration.installOrRepair(
                configDirectoryURL: paths.antigravityConfigDirectoryURL,
                binaries: binaries
            )
            let status = AntigravityIntegration.verify(
                configDirectoryURL: paths.antigravityConfigDirectoryURL,
                binaries: binaries
            )
            switch status {
            case .installed:
                antigravityStatusSummary = "Antigravity 2.x Hook & MCP 已就绪"
            case .needsInstallOrRepair(let reasons):
                antigravityStatusSummary = "需修复: \(reasons.joined(separator: "; "))"
            }
        } catch {
            antigravityStatusSummary = "安装失败: \(error.localizedDescription)"
            hudBanner = .errorBanner(
                title: "Antigravity 插件配置失败",
                detail: error.localizedDescription
            )
        }
    }

    private static func previewText(_ raw: String) -> String {
        let singleLine = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count > 44 {
            return String(singleLine.prefix(44)) + "..."
        }
        return singleLine
    }
}
