// SPDX-License-Identifier: MIT

import CodingRewindCore
import SwiftUI

@MainActor
struct HUDSectionBar: View {
    @Bindable var coordinator: AppCoordinator
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 12) {
            ForEach([HUDSection.hot, .unplaced, .map], id: \.self) { section in
                let isSelected = isSelected(section)
                Button(AppStrings.hudSectionTitle(section, unplacedCount: coordinator.unplacedCount, in: language)) {
                    coordinator.hudSection = section
                }
                .rewindButtonRole(.toolbar)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("hud.section.\(identifier(section))")
            }
            Spacer()
        }
    }

    private func isSelected(_ section: HUDSection) -> Bool {
        if case .place = coordinator.hudSection {
            return section == .map
        }
        return coordinator.hudSection == section
    }

    private func identifier(_ section: HUDSection) -> String {
        switch section {
        case .hot: return "hot"
        case .unplaced: return "unplaced"
        case .map, .place: return "map"
        }
    }
}

@MainActor
struct HUDPlaceChipStrip: View {
    let snippetID: String
    let refs: [PlaceRef]
    let title: (PlaceRef) -> String
    let language: AppLanguage
    let onRemove: (PlaceRef) -> Void

    var body: some View {
        if !refs.isEmpty {
            HStack(spacing: 4) {
                ForEach(refs, id: \.self) { ref in
                    let chipTitle = title(ref)
                    HStack(spacing: 3) {
                        Text(chipTitle)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Button {
                            onRemove(ref)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .contentShape(Rectangle())
                        }
                        .rewindButtonRole(.toolbar)
                        .focusEffectDisabled()
                        .accessibilityLabel(AppStrings.removePlaceLabel(title: chipTitle, in: language))
                        .accessibilityIdentifier("hud.card.place.remove.\(snippetID).\(ref.tag)")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("hud.card.place.\(snippetID).\(ref.tag)")
                }
            }
        }
    }
}

@MainActor
struct HUDRecordRowView: View {
    let record: SnippetRecord
    let isFocused: Bool
    let placeTitle: (PlaceRef) -> String
    let language: AppLanguage
    let onFocus: () -> Void
    let onRemovePlace: (PlaceRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(AppStrings.snippetStatusBadge(record.status, in: language))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("#\(record.sourcePlatform)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(record.createdAt, format: .dateTime.year().month().day())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let title = record.title {
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            HUDPlaceChipStrip(
                snippetID: record.id,
                refs: record.places,
                title: placeTitle,
                language: language,
                onRemove: onRemovePlace
            )
            Text(record.verbatimText).font(.system(size: 11.5)).lineLimit(3).textSelection(.enabled)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.record.\(record.id)")
        .onTapGesture(perform: onFocus)
    }
}

@MainActor
struct HUDPlaceMapView: View {
    @Bindable var coordinator: AppCoordinator
    let language: AppLanguage

    var body: some View {
        let places = coordinator.activePlaces
        let counts = coordinator.placeClipCounts
        if places.isEmpty {
            Text(AppStrings.placeMapEmpty(in: language))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(PlaceKind.allCases, id: \.self) { kind in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppStrings.placeKindColumnTitle(kind, in: language))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(places.filter { $0.ref.kind == kind }, id: \.ref) { place in
                                Button {
                                    Task { @MainActor in await coordinator.showPlace(place.ref) }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(place.title).lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text("\(counts[place.ref] ?? 0)").foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 11.5))
                                    .contentShape(Rectangle())
                                }
                                .rewindButtonRole(.toolbar)
                                .accessibilityIdentifier("hud.map.place.\(place.ref.tag)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("hud.map.column.\(kind.rawValue)")
                    }
                }
            }
        }
    }
}

@MainActor
struct HUDPlacePickerView: View {
    @Bindable var coordinator: AppCoordinator
    let language: AppLanguage

    @FocusState private var isFocused: Bool

    var body: some View {
        let matches = coordinator.placePickerMatches
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(Color.accentColor)
                TextField(
                    AppStrings.placePickerPlaceholder(in: language),
                    text: Binding(
                        get: { coordinator.placePicker?.query ?? "" },
                        set: { coordinator.updatePlacePickerQuery($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit {
                    Task { @MainActor in await coordinator.commitPlacePicker() }
                }
                .accessibilityIdentifier("hud.placePicker.field")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if matches.isEmpty {
                Text(AppStrings.placePickerNoMatch(in: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(matches.prefix(8).enumerated()), id: \.element.ref) { index, place in
                    Button {
                        Task { @MainActor in await coordinator.commitPlacePicker(place) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(place.title).font(.system(size: 11.5, weight: index == 0 ? .semibold : .regular))
                            Text("#\(place.ref.tag)").font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .rewindButtonRole(.toolbar)
                    .accessibilityIdentifier("hud.placePicker.option.\(place.ref.tag)")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.placePicker")
        .onAppear { isFocused = true }
    }
}
