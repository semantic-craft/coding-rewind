// SPDX-License-Identifier: MIT

import Foundation

extension AppCoordinator {
    public var libraryProjection: LibraryWorkspaceProjection {
        LibraryProjector.project(
            hotCards: cards,
            libraryRecords: libraryRecords ?? [],
            placeRecords: placeRecords,
            activePlaces: activePlaces,
            cachedDetails: cachedCardDetails,
            detailStates: cardDetailStates,
            scope: libraryScope,
            searchText: librarySearchText,
            focusedClipID: libraryFocusedClipID,
            triagedInSessionCount: triagedInSessionCount
        )
    }

    public func refreshLibraryWorkspace() async {
        await refresh()
        await refreshPlaceLibrary()
        if case .place(let ref) = libraryScope {
            await loadPlaceRecords(ref)
        }
        ensureLibraryInspectedDetailLoaded()
    }

    public func ensureLibraryInspectedDetailLoaded() {
        guard let item = libraryProjection.inspectedItem else { return }
        if cardDetailStates[item.id] == nil || cardDetailStates[item.id] == .idle {
            reloadCardDetail(id: item.id)
        }
    }

    public func handleLibraryIntent(_ intent: LibraryUserIntent) async {
        switch intent {
        case .selectScope(let scope):
            libraryScope = scope
            pendingDeleteConfirmation = nil
            if case .place(let ref) = scope {
                await loadPlaceRecords(ref)
            }
            libraryFocusedClipID = libraryProjection.visibleItems.first?.id
            ensureLibraryInspectedDetailLoaded()

        case .setLayoutMode(let mode):
            libraryLayoutMode = mode

        case .focusClip(let id):
            libraryFocusedClipID = id
            if id != nil {
                ensureLibraryInspectedDetailLoaded()
            }

        case .stepFocus(let delta):
            let items = libraryProjection.visibleItems
            guard !items.isEmpty else {
                libraryFocusedClipID = nil
                return
            }
            let currentID = libraryFocusedClipID ?? libraryProjection.inspectedItem?.id
            let nextIndex: Int
            if let currentID, let currentIndex = items.firstIndex(where: { $0.id == currentID }) {
                nextIndex = min(max(currentIndex + delta, 0), items.count - 1)
            } else {
                nextIndex = delta < 0 ? items.count - 1 : 0
            }
            libraryFocusedClipID = items[nextIndex].id
            ensureLibraryInspectedDetailLoaded()

        case .toggleChecked(let id):
            guard !isCardLocked(id) else {
                setBanner(.cardsLockedByActiveConversation, isError: true)
                return
            }
            toggleCheck(for: id)

        case .clearChecked:
            pendingDeleteConfirmation = nil
            checkedCardIDs.removeAll()

        case .acceptSuggestedPlaces(let clipID, let refs, let advanceFocus):
            guard !refs.isEmpty else { return }
            let visibleBefore = advanceFocus ? libraryProjection.visibleItems.map(\.id) : []
            let revisionBefore = libraryRevision
            await applyPlacePatch(SnippetMetadataPatch(addTags: refs.map(\.tag)), to: clipID)
            guard libraryRevision != revisionBefore else { return }
            triagedInSessionCount += 1
            if advanceFocus {
                let visibleAfter = libraryProjection.visibleItems.map(\.id)
                let visibleAfterSet = Set(visibleAfter)
                var nextFocusID: String?
                if let oldIndex = visibleBefore.firstIndex(of: clipID) {
                    nextFocusID = visibleBefore[(oldIndex + 1)...].first { $0 != clipID && visibleAfterSet.contains($0) }
                        ?? visibleBefore[..<oldIndex].last { $0 != clipID && visibleAfterSet.contains($0) }
                }
                libraryFocusedClipID = nextFocusID ?? visibleAfter.first
                ensureLibraryInspectedDetailLoaded()
            }

        case .openPlacePicker(let clipID):
            libraryFocusedClipID = clipID
            _ = openPlacePicker(for: clipID)

        case .removePlace(let clipID, let ref):
            await removePlace(ref, from: clipID)

        case .archiveClips(let ids):
            await archiveLibraryClips(ids: ids)

        case .unarchiveClips(let ids):
            await unarchiveLibraryClips(ids: ids)

        case .requestDelete(let ids, let immediate):
            await requestDeleteCards(ids: ids, bypassConfirmation: immediate)

        case .appendNote(let clipID, let text):
            await appendLibraryNote(clipID: clipID, text: text)

        case .triggerSourceAction(let item):
            let card = resolvableCardsForHandoff().first(where: { $0.id == item.id })
                ?? LibraryProjector.synthesizeRewindCard(from: item)
            _ = await openSource(for: card)

        case .stageAndOpenHandoff(let clipIDs):
            guard !clipIDs.isEmpty else { return }
            checkedCardIDs = Set(clipIDs)
            _ = openConversationDraft()
        }
    }

    private func archiveLibraryClips(ids: [String]) async {
        guard !ids.isEmpty else { return }
        let hotIDSet = Set(cards.map(\.id))
        let hotIDs = ids.filter { hotIDSet.contains($0) }
        let recordOnlyIDs = ids.filter { !hotIDSet.contains($0) }

        if !hotIDs.isEmpty {
            await archiveCards(ids: hotIDs)
        }

        if !recordOnlyIDs.isEmpty {
            if recordOnlyIDs.contains(where: { isCardLocked($0) }) {
                setBanner(.cardsLockedByActiveConversation, isError: true)
            } else {
                var succeeded = 0
                var failed = 0
                var lastError: (any Error)?
                for id in recordOnlyIDs {
                    do {
                        let updated = try await placeRepository().updateSnippetMetadata(
                            id: id,
                            patch: SnippetMetadataPatch(archived: true),
                            now: Date()
                        )
                        archivedClipIDs.insert(id)
                        archivedClipIDs.insert(updated.id)
                        checkedCardIDs.remove(id)
                        checkedCardIDs.remove(updated.id)
                        updateStoredSnippetRecord(updated, matchingID: id)
                        succeeded += 1
                    } catch {
                        lastError = error
                        failed += 1
                    }
                }
                if hotIDs.isEmpty {
                    if failed == 0 && succeeded > 0 {
                        setBanner(.archivedClips(count: succeeded), isError: false)
                    } else if succeeded > 0 && failed > 0 {
                        setBanner(.partialArchiveClipsFailure(succeeded: succeeded, failed: failed), isError: true)
                    } else if let lastError {
                        setErrorBanner(lastError)
                    }
                }
            }
        }

        reconcileLibraryFocusAfterVisibilityChange()
    }

    private func unarchiveLibraryClips(ids: [String]) async {
        guard !ids.isEmpty else { return }
        var lastError: (any Error)?
        var anySucceeded = false
        for id in ids {
            do {
                let updated = try await placeRepository().updateSnippetMetadata(
                    id: id,
                    patch: SnippetMetadataPatch(archived: false),
                    now: Date()
                )
                archivedClipIDs.remove(id)
                archivedClipIDs.remove(updated.id)
                updateStoredSnippetRecord(updated, matchingID: id)
                anySucceeded = true
            } catch {
                lastError = error
            }
        }
        if anySucceeded {
            await refresh()
        } else if let lastError {
            setErrorBanner(lastError)
        }
        reconcileLibraryFocusAfterVisibilityChange()
    }

    private func appendLibraryNote(clipID: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let updated = try await placeRepository().appendSnippetNote(
                id: clipID,
                content: trimmed,
                author: nil,
                now: Date()
            )
            updateStoredSnippetRecord(updated, matchingID: clipID)
            let existingDetail = cachedCardDetails[clipID]
            let mergedContext = existingDetail?.context ?? updated.conversationContext
            let mergedNotes = LocalNotesStore.sortAndDeduplicate((existingDetail?.notes ?? []) + updated.notes)
            let isComplete = existingDetail?.isCompleteFromServer ?? (updated.dataOrigin == .remote)
            let detail = CardDetail(
                context: mergedContext,
                notes: mergedNotes,
                isCompleteFromServer: isComplete
            )
            cachedCardDetails[clipID] = detail
            cardDetailStates[clipID] = .loaded(detail)
            if isErrorBanner {
                bannerMessage = nil
                isErrorBanner = false
            }
        } catch {
            setErrorBanner(error)
        }
    }

    private func updateStoredSnippetRecord(_ updated: SnippetRecord, matchingID originalID: String) {
        libraryRevision += 1
        let replaceIn: ([SnippetRecord]) -> [SnippetRecord] = { records in
            records.map { ($0.id == originalID || $0.id == updated.id) ? updated : $0 }
        }
        libraryRecords = libraryRecords.map(replaceIn)
        placeRecords = replaceIn(placeRecords)
    }

    private func reconcileLibraryFocusAfterVisibilityChange() {
        let visibleIDs = libraryProjection.visibleItems.map(\.id)
        if let focused = libraryFocusedClipID, !visibleIDs.contains(focused) {
            libraryFocusedClipID = visibleIDs.first
        } else if libraryFocusedClipID == nil {
            libraryFocusedClipID = visibleIDs.first
        }
        ensureLibraryInspectedDetailLoaded()
    }
}
