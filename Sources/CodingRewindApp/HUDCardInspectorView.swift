// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import SwiftUI

@MainActor
struct HUDCardInspectorView: View {
    let card: RewindCard
    let detailState: CardDetailLoadState
    let language: AppLanguage
    let onCopyText: () -> Void
    let onSourceAction: () -> Void
    let onExportOriginal: () -> Void
    let onWakeAntigravity: () -> Void
    let onWakeDSH: () -> Void
    let onCopySessionID: (String) -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    @State private var isTurnsExpanded = true
    @State private var isNotesExpanded = true

    private var resolvedDetail: CardDetail? {
        switch detailState {
        case .idle:
            return nil
        case .loading(let partial):
            return partial
        case .loaded(let detail):
            return detail
        case .failed(let partial, _):
            return partial
        }
    }

    static func shouldSuppressSessionOpening(_ opening: String, context: CaptureContext?) -> Bool {
        let prompt = context?.prompt ?? ""
        guard !prompt.isEmpty else { return false }
        if opening == prompt {
            return true
        }
        let userTurnCount = context?.recentTurns.filter { $0.role.lowercased() == "user" }.count ?? 0
        guard userTurnCount <= 1 else { return false }
        if opening.hasSuffix("…") {
            let stem = opening.dropLast()
            return !stem.isEmpty && prompt.hasPrefix(stem)
        }
        if let newlineIndex = opening.lastIndex(of: "\n") {
            let beforeFence = opening[..<newlineIndex]
            let trailingLine = opening[opening.index(after: newlineIndex)...]
            let isAutoClosedFence = trailingLine.count >= 3
                && (trailingLine.allSatisfy({ $0 == "`" }) || trailingLine.allSatisfy({ $0 == "~" }))
            if isAutoClosedFence, beforeFence.hasSuffix("…") {
                let stem = beforeFence.dropLast()
                return !stem.isEmpty && prompt.hasPrefix(stem)
            }
        }
        return false
    }

    var body: some View {
        let context = resolvedDetail?.context
        let notes = resolvedDetail?.notes ?? []
        let effectiveSessionID = card.effectiveSessionID(context: context)
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
        let formattedDate = card.createdAt.formatted(dateStyle)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(card.sourceTitle) · \(formattedDate)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(AppStrings.copyClipTextMenu(in: language)) {
                    onCopyText()
                }
                .rewindButtonRole(.toolbar)
                .focusEffectDisabled()
                .font(.system(size: 10.5))
                .accessibilityIdentifier("hud.inspector.copyText")
                .help(AppStrings.inspectorCopyTextHelp(in: language))

                if MemosWireFormat.hasOriginal(in: card.rawContent) {
                    Button(AppStrings.exportOriginal(in: language), action: onExportOriginal)
                        .rewindButtonRole(.toolbar)
                        .accessibilityIdentifier("hud.inspector.exportOriginal")
                }

                if let locator = card.sourceLocator {
                    Button(AppStrings.sourceActionButton(for: locator, in: language)) {
                        onSourceAction()
                    }
                    .rewindButtonRole(.toolbar)
                    .focusEffectDisabled()
                    .font(.system(size: 10.5))
                    .accessibilityIdentifier("hud.inspector.sourceAction")

                    if case .antigravitySession = locator {
                        Button(AppStrings.wakeAntigravityButton(in: language)) {
                            onWakeAntigravity()
                        }
                        .rewindButtonRole(.toolbar)
                        .focusEffectDisabled()
                        .font(.system(size: 10.5))
                        .accessibilityIdentifier("hud.inspector.wakeAntigravity")
                    } else if case .dshSession = locator {
                        Button(AppStrings.wakeDSHButton(in: language)) {
                            onWakeDSH()
                        }
                        .rewindButtonRole(.toolbar)
                        .focusEffectDisabled()
                        .font(.system(size: 10.5))
                        .accessibilityIdentifier("hud.inspector.wakeDSH")
                    }
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .rewindButtonRole(.toolbar)
                .focusEffectDisabled()
                .accessibilityLabel(AppStrings.inspectorCloseLabel(in: language))
                .accessibilityIdentifier("hud.inspector.close")
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if case .loading = detailState {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(AppStrings.inspectorLoadingText(in: language))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("hud.inspector.loading")
                    } else if case .failed(_, let message) = detailState {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                            Text(message)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Button(AppStrings.inspectorRetryButton(in: language)) {
                                onRetry()
                            }
                            .rewindButtonRole(.secondary)
                            .controlSize(.mini)
                            .focusEffectDisabled()
                            .accessibilityIdentifier("hud.inspector.retry")
                        }
                    }

                    if let sessionID = effectiveSessionID {
                        HStack(spacing: 6) {
                            Text(AppStrings.inspectorSessionIDLabel(in: language))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(sessionID)
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button(AppStrings.inspectorCopySessionIDButton(in: language)) {
                                onCopySessionID(sessionID)
                            }
                            .rewindButtonRole(.toolbar)
                            .focusEffectDisabled()
                            .font(.system(size: 10))
                            .accessibilityIdentifier("hud.inspector.copySessionID")
                            .help(AppStrings.inspectorCopySessionIDHelp(in: language))
                        }
                    }

                    if let lead = context?.lead {
                        switch lead {
                        case .sessionOpening(let opening) where !Self.shouldSuppressSessionOpening(opening, context: context):
                            inspectorSection(
                                heading: AppStrings.inspectorSessionOpeningHeading(in: language),
                                text: opening
                            )
                        case .pageLead(let pageLead):
                            inspectorSection(
                                heading: AppStrings.inspectorPageLeadHeading(in: language),
                                text: pageLead
                            )
                        default:
                            EmptyView()
                        }
                    }

                    if let prompt = context?.prompt, !prompt.isEmpty {
                        inspectorSection(
                            heading: AppStrings.inspectorPrecedingPromptHeading(in: language),
                            text: prompt
                        )
                    }

                    inspectorSection(
                        heading: AppStrings.inspectorFullExcerptHeading(in: language),
                        text: card.verbatimText
                    )

                    if let turns = context?.recentTurns, !turns.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                isTurnsExpanded.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isTurnsExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(AppStrings.inspectorRecentTurnsHeading(count: turns.count, in: language))
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .rewindButtonRole(.toolbar)
                            .focusEffectDisabled()
                            .accessibilityIdentifier("hud.inspector.toggleTurns")

                            if isTurnsExpanded {
                                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(turn.role)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(turn.text)
                                            .font(.system(size: 11))
                                            .textSelection(.enabled)
                                    }
                                    .padding(5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
                                }
                            }
                        }
                    }

                    if !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                isNotesExpanded.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isNotesExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(AppStrings.inspectorNotesHeading(count: notes.count, in: language))
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .rewindButtonRole(.toolbar)
                            .focusEffectDisabled()
                            .accessibilityIdentifier("hud.inspector.toggleNotes")

                            if isNotesExpanded {
                                ForEach(notes) { note in
                                    let noteDate = note.createdAt.formatted(dateStyle)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(note.author) · \(noteDate)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(note.content)
                                            .font(.system(size: 11))
                                            .textSelection(.enabled)
                                    }
                                    .padding(5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.inspector")
    }

    private func inspectorSection(heading: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
