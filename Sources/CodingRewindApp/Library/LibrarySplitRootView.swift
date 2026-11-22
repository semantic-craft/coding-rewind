// SPDX-License-Identifier: MIT

import CodingRewindCore
import SwiftUI

@MainActor
@Observable
public final class LibraryWindowFocusModel {
    public var searchFocusToken: Int = 0
    public init() {}
    public func requestSearchFocus() { searchFocusToken &+= 1 }
}

@MainActor
struct LibrarySplitRootView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var focusModel: LibraryWindowFocusModel
    let onCommand: @MainActor (AppCommand) -> Void
    let onResignTextInput: @MainActor () -> Void

    private var language: AppLanguage { coordinator.language }

    private func dispatchIntent(_ intent: LibraryUserIntent) {
        Task { @MainActor in await coordinator.handleLibraryIntent(intent) }
    }

    var body: some View {
        let projection = coordinator.libraryProjection
        NavigationSplitView {
            LibrarySidebarView(
                selectedScope: coordinator.libraryScope,
                scopeCounts: projection.scopeCounts,
                activePlaces: coordinator.activePlaces,
                placeTitle: { coordinator.placeTitle(for: $0) },
                language: language,
                onSelectScope: { dispatchIntent(.selectScope($0)) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            centerWorkspace(projection: projection)
        }
        .inspector(isPresented: $coordinator.isLibraryInspectorPresented) {
            LibraryInspectorColumnView(
                item: projection.inspectedItem,
                detailState: projection.inspectedDetailState,
                relatedItems: projection.relatedPlaceItems,
                checkedIDs: coordinator.checkedCardIDs,
                isLocked: projection.inspectedItem.map { coordinator.isCardLocked($0.id) } ?? false,
                placeTitle: { coordinator.placeTitle(for: $0) },
                language: language,
                onCopyExcerpt: { coordinator.copyClipText($0) },
                onCopySessionID: { coordinator.copySessionID($0) },
                onWakeAntigravity: { coordinator.wakeAntigravity() },
                onWakeDSH: { coordinator.wakeDSH() },
                onIntent: dispatchIntent
            )
            .inspectorColumnWidth(min: 300, ideal: 344, max: 440)
        }
        .environment(\.locale, language.locale)
    }

    private func centerWorkspace(projection: LibraryWorkspaceProjection) -> some View {
        let checkedIDs = coordinator.checkedActionableCardIDs
        return ZStack {
            VStack(spacing: 0) {
                LibraryTopBarView(
                    scopeTitle: AppStrings.libraryScopeTitle(coordinator.libraryScope, placeTitle: { coordinator.placeTitle(for: $0) }, in: language),
                    itemCount: projection.visibleItems.count,
                    searchText: $coordinator.librarySearchText,
                    layoutMode: coordinator.libraryLayoutMode,
                    isInspectorPresented: coordinator.isLibraryInspectorPresented,
                    searchFocusToken: focusModel.searchFocusToken,
                    language: language,
                    onSelectLayout: { dispatchIntent(.setLayoutMode($0)) },
                    onRefresh: { Task { @MainActor in await coordinator.refreshLibraryWorkspace() } },
                    onToggleInspector: { coordinator.isLibraryInspectorPresented.toggle() }
                )
                Divider()
                if let msg = coordinator.bannerMessage {
                    LibraryStatusBannerView(message: msg, isError: coordinator.isErrorBanner, language: language) {
                        coordinator.bannerMessage = nil
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
                Group {
                    switch coordinator.libraryLayoutMode {
                    case .bentoCards:
                        LibraryBentoGridView(
                            projection: projection,
                            scope: coordinator.libraryScope,
                            checkedIDs: coordinator.checkedCardIDs,
                            focusedID: projection.inspectedItem?.id,
                            lockedIDs: coordinator.lockedConversationCardIDs,
                            placeTitle: { coordinator.placeTitle(for: $0) },
                            language: language,
                            onIntent: dispatchIntent
                        )
                    case .sessionTimeline:
                        LibrarySessionTimelineView(
                            bundles: projection.sessionBundles,
                            checkedIDs: coordinator.checkedCardIDs,
                            focusedID: projection.inspectedItem?.id,
                            lockedIDs: coordinator.lockedConversationCardIDs,
                            placeTitle: { coordinator.placeTitle(for: $0) },
                            language: language,
                            onIntent: dispatchIntent
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBarOverlay(checkedIDs: checkedIDs)
            }
            .background(Color(nsColor: .textBackgroundColor))
            if let draft = coordinator.conversationDraft {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if !coordinator.isLaunchingConversation {
                            onResignTextInput()
                            coordinator.dismissConversationDraft()
                        }
                    }
                HUDConversationDraftView(coordinator: coordinator, draft: draft, language: language, onCommand: onCommand)
                    .padding(20)
                    .frame(maxWidth: 680, maxHeight: 460)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: Color.black.opacity(0.24), radius: 18, y: 8)
                    )
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func bottomBarOverlay(checkedIDs: [String]) -> some View {
        let hasPicker = coordinator.placePicker != nil
        let hasDelete = coordinator.pendingDeleteConfirmation != nil
        let hasDock = !checkedIDs.isEmpty && coordinator.conversationDraft == nil
        if hasPicker || hasDelete || hasDock {
            VStack(spacing: 8) {
                if hasPicker {
                    HUDPlacePickerView(coordinator: coordinator, language: language)
                }
                if let pending = coordinator.pendingDeleteConfirmation {
                    LibraryDeleteConfirmBar(
                        count: pending.cardIDs.count,
                        allOfflinePending: pending.allOfflinePending,
                        isMutating: coordinator.isMutatingCards,
                        language: language,
                        onCancel: { coordinator.cancelDeleteConfirmation() },
                        onConfirm: { Task { @MainActor in await coordinator.confirmPendingDelete() } }
                    )
                }
                if hasDock {
                    LibraryHandoffDockView(
                        stagedCount: checkedIDs.count,
                        actionTitle: coordinator.conversationActionTitle,
                        isLaunching: coordinator.isLaunchingConversation,
                        language: language,
                        onClear: { dispatchIntent(.clearChecked) },
                        onBatchPlace: { if let firstID = checkedIDs.first { dispatchIntent(.openPlacePicker(clipID: firstID)) } },
                        onLaunch: { onCommand(.launchConversation) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

@MainActor
private struct LibraryTopBarView: View {
    let scopeTitle: String
    let itemCount: Int
    @Binding var searchText: String
    let layoutMode: LibraryLayoutMode
    let isInspectorPresented: Bool
    let searchFocusToken: Int
    let language: AppLanguage
    let onSelectLayout: @MainActor (LibraryLayoutMode) -> Void
    let onRefresh: @MainActor () -> Void
    let onToggleInspector: @MainActor () -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(scopeTitle).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Text("\(itemCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(AppStrings.librarySearchPlaceholder(in: language), text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).focused($isSearchFocused)
                    .accessibilityIdentifier("library.search.field")
                    .onSubmit { isSearchFocused = false }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .rewindButtonRole(.toolbar).focusEffectDisabled()
                    .accessibilityLabel(AppStrings.libraryClearSearchLabel(in: language))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(minWidth: 110, maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 2) {
                ForEach(LibraryLayoutMode.allCases, id: \.self) { mode in
                    let selected = layoutMode == mode
                    Button { onSelectLayout(mode) } label: {
                        Image(systemName: mode == .bentoCards ? "rectangle.grid.2x2" : "list.bullet.indent")
                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .frame(width: 28, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear))
                    }
                    .rewindButtonRole(.toolbar).focusEffectDisabled()
                    .accessibilityLabel(AppStrings.libraryLayoutTitle(mode, in: language))
                    .help(AppStrings.libraryLayoutTitle(mode, in: language))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("library.layout.\(mode.rawValue)")
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                .rewindButtonRole(.toolbar).focusEffectDisabled()
                .accessibilityLabel(AppStrings.syncNow(in: language))
                .accessibilityIdentifier("library.toolbar.refresh")
                .help(AppStrings.syncNowHelp(in: language))
            Button(action: onToggleInspector) {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(isInspectorPresented ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .rewindButtonRole(.toolbar).focusEffectDisabled()
            .accessibilityLabel(AppStrings.libraryInspectorToggleHelp(in: language))
            .accessibilityIdentifier("library.toolbar.inspectorToggle")
            .help(AppStrings.libraryInspectorToggleHelp(in: language))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onChange(of: searchFocusToken) { _, newValue in
            if newValue > 0 { isSearchFocused = true }
        }
    }
}

@MainActor
private struct LibraryStatusBannerView: View {
    let message: String
    let isError: Bool
    let language: AppLanguage
    let onDismiss: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(message).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .rewindButtonRole(.toolbar).focusEffectDisabled()
                .accessibilityLabel(AppStrings.dismissBannerLabel(in: language))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background((isError ? Color.orange : Color.green).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
private struct LibraryDeleteConfirmBar: View {
    let count: Int
    let allOfflinePending: Bool
    let isMutating: Bool
    let language: AppLanguage
    let onCancel: @MainActor () -> Void
    let onConfirm: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.red)
            Text(AppStrings.deleteConfirmationMessage(count: count, allOfflinePending: allOfflinePending, in: language))
                .font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 4)
            Button(AppStrings.cancelButton(in: language), action: onCancel).rewindButtonRole(.secondary)
            Button(AppStrings.confirmDeleteButton(in: language), action: onConfirm)
                .buttonStyle(RewindDestructiveButtonStyle()).disabled(isMutating)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.35), lineWidth: 1) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.deleteConfirm")
    }
}

@MainActor
private struct LibraryHandoffDockView: View {
    let stagedCount: Int
    let actionTitle: String
    let isLaunching: Bool
    let language: AppLanguage
    let onClear: @MainActor () -> Void
    let onBatchPlace: @MainActor () -> Void
    let onLaunch: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(AppStrings.libraryHandoffSelectedCount(stagedCount, in: language)).font(.system(size: 12, weight: .semibold))
            Button(AppStrings.libraryClearSelectionButton(in: language), action: onClear).rewindButtonRole(.secondary)
            Button(AppStrings.libraryBatchPlaceButton(in: language), action: onBatchPlace).rewindButtonRole(.secondary)
            Spacer(minLength: 4)
            Button(action: onLaunch) {
                HStack(spacing: 6) { Text(actionTitle); Text("⌘↩") }
            }
            .buttonStyle(RewindLaunchButtonStyle()).disabled(isLaunching)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.handoffDock")
    }
}
