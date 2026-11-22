// SPDX-License-Identifier: MIT

import CodingRewindCore
import SwiftUI

@MainActor
struct LibrarySidebarView: View {
    let selectedScope: LibraryScope
    let scopeCounts: [LibraryScope: Int]
    let activePlaces: [PlaceRecord]
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onSelectScope: @MainActor (LibraryScope) -> Void

    private static let smartViews: [LibraryScope] = [.all, .unplacedInbox, .hot72Hours, .archived]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sidebarSection(title: AppStrings.librarySidebarSectionViews(in: language)) {
                    ForEach(Self.smartViews, id: \.self) { scope in
                        LibrarySidebarRow(
                            title: AppStrings.libraryScopeTitle(scope, placeTitle: placeTitle, in: language),
                            systemImage: iconName(for: scope),
                            count: scopeCounts[scope] ?? 0,
                            isSelected: selectedScope == scope,
                            accentBadge: scope == .unplacedInbox,
                            identifier: identifier(for: scope),
                            action: { onSelectScope(scope) }
                        )
                    }
                }

                sidebarSection(title: AppStrings.librarySidebarSectionSources(in: language)) {
                    ForEach(CaptureSourceKind.allCases, id: \.self) { kind in
                        let scope = LibraryScope.source(kind)
                        LibrarySidebarRow(
                            title: AppStrings.libraryScopeTitle(scope, placeTitle: placeTitle, in: language),
                            systemImage: iconName(for: kind),
                            count: scopeCounts[scope] ?? 0,
                            isSelected: selectedScope == scope,
                            accentBadge: false,
                            identifier: "library.scope.source.\(kind.rawValue)",
                            action: { onSelectScope(scope) }
                        )
                    }
                }

                if activePlaces.isEmpty {
                    sidebarSection(title: AppStrings.librarySidebarSectionPlaces(.project, in: language)) {
                        Text(AppStrings.placeMapEmpty(in: language))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                } else {
                    ForEach(PlaceKind.allCases, id: \.self) { kind in
                        let placesForKind = activePlaces.filter { $0.ref.kind == kind }
                        if !placesForKind.isEmpty {
                            sidebarSection(title: AppStrings.librarySidebarSectionPlaces(kind, in: language)) {
                                ForEach(placesForKind, id: \.ref) { place in
                                    let scope = LibraryScope.place(place.ref)
                                    LibrarySidebarRow(
                                        title: place.title,
                                        systemImage: iconName(for: kind),
                                        count: scopeCounts[scope] ?? 0,
                                        isSelected: selectedScope == scope,
                                        accentBadge: false,
                                        identifier: "library.scope.place.\(place.ref.tag)",
                                        action: { onSelectScope(scope) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 200, idealWidth: 220, maxWidth: 260, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sidebar")
    }

    private func sidebarSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            content()
        }
    }

    private func iconName(for scope: LibraryScope) -> String {
        switch scope {
        case .all: return "square.grid.2x2"
        case .unplacedInbox: return "tray"
        case .hot72Hours: return "clock"
        case .archived: return "archivebox"
        case .source(let kind): return iconName(for: kind)
        case .place(let ref): return iconName(for: ref.kind)
        }
    }

    private func iconName(for source: CaptureSourceKind) -> String {
        switch source {
        case .geminiWeb: return "sparkles"
        case .antigravity: return "terminal"
        case .chatGPTApp: return "bubble.left.and.text.bubble.right"
        }
    }

    private func iconName(for kind: PlaceKind) -> String {
        switch kind {
        case .project: return "folder"
        case .topic: return "tag"
        case .person: return "person"
        }
    }

    private func identifier(for scope: LibraryScope) -> String {
        switch scope {
        case .all: return "library.scope.all"
        case .unplacedInbox: return "library.scope.unplaced"
        case .hot72Hours: return "library.scope.hot"
        case .archived: return "library.scope.archived"
        case .source(let kind): return "library.scope.source.\(kind.rawValue)"
        case .place(let ref): return "library.scope.place.\(ref.tag)"
        }
    }
}

@MainActor
private struct LibrarySidebarRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let isSelected: Bool
    let accentBadge: Bool
    let identifier: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(badgeForeground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(badgeBackground))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.primary.opacity(0.085) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .rewindButtonRole(.toolbar)
        .focusEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var badgeForeground: Color {
        if accentBadge && count > 0 {
            return .accentColor
        }
        return .secondary
    }

    private var badgeBackground: Color {
        if accentBadge && count > 0 {
            return Color.accentColor.opacity(0.16)
        }
        return Color.primary.opacity(0.06)
    }
}
