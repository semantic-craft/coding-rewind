// SPDX-License-Identifier: MIT

import CodingRewindCore
import SwiftUI

@MainActor
struct LibrarySessionTimelineView: View {
    let bundles: [LibrarySessionBundle]
    let checkedIDs: Set<String>
    let focusedID: String?
    let lockedIDs: Set<String>
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    private var activeBundle: LibrarySessionBundle? {
        if let focusedID,
           let matched = bundles.first(where: { bundle in bundle.clips.contains { $0.id == focusedID } }) {
            return matched
        }
        return bundles.first
    }

    var body: some View {
        Group {
            if bundles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(AppStrings.libraryEmptyScopeTitle(in: language)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(bundles) { bundle in
                                LibrarySessionRowView(
                                    bundle: bundle,
                                    isActive: activeBundle?.key == bundle.key,
                                    language: language,
                                    onSelect: { onIntent(.focusClip(bundle.clips.first?.id)) }
                                )
                            }
                        }
                        .padding(10)
                    }
                    .frame(width: 260)
                    Divider()
                    if let bundle = activeBundle {
                        LibrarySessionRailView(
                            bundle: bundle,
                            checkedIDs: checkedIDs,
                            focusedID: focusedID,
                            lockedIDs: lockedIDs,
                            placeTitle: placeTitle,
                            language: language,
                            onIntent: onIntent
                        )
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sessionTimeline")
    }
}

@MainActor
private struct LibrarySessionRowView: View {
    let bundle: LibrarySessionBundle
    let isActive: Bool
    let language: AppLanguage
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                Text(bundle.sessionTitle).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    LibraryClipSourceBadge(source: bundle.source, platform: bundle.sourcePlatform, language: language)
                    Text(AppStrings.librarySessionClipsBadge(bundle.clips.count, in: language))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(bundle.latestClipAt, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03)))
            .overlay {
                if isActive { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1) }
            }
            .contentShape(Rectangle())
        }
        .rewindButtonRole(.toolbar).focusEffectDisabled()
        .accessibilityIdentifier("library.session.row.\(bundle.key.rawValue)")
    }
}

@MainActor
private struct LibrarySessionRailView: View {
    let bundle: LibrarySessionBundle
    let checkedIDs: Set<String>
    let focusedID: String?
    let lockedIDs: Set<String>
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        LibraryClipSourceBadge(source: bundle.source, platform: bundle.sourcePlatform, language: language)
                        Text(bundle.sessionTitle).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Spacer()
                        Text(bundle.latestClipAt, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !bundle.places.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(bundle.places, id: \.self) { ref in
                                Text(placeTitle(ref)).font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            }
                        }
                    }
                    if let opening = bundle.sessionOpening, !opening.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppStrings.librarySessionOpeningLabel(in: language))
                                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                            Text(opening).font(.system(size: 12)).lineLimit(4)
                        }
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading).librarySurface()
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bundle.clips) { clip in
                        LibraryTimelineStepView(
                            clip: clip,
                            isChecked: checkedIDs.contains(clip.id),
                            isFocused: focusedID == clip.id,
                            isLocked: lockedIDs.contains(clip.id),
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

@MainActor
private struct LibraryTimelineStepView: View {
    let clip: LibraryClipItem
    let isChecked: Bool
    let isFocused: Bool
    let isLocked: Bool
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onIntent: @MainActor (LibraryUserIntent) -> Void

    var body: some View {
        let previewText = clip.codePreviewLines.isEmpty ? clip.verbatimMarkdown : clip.codePreviewLines
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(isFocused ? Color.accentColor : Color.secondary.opacity(0.5)).frame(width: 8, height: 8).padding(.top, 6)
                Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1.5).frame(maxHeight: .infinity)
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 6) {
                if let prompt = clip.precedingPromptEyebrow, !prompt.isEmpty {
                    Text(prompt).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading).librarySurface(fillOpacity: 0.04)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button { onIntent(.toggleChecked(clip.id)) } label: {
                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13)).foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                        }
                        .rewindButtonRole(.toolbar).focusEffectDisabled().disabled(isLocked)
                        Text(clip.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(clip.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    if !clip.places.isEmpty {
                        HUDPlaceChipStrip(snippetID: clip.id, refs: clip.places, title: placeTitle, language: language) { ref in
                            onIntent(.removePlace(clipID: clip.id, ref: ref))
                        }
                    }
                    Text(previewText)
                        .font(clip.isCodeDominant ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                        .lineLimit(clip.isCodeDominant ? 8 : 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(clip.isCodeDominant ? 8 : 0)
                        .background { if clip.isCodeDominant { RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)) } }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(isChecked ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isFocused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.09), lineWidth: isFocused ? 1.5 : 1)
                }
                .contentShape(Rectangle())
                .onTapGesture { onIntent(.focusClip(clip.id)) }
            }
        }
    }
}
