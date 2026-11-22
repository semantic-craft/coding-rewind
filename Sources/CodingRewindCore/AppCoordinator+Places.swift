// SPDX-License-Identifier: MIT

import Foundation

public enum HUDSection: Equatable, Hashable, Sendable {
    case hot
    case unplaced
    case map
    case place(PlaceRef)
}

public struct PlacePickerState: Equatable, Sendable {
    public let targetID: String
    public var query: String
}

extension AppCoordinator {
    public var activePlaces: [PlaceRecord] {
        places.filter { !$0.archived }
    }

    public func placeTitle(for ref: PlaceRef) -> String {
        places.first { $0.ref == ref }?.title ?? ref.slug.rawValue
    }

    public var unplacedCount: Int? {
        libraryRecords?.filter(\.isUnplaced).count
    }

    public var placeClipCounts: [PlaceRef: Int] {
        var counts: [PlaceRef: Int] = [:]
        for record in libraryRecords ?? [] {
            for ref in record.places {
                counts[ref, default: 0] += 1
            }
        }
        return counts
    }

    public var browseRecords: [SnippetRecord] {
        let source: [SnippetRecord]
        switch hudSection {
        case .hot, .map:
            return []
        case .unplaced:
            source = (libraryRecords ?? []).filter(\.isUnplaced)
        case .place(let ref):
            source = placeRecords.filter { $0.places.contains(ref) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return source }
        return source.filter { record in
            let haystack = [
                record.title ?? "",
                record.sessionTopic ?? "",
                record.contextSummary ?? "",
                record.keywords.joined(separator: " "),
                record.sourceTitle,
                record.verbatimText
            ].joined(separator: "\n").lowercased()
            return haystack.contains(query) || placesMatch(record.places, query: query)
        }
    }

    func placesMatch(_ refs: [PlaceRef], query: String) -> Bool {
        refs.contains { ref in
            ref.tag.contains(query) || places.first { $0.ref == ref }?.matches(query) == true
        }
    }

    public func showPlace(_ ref: PlaceRef) async {
        hudSection = .place(ref)
        focusedRecordID = nil
        await loadPlaceRecords(ref)
    }

    public func refreshPlaceLibrary() async {
        let repository = placeRepository()
        let revision = libraryRevision
        async let listedPlaces = try? repository.listPlaces(includeArchived: true)
        async let listedRecords = try? repository.listSnippets(SnippetQuery(windowHours: nil, status: .all, resultLimit: .unbounded), now: Date())
        let (placeResult, recordResult) = await (listedPlaces, listedRecords)
        guard revision == libraryRevision else { return }
        if let placeResult {
            places = placeResult.places
        }
        if let recordResult {
            libraryRecords = recordResult.snippets.filter { !deletedClipIDs.contains($0.id) }
        }
        if case .place(let ref) = hudSection {
            await loadPlaceRecords(ref)
        } else if case .place(let ref) = libraryScope {
            await loadPlaceRecords(ref)
        } else {
            placeRecords = []
        }
    }

    func loadPlaceRecords(_ ref: PlaceRef) async {
        let revision = libraryRevision
        let query = SnippetQuery(windowHours: nil, status: .all, place: ref, resultLimit: .unbounded)
        guard let result = try? await placeRepository().listSnippets(query, now: Date()),
              revision == libraryRevision,
              (hudSection == .place(ref) || libraryScope == .place(ref)) else {
            return
        }
        placeRecords = result.snippets.filter { !deletedClipIDs.contains($0.id) }
    }

    public var placeTargetID: String? {
        switch hudSection {
        case .hot:
            let visible = filteredCards
            if let focused = focusedCardID, visible.contains(where: { $0.id == focused }) {
                return focused
            }
            return visible.first?.id
        case .unplaced, .place:
            let visible = browseRecords
            if let focused = focusedRecordID, visible.contains(where: { $0.id == focused }) {
                return focused
            }
            return visible.first?.id
        case .map:
            return nil
        }
    }

    @discardableResult
    public func openPlacePicker(for targetID: String? = nil) -> Bool {
        guard conversationDraft == nil, let resolvedTargetID = targetID ?? placeTargetID else { return false }
        let cached = PlacesCache(fileURL: paths.placesCacheFileURL).load()
        if !cached.isEmpty {
            places = cached
        }
        placePicker = PlacePickerState(targetID: resolvedTargetID, query: "")
        return true
    }

    public func updatePlacePickerQuery(_ query: String) {
        placePicker?.query = query
    }

    public func closePlacePicker() {
        placePicker = nil
    }

    public var placePickerMatches: [PlaceRecord] {
        guard let placePicker else { return [] }
        let assigned = Set(currentPlaces(of: placePicker.targetID))
        return PlaceRecord.fuzzyMatches(placePicker.query, in: activePlaces.filter { !assigned.contains($0.ref) })
    }

    public func commitPlacePicker(_ choice: PlaceRecord? = nil) async {
        guard let picker = placePicker, let place = choice ?? placePickerMatches.first else { return }
        placePicker = nil
        await addPlace(place.ref, to: picker.targetID)
    }

    public func addPlace(_ ref: PlaceRef, to snippetID: String) async {
        await applyPlacePatch(SnippetMetadataPatch(addTags: [ref.tag]), to: snippetID)
    }

    public func removePlace(_ ref: PlaceRef, from snippetID: String) async {
        await applyPlacePatch(SnippetMetadataPatch(removeTags: [ref.tag]), to: snippetID)
    }

    func currentPlaces(of snippetID: String) -> [PlaceRef] {
        cards.first { $0.id == snippetID }?.places
            ?? (libraryRecords ?? []).first { $0.id == snippetID }?.places
            ?? placeRecords.first { $0.id == snippetID }?.places
            ?? []
    }

    func applyPlacePatch(_ patch: SnippetMetadataPatch, to snippetID: String) async {
        let initialKey = canonicalSnippetID(for: snippetID)
        let priorTask = pendingPlacePatchTasks[initialKey]
        let task = Task<Void, Never> { @MainActor [weak self] in
            if let priorTask {
                await priorTask.value
            }
            guard let self else { return }
            let targetID = self.canonicalSnippetID(for: snippetID)
            await self.executePlacePatch(patch, targetID: targetID, originalID: snippetID)
        }
        pendingPlacePatchTasks[initialKey] = task
        await task.value
        for (key, pending) in pendingPlacePatchTasks where pending == task {
            pendingPlacePatchTasks.removeValue(forKey: key)
        }
    }

    private func executePlacePatch(_ patch: SnippetMetadataPatch, targetID: String, originalID: String) async {
        let updated: SnippetRecord
        do {
            updated = try await placeRepository().updateSnippetMetadata(id: targetID, patch: patch, now: Date())
        } catch {
            setErrorBanner(error)
            return
        }
        if updated.id != targetID {
            recordSnippetIDRemap(from: targetID, to: updated.id)
        }
        if updated.id != originalID {
            recordSnippetIDRemap(from: originalID, to: updated.id)
        }
        let previousIDs = Set([originalID, targetID])
        for oldID in previousIDs where oldID != updated.id {
            remapCardDetailState(from: oldID, to: updated.id)
            if checkedCardIDs.remove(oldID) != nil {
                checkedCardIDs.insert(updated.id)
            }
            if focusedCardID == oldID {
                focusedCardID = updated.id
            }
            if focusedRecordID == oldID {
                focusedRecordID = updated.id
            }
        }
        let matchingIDs = previousIDs.union([updated.id])
        let replaceIn: ([SnippetRecord]) -> [SnippetRecord] = { records in
            records.map { matchingIDs.contains($0.id) ? updated : $0 }
        }
        mutateLibrarySnapshots { library, place in
            library = library.map(replaceIn)
            place = replaceIn(place)
        }
        if cards.contains(where: { matchingIDs.contains($0.id) }) {
            let refreshed = hotCache.loadCards().first { $0.id == updated.id }
            updateLocalCards { cards in
                cards.removeAll { matchingIDs.contains($0.id) }
                if let refreshed {
                    cards = Self.mergeCards(cached: cards + [refreshed], pendingOutbox: [])
                }
            }
        }
    }

    func placeRepository() -> SnippetRepository {
        let token: DeveloperCredentialsResolver.TokenResolution = KeychainTokenStore.resolveToken(environment: environment)
            .map { .resolved($0) } ?? .missing
        return SnippetRepository(paths: paths, environment: environment, client: memosClient, preResolvedToken: token)
    }
}
