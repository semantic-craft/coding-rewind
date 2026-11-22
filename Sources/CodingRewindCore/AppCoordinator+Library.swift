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
            triagedInSessionCount: triagedInSessionCount,
            archivedClipIDs: archivedClipIDs
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
        switch cardDetailStates[item.id] {
        case .none, .idle, .failed:
            reloadCardDetail(id: item.id)
        case .loading, .loaded:
            break
        }
    }

    public func handleLibraryIntent(_ intent: LibraryUserIntent) async {
        switch intent {
        case .selectScope(let scope):
            libraryScope = scope
            pendingDeleteConfirmation = nil
            if case .place(let ref) = scope {
                await loadPlaceRecords(ref)
            } else if case .place = hudSection {
            } else {
                placeRecords = []
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
            _ = await openSource(locator: item.sourceLocator)

        case .exportOriginal(let clipID):
            await exportOriginal(clipID: clipID)

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
                        let targetID = canonicalSnippetID(for: id)
                        let updated = try await placeRepository().updateSnippetMetadata(
                            id: targetID,
                            patch: SnippetMetadataPatch(archived: true),
                            now: Date()
                        )
                        if updated.id != targetID {
                            recordSnippetIDRemap(from: targetID, to: updated.id)
                        }
                        if updated.id != id {
                            recordSnippetIDRemap(from: id, to: updated.id)
                        }
                        archivedClipIDs.insert(id)
                        archivedClipIDs.insert(targetID)
                        archivedClipIDs.insert(updated.id)
                        checkedCardIDs.remove(id)
                        checkedCardIDs.remove(targetID)
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
                let targetID = canonicalSnippetID(for: id)
                let updated = try await placeRepository().updateSnippetMetadata(
                    id: targetID,
                    patch: SnippetMetadataPatch(archived: false),
                    now: Date()
                )
                if updated.id != targetID {
                    recordSnippetIDRemap(from: targetID, to: updated.id)
                }
                if updated.id != id {
                    recordSnippetIDRemap(from: id, to: updated.id)
                }
                archivedClipIDs.remove(id)
                archivedClipIDs.remove(targetID)
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
            let resolvedClipID = canonicalSnippetID(for: clipID)
            let updated = try await placeRepository().appendSnippetNote(
                id: resolvedClipID,
                content: trimmed,
                author: nil,
                now: Date()
            )
            if updated.id != resolvedClipID {
                recordSnippetIDRemap(from: resolvedClipID, to: updated.id)
            }
            if updated.id != clipID {
                recordSnippetIDRemap(from: clipID, to: updated.id)
                remapCardDetailState(from: clipID, to: updated.id)
                if checkedCardIDs.remove(clipID) != nil {
                    checkedCardIDs.insert(updated.id)
                }
                if focusedCardID == clipID {
                    focusedCardID = updated.id
                }
            }
            updateStoredSnippetRecord(updated, matchingID: clipID)
            let targetID = updated.id
            let existingDetail = cachedCardDetails[targetID]
            let mergedContext = existingDetail?.context ?? updated.conversationContext
            let mergedNotes = LocalNotesStore.sortAndDeduplicate((existingDetail?.notes ?? []) + updated.notes)
            let isComplete = existingDetail?.isCompleteFromServer ?? (updated.dataOrigin == .remote)
            let detail = CardDetail(
                context: mergedContext,
                notes: mergedNotes,
                isCompleteFromServer: isComplete
            )
            cachedCardDetails[targetID] = detail
            cardDetailStates[targetID] = .loaded(detail)
            if isErrorBanner {
                bannerMessage = nil
                isErrorBanner = false
            }
        } catch {
            setErrorBanner(error)
        }
    }

    func removeObsoleteLocalRecordID(_ oldID: String, replacedBy newID: String) {
        guard oldID != newID else { return }
        recordSnippetIDRemap(from: oldID, to: newID)
        mutateLibrarySnapshots { library, place in
            library = library?.filter { $0.id != oldID }
            place.removeAll { $0.id == oldID }
        }
    }

    func markSnippetRecordsArchived(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let update: ([SnippetRecord]) -> [SnippetRecord] = { records in
            records.map { record in
                guard ids.contains(record.id), record.status != .synthesized else { return record }
                return SnippetRecord(
                    id: record.id,
                    status: .synthesized,
                    sourcePlatform: record.sourcePlatform,
                    title: record.title,
                    sessionTopic: record.sessionTopic,
                    contextSummary: record.contextSummary,
                    keywords: record.keywords,
                    sourceTitle: record.sourceTitle,
                    sourceURL: record.sourceURL,
                    verbatimText: record.verbatimText,
                    createdAt: record.createdAt,
                    dataOrigin: record.dataOrigin,
                    conversationContext: record.conversationContext,
                    tags: record.tags,
                    notes: record.notes
                )
            }
        }
        mutateLibrarySnapshots { library, place in
            library = library.map(update)
            place = update(place)
        }
        reconcileLibraryFocusAfterVisibilityChange()
    }

    private func updateStoredSnippetRecord(_ updated: SnippetRecord, matchingID originalID: String) {
        let replaceIn: ([SnippetRecord]) -> [SnippetRecord] = { records in
            records.map { ($0.id == originalID || $0.id == updated.id) ? updated : $0 }
        }
        mutateLibrarySnapshots { library, place in
            library = library.map(replaceIn)
            place = replaceIn(place)
        }
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
