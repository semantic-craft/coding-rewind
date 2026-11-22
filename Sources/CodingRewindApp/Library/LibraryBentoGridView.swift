// SPDX-License-Identifier: MIT

import CodingRewindCore
import SwiftUI

extension View {
    func librarySurface(cornerRadius: CGFloat = 8, fillOpacity: Double = 0.045, borderOpacity: Double = 0) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(fillOpacity)))
            .overlay {
                if borderOpacity > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 1)
                }
            }
    }
}

@MainActor
struct LibraryClipSourceBadge: View {
    let source: CaptureSourceKind?
    let platform: String
    let language: AppLanguage

    private var symbolName: String {
        switch source {
        case .geminiWeb: return "sparkles"
        case .antigravity: return "bolt.horizontal.circle"
        case .chatGPTApp: return "bubble.left.and.bubble.right"
        case nil: return "doc.text"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName).font(.system(size: 10, weight: .semibold))
            Text(AppStrings.librarySourceDisplayName(source: source, platform: platform, in: language))
                .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

@MainActor
struct LibraryBentoGridView: View {
    let projection: LibraryWorkspaceProjection
    let scope: LibraryScope
    let checkedIDs: Set<String>
    let focusedID: String?
    let lockedIDs: Set<String>
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    private let columns = [GridItem(.adaptive(minimum: 310, maximum: 540), spacing: 14)]

    var body: some View {
        if projection.visibleItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(AppStrings.libraryEmptyScopeTitle(in: language)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if scope == .unplacedInbox {
                        LibraryTriageBannerView(
                            progress: projection.triageProgress,
                            inspectedItem: projection.inspectedItem,
                            language: language,
                            onIntent: onIntent
                        )
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(projection.visibleItems) { item in
                            LibraryBentoCardView(
                                item: item,
                                isInbox: scope == .unplacedInbox,
                                isChecked: checkedIDs.contains(item.id),
                                isFocused: focusedID == item.id || (focusedID == nil && projection.inspectedItem?.id == item.id),
                                isLocked: lockedIDs.contains(item.id),
                                placeTitle: placeTitle,
                                language: language,
                                onIntent: onIntent
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

@MainActor
private struct LibraryTriageBannerView: View {
    let progress: TriageProgressSnapshot
    let inspectedItem: LibraryClipItem?
    let language: AppLanguage
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    var body: some View {
        let total = max(progress.remainingUnplacedCount + progress.triagedInSessionCount, 1)
        let ratio = min(max(Double(progress.triagedInSessionCount) / Double(total), 0), 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(AppStrings.libraryTriageHeadline(remaining: progress.remainingUnplacedCount, triaged: progress.triagedInSessionCount, in: language))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 8)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10)).frame(width: 110, height: 6)
                    Capsule().fill(Color.accentColor).frame(width: max(6, 110 * ratio), height: 6)
                }
            }
            if let item = inspectedItem {
                HStack(spacing: 6) {
                    ForEach(Array(item.suggestedPlaces.prefix(3).enumerated()), id: \.element) { index, candidate in
                        Button {
                            onIntent(.acceptSuggestedPlaces(clipID: item.id, refs: [candidate.place.ref], advanceFocus: false))
                        } label: {
                            Text("[\(index + 1)] \(candidate.place.title) · \(AppStrings.librarySuggestionReason(candidate.reason, in: language))")
                                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .rewindButtonRole(.secondary)
                        .accessibilityIdentifier("library.triage.suggest.\(index)")
                    }
                    Spacer(minLength: 4)
                    if let first = item.suggestedPlaces.first {
                        Button(AppStrings.libraryAcceptAndNextButton(in: language)) {
                            onIntent(.acceptSuggestedPlaces(clipID: item.id, refs: [first.place.ref], advanceFocus: true))
                        }
                        .rewindButtonRole(.primary).controlSize(.small)
                        .accessibilityIdentifier("library.triage.acceptNext")
                    }
                    Button(AppStrings.libraryChoosePlaceButton(in: language)) {
                        onIntent(.openPlacePicker(clipID: item.id))
                    }
                    .rewindButtonRole(.secondary)
                    .accessibilityIdentifier("library.triage.openPicker")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.triageBanner")
    }
}

@MainActor
private struct LibraryBentoCardView: View {
    let item: LibraryClipItem
    let isInbox: Bool
    let isChecked: Bool
    let isFocused: Bool
    let isLocked: Bool
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    var body: some View {
        let previewText = item.codePreviewLines.isEmpty ? item.verbatimMarkdown : item.codePreviewLines
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { onIntent(.toggleChecked(item.id)) } label: {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13)).foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                }
                .rewindButtonRole(.toolbar).focusEffectDisabled().disabled(isLocked)
                .accessibilityIdentifier("library.card.check.\(item.id)")

                LibraryClipSourceBadge(source: item.source, platform: item.sourcePlatform, language: language)
                if let slot = item.hitSlot {
                    Text(AppStrings.libraryHitSlotBadge(slot, in: language))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                if item.isQueuedOffline {
                    Text(AppStrings.pendingSyncBadge(in: language)).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
            if let eyebrow = item.precedingPromptEyebrow, !eyebrow.isEmpty {
                Text("> \(eyebrow)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            if item.isCodeDominant {
                Text(previewText).font(.system(size: 11.5, design: .monospaced)).lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).librarySurface()
            } else {
                Text(previewText).font(.system(size: 12)).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                if !item.places.isEmpty {
                    HUDPlaceChipStrip(snippetID: item.id, refs: item.places, title: placeTitle, language: language) { ref in
                        onIntent(.removePlace(clipID: item.id, ref: ref))
                    }
                } else if isInbox && !item.suggestedPlaces.isEmpty {
                    ForEach(item.suggestedPlaces.prefix(2), id: \.self) { candidate in
                        Button("+ \(candidate.place.title)") {
                            onIntent(.acceptSuggestedPlaces(clipID: item.id, refs: [candidate.place.ref], advanceFocus: false))
                        }
                        .rewindButtonRole(.toolbar).focusEffectDisabled()
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                    }
                }
                Spacer(minLength: 4)
                Button(AppStrings.libraryChoosePlaceButton(in: language)) {
                    onIntent(.openPlacePicker(clipID: item.id))
                }
                .rewindButtonRole(.toolbar).focusEffectDisabled().font(.system(size: 11)).foregroundStyle(.secondary)

                Button(item.status == .synthesized ? AppStrings.libraryUnarchiveButton(in: language) : AppStrings.libraryArchiveButton(in: language)) {
                    onIntent(item.status == .synthesized ? .unarchiveClips([item.id]) : .archiveClips([item.id]))
                }
                .rewindButtonRole(.toolbar).focusEffectDisabled().font(.system(size: 11)).foregroundStyle(.secondary).disabled(isLocked)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(isChecked ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.09), lineWidth: isFocused ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { onIntent(.focusClip(item.id)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.card.\(item.id)")
    }
}
