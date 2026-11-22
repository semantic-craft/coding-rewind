// SPDX-License-Identifier: MIT

import CodingRewindCore
import SwiftUI

@MainActor
struct LibraryInspectorColumnView: View {
    let item: LibraryClipItem?
    let detailState: CardDetailLoadState
    let relatedItems: [LibraryClipItem]
    let checkedIDs: Set<String>
    let isLocked: Bool
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onCopyExcerpt: @MainActor (String) -> Void
    let onCopySessionID: @MainActor (String) -> Void
    let onWakeAntigravity: @MainActor () -> Void
    let onWakeDSH: @MainActor () -> Void
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    @State private var draftNoteText = ""
    @State private var isTurnsExpanded = true

    private var resolvedDetail: CardDetail? {
        switch detailState {
        case .idle: return nil
        case .loading(let partial): return partial
        case .loaded(let detail): return detail
        case .failed(let partial, _): return partial
        }
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        LibraryInspectorHeaderSection(item: item, placeTitle: placeTitle, language: language, onCopySessionID: onCopySessionID, onWakeAntigravity: onWakeAntigravity, onWakeDSH: onWakeDSH, onIntent: onIntent)
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(AppStrings.libraryVerbatimExcerptLabel(in: language)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button(AppStrings.libraryCopyExcerptButton(in: language)) { onCopyExcerpt(item.verbatimMarkdown) }
                                    .rewindButtonRole(.toolbar).focusEffectDisabled().font(.system(size: 11))
                                    .accessibilityIdentifier("library.inspector.copyExcerpt")
                            }
                            Text(item.verbatimMarkdown)
                                .font(item.isCodeDominant ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                                .lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10).librarySurface(borderOpacity: 0.08)
                        }
                        LibraryInspectorProvenanceSection(item: item, detailState: detailState, detail: resolvedDetail, isTurnsExpanded: $isTurnsExpanded, language: language, onCopySessionID: onCopySessionID)
                        LibraryInspectorNotesSection(itemID: item.id, notes: resolvedDetail?.notes ?? [], isLocked: isLocked, draftNoteText: $draftNoteText, language: language, onIntent: onIntent)
                        if !relatedItems.isEmpty {
                            LibraryInspectorRelatedSection(itemID: item.id, relatedItems: relatedItems, checkedIDs: checkedIDs, language: language, onIntent: onIntent)
                        }
                        Divider()
                        HStack(spacing: 8) {
                            Button(item.status == .synthesized ? AppStrings.libraryUnarchiveButton(in: language) : AppStrings.libraryArchiveButton(in: language)) {
                                onIntent(item.status == .synthesized ? .unarchiveClips([item.id]) : .archiveClips([item.id]))
                            }.rewindButtonRole(.secondary).disabled(isLocked)
                            Spacer()
                            Button(AppStrings.libraryDeleteButton(in: language), role: .destructive) { onIntent(.requestDelete([item.id], immediate: false)) }
                                .rewindButtonRole(.secondary).disabled(isLocked)
                        }
                    }.padding(18)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text(AppStrings.libraryEmptyInspectorHint(in: language)).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: item?.id) { _, _ in draftNoteText = "" }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.inspector")
    }
}

@MainActor
private struct LibraryInspectorHeaderSection: View {
    let item: LibraryClipItem
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onCopySessionID: @MainActor (String) -> Void
    let onWakeAntigravity: @MainActor () -> Void
    let onWakeDSH: @MainActor () -> Void
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 6) {
                LibraryClipSourceBadge(source: item.source, platform: item.sourcePlatform, language: language)
                Text(item.sourceTitle).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(AppStrings.snippetStatusBadge(item.status, in: language)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                HUDPlaceChipStrip(snippetID: item.id, refs: item.places, title: placeTitle, language: language) { ref in
                    onIntent(.removePlace(clipID: item.id, ref: ref))
                }
                Spacer(minLength: 4)
                Button(AppStrings.libraryChoosePlaceButton(in: language)) { onIntent(.openPlacePicker(clipID: item.id)) }.rewindButtonRole(.secondary)
            }
            if item.hasOriginal {
                Button(AppStrings.exportOriginal(in: language)) { onIntent(.exportOriginal(clipID: item.id)) }
                    .rewindButtonRole(.secondary)
                    .accessibilityIdentifier("library.inspector.exportOriginal")
            }
            if let locator = item.sourceLocator {
                HStack(spacing: 6) {
                    Button(AppStrings.sourceActionButton(for: locator, in: language)) { onIntent(.triggerSourceAction(item)) }
                        .rewindButtonRole(.secondary).accessibilityIdentifier("library.inspector.sourceAction")
                    if case .antigravitySession = locator {
                        Button(AppStrings.wakeAntigravityButton(in: language), action: onWakeAntigravity).rewindButtonRole(.secondary)
                    } else if case .dshSession(let sid) = locator {
                        Button(AppStrings.wakeDSHButton(in: language), action: onWakeDSH).rewindButtonRole(.secondary)
                        Button(AppStrings.copySessionIDButton(in: language)) { onCopySessionID(sid) }.rewindButtonRole(.toolbar).focusEffectDisabled()
                    }
                }
            }
        }
    }
}

@MainActor
private struct LibraryInspectorProvenanceSection: View {
    let item: LibraryClipItem
    let detailState: CardDetailLoadState
    let detail: CardDetail?
    @Binding var isTurnsExpanded: Bool
    let language: AppLanguage
    let onCopySessionID: @MainActor (String) -> Void

    var body: some View {
        let context = detail?.context
        let sessionID = item.sourceLocator?.sessionID ?? context?.sessionID
        let prompt = (context?.prompt.isEmpty == false ? context?.prompt : nil) ?? item.precedingPromptEyebrow
        VStack(alignment: .leading, spacing: 8) {
            if case .loading = detailState {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(AppStrings.inspectorLoadingText(in: language)).font(.system(size: 11)).foregroundStyle(.secondary) }
            } else if case .failed(_, let message) = detailState {
                HStack(spacing: 6) { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange); Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
            if let sessionID, !sessionID.isEmpty {
                HStack(spacing: 6) {
                    Text(AppStrings.inspectorSessionIDLabel(in: language)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Text(sessionID).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button(AppStrings.inspectorCopySessionIDButton(in: language)) { onCopySessionID(sessionID) }.rewindButtonRole(.toolbar).focusEffectDisabled().font(.system(size: 10.5))
                }
            }
            if let lead = context?.lead {
                switch lead {
                case .sessionOpening(let opening) where !HUDCardInspectorView.shouldSuppressSessionOpening(opening, context: context):
                    inspectorBox(title: AppStrings.librarySessionOpeningLabel(in: language), body: opening)
                case .pageLead(let pageLead):
                    inspectorBox(title: AppStrings.inspectorPageLeadHeading(in: language), body: pageLead)
                default: EmptyView()
                }
            }
            if let prompt, !prompt.isEmpty { inspectorBox(title: AppStrings.libraryPrecedingPromptLabel(in: language), body: prompt) }
            if let turns = context?.recentTurns, !turns.isEmpty {
                Button { isTurnsExpanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isTurnsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9.5, weight: .semibold))
                        Text(AppStrings.libraryRecentTurnsLabel(turns.count, in: language)).font(.system(size: 11, weight: .semibold))
                    }.foregroundStyle(.secondary)
                }.rewindButtonRole(.toolbar).focusEffectDisabled()
                if isTurnsExpanded {
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.role).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Text(turn.text).font(.system(size: 11.5)).textSelection(.enabled)
                        }.padding(7).frame(maxWidth: .infinity, alignment: .leading).librarySurface(cornerRadius: 6, fillOpacity: 0.04)
                    }
                }
            }
        }
    }

    private func inspectorBox(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(body).font(.system(size: 11.5)).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8).librarySurface(cornerRadius: 7, fillOpacity: 0.04)
        }
    }
}

@MainActor
private struct LibraryInspectorNotesSection: View {
    let itemID: String
    let notes: [SnippetNote]
    let isLocked: Bool
    @Binding var draftNoteText: String
    let language: AppLanguage
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppStrings.libraryNotesSectionLabel(notes.count, in: language)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(note.author).font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text(note.createdAt, format: .dateTime.month().day().hour().minute()).font(.system(size: 10))
                    }.foregroundStyle(.secondary)
                    Text(note.content).font(.system(size: 11.5)).textSelection(.enabled)
                }.padding(7).frame(maxWidth: .infinity, alignment: .leading).librarySurface(cornerRadius: 6, fillOpacity: 0.04)
            }
            HStack(spacing: 6) {
                TextField(AppStrings.libraryNotePlaceholder(in: language), text: $draftNoteText).textFieldStyle(.roundedBorder).font(.system(size: 11.5)).onSubmit(submitNote).accessibilityIdentifier("library.inspector.noteField")
                Button(AppStrings.libraryAddNoteButton(in: language), action: submitNote).rewindButtonRole(.secondary).disabled(isLocked || draftNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("library.inspector.addNote")
            }
        }
    }

    private func submitNote() {
        let trimmed = draftNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLocked, !trimmed.isEmpty else { return }
        onIntent(.appendNote(clipID: itemID, text: trimmed))
        draftNoteText = ""
    }
}

@MainActor
private struct LibraryInspectorRelatedSection: View {
    let itemID: String
    let relatedItems: [LibraryClipItem]
    let checkedIDs: Set<String>
    let language: AppLanguage
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(AppStrings.libraryRelatedClipsLabel(relatedItems.count, in: language)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(AppStrings.libraryMergeStartChatButton(in: language)) { onIntent(.stageAndOpenHandoff(clipIDs: [itemID] + relatedItems.map(\.id))) }.rewindButtonRole(.secondary).accessibilityIdentifier("library.inspector.mergeStartChat")
            }
            ForEach(relatedItems) { rel in
                Button { onIntent(.focusClip(rel.id)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: checkedIDs.contains(rel.id) ? "checkmark.circle.fill" : "doc.text").font(.system(size: 11)).foregroundStyle(checkedIDs.contains(rel.id) ? Color.accentColor : Color.secondary)
                        Text(rel.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                        Spacer()
                        Text(rel.createdAt, format: .dateTime.month().day()).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(7).librarySurface(cornerRadius: 6, fillOpacity: 0.035).contentShape(Rectangle())
                }.rewindButtonRole(.toolbar).focusEffectDisabled()
            }
        }
    }
}
