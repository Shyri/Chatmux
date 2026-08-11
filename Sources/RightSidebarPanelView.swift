import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

private func rightSidebarDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    // Declaration order is the order the picker shows: `availableModes` is
    // `allCases.filter { … }`. GitLab and Changes lead because they are the
    // per-workspace views you act on; the Vault is a browse-everything list, so
    // it sits at the end. Raw values are pinned strings, so reordering does not
    // touch persisted state or the CLI vocabulary.
    case files
    case find
    case gitStatus = "git-status"
    case gitlab
    case feed
    case dock
    case sessions
    case autoTasks = "auto-tasks"
    case autoTaskConfig = "auto-task-config"
    case customSidebar = "custom-sidebar"

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .dock: return String(localized: "rightSidebar.mode.dock", defaultValue: "Dock")
        case .gitlab: return String(localized: "rightSidebar.mode.gitlab", defaultValue: "GitLab")
        case .gitStatus: return String(localized: "rightSidebar.mode.gitStatus", defaultValue: "Changes")
        case .autoTasks: return String(localized: "rightSidebar.mode.autoTasks", defaultValue: "Auto-Tasks")
        case .autoTaskConfig: return String(localized: "rightSidebar.mode.autoTaskConfig", defaultValue: "Auto-Task Config")
        case .customSidebar: return String(localized: "rightSidebar.mode.customSidebar", defaultValue: "Custom")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "books.vertical"
        case .feed: return "dot.radiowaves.left.and.right"
        case .dock: return "dock.rectangle"
        case .gitlab: return "arrow.triangle.merge"
        case .gitStatus: return "checklist"
        case .autoTasks: return "clock.badge.checkmark"
        case .autoTaskConfig: return "slider.horizontal.3"
        case .customSidebar: return "wand.and.stars"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .find: return .switchRightSidebarToFind
        case .sessions: return .switchRightSidebarToSessions
        case .feed: return .switchRightSidebarToFeed
        case .dock: return .switchRightSidebarToDock
        case .gitlab: return .switchRightSidebarToGitlab
        case .gitStatus: return nil
        case .autoTasks: return nil
        case .autoTaskConfig: return nil
        case .customSidebar: return nil
        }
    }
}

extension RightSidebarMode {
    // `autoTaskConfig` is pane-only: it is a wide editor, not a sidebar
    // view, so it is absent from `availableModes` but present here.
    static let paneModes: [RightSidebarMode] = [.files, .find, .sessions, .gitlab, .gitStatus, .autoTasks, .autoTaskConfig]

    var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }
}

enum RightSidebarContentMountPolicy {
    static func shouldMountContent(isRightSidebarVisible: Bool, hasMountedContent: Bool) -> Bool {
        isRightSidebarVisible || hasMountedContent
    }
}

enum FileExplorerRootSyncPolicy {
    static func shouldSyncFileExplorerStore(isRightSidebarVisible: Bool, mode: RightSidebarMode) -> Bool {
        guard isRightSidebarVisible else { return false }
        switch mode {
        case .files, .find:
            return true
        case .sessions, .feed, .dock, .gitlab, .gitStatus, .autoTasks, .autoTaskConfig, .customSidebar:
            return false
        }
    }
}

extension RightSidebarMode {
    static func modeShortcut(for event: NSEvent) -> RightSidebarMode? {
        modeShortcut(for: event, allowingAction: { _ in true })
    }

    static func modeShortcut(
        for event: NSEvent,
        allowingAction: (KeyboardShortcutSettings.Action) -> Bool
    ) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        for mode in RightSidebarMode.allCases {
            guard let action = mode.shortcutAction,
                  allowingAction(action),
                  mode.isAvailable(),
                  KeyboardShortcutSettings.shortcut(for: action).matches(event: event) else {
                continue
            }
            return mode
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToGitlab).matches(event: event),
           RightSidebarMode.gitlab.isAvailable() {
            return .gitlab
        }
        return nil
    }
}

/// Right sidebar root view. Hosts a segmented mode picker plus the active panel.
struct RightSidebarPanelView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var fileExplorerStore: FileExplorerStore
    @ObservedObject var fileExplorerState: FileExplorerState
    @ObservedObject var sessionIndexStore: SessionIndexStore
    let titlebarHeight: CGFloat
    let windowAppearance: WindowAppearanceSnapshot
    let workspaceId: UUID?
    var workspace: Workspace? = nil
    var editingNoteId: Binding<UUID?>? = nil
    let onResumeSession: ((SessionEntry) -> Void)?
    let onOpenFilePreview: (String) -> Void
    let onOpenAsPane: (RightSidebarMode) -> Void
    let onClose: () -> Void

    @AppStorage("rightSidebar.notes.collapsed")
    private var notesCollapsed: Bool = false
    @AppStorage("rightSidebar.notes.height")
    private var notesPanelHeight: Double = 180
    @State private var notesDragStartHeight: CGFloat?
    @State private var isDraggingNotesDivider: Bool = false

    private static let notesPanelMinHeight: CGFloat = 80
    private static let notesPanelMaxHeight: CGFloat = 500

    @State private var modeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOrControl) { window in
        guard let responder = window.firstResponder else { return false }
        return AppDelegate.shared?.isRightSidebarFocusResponder(responder, in: window) == true
    }
    @State private var focusShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var closeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var hasMountedRightSidebarContent = false
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
    private let closeShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintX
    private let closeShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintY
    private let focusShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintX
    private let focusShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintY
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @AppStorage(RightSidebarBetaFeatureSettings.feedEnabledKey)
    private var feedEnabled = RightSidebarBetaFeatureSettings.defaultFeedEnabled
    @AppStorage(RightSidebarBetaFeatureSettings.dockEnabledKey)
    private var dockEnabled = RightSidebarBetaFeatureSettings.defaultDockEnabled

    // Re-reading the observable store inside modeBar causes SwiftUI to
    // track the pending count so the badge updates live when hooks push
    // new items.
    private var feedPendingCount: Int {
        FeedCoordinator.shared.store?.pending.count ?? 0
    }

    private var availableModes: [RightSidebarMode] {
        RightSidebarMode.availableModes(feedEnabled: feedEnabled, dockEnabled: dockEnabled)
    }

    private var modeBarItems: [RightSidebarModeBarItem] {
        availableModes.map { RightSidebarModeBarItem(kind: .mode($0)) }
    }

    private var focusShortcutHintAnimationValue: Bool {
        alwaysShowShortcutHints || (showModifierHoldHints && focusShortcutHintMonitor.isModifierPressed)
    }

    private func startShortcutHintMonitorsIfNeeded() {
        guard showModifierHoldHints else {
            stopShortcutHintMonitors()
            return
        }
        modeShortcutHintMonitor.start()
        focusShortcutHintMonitor.start()
        closeShortcutHintMonitor.start()
    }

    private func stopShortcutHintMonitors() {
        modeShortcutHintMonitor.stop()
        focusShortcutHintMonitor.stop()
        closeShortcutHintMonitor.stop()
    }

    var body: some View {
        VStack(spacing: 0) {
            notesHeaderSection
            modeBar
                .rightSidebarChromeBottomBorder()
            contentForMode
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shortcutHintVisibilityAnimation(value: focusShortcutHintAnimationValue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RightSidebarKeyboardFocusBridge()
            .frame(width: 1, height: 1)
        )
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                let hintWindow = showModifierHoldHints ? window : nil
                modeShortcutHintMonitor.setHostWindow(hintWindow)
                focusShortcutHintMonitor.setHostWindow(hintWindow)
                closeShortcutHintMonitor.setHostWindow(hintWindow)
            }
            .frame(width: 0, height: 0)
        )
        .accessibilityIdentifier("RightSidebar")
        .onAppear {
            startShortcutHintMonitorsIfNeeded()
            if fileExplorerState.isVisible { hasMountedRightSidebarContent = true }
            fileExplorerState.refreshModeAvailability()
        }
        .onDisappear {
            stopShortcutHintMonitors()
        }
        .onChange(of: showModifierHoldHints) { _, _ in
            startShortcutHintMonitorsIfNeeded()
        }
        .onChange(of: fileExplorerState.isVisible) { _, visible in
            if visible { hasMountedRightSidebarContent = true }
        }
        .onChange(of: feedEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
        .onChange(of: dockEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
    }

    private var modeBar: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        return ZStack {
            WindowDragHandleView()

            HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
                ForEach(modeBarItems) { item in
                    let shortcut = item.shortcutAction.map { KeyboardShortcutSettings.shortcut(for: $0) } ?? .unbound
                    ModeBarButton(
                        item: item,
                        isSelected: item.isSelected(
                            mode: fileExplorerState.mode
                        ),
                        badgeCount: item.mode == .feed ? feedPendingCount : 0,
                        shortcutHint: shortcut,
                        showsShortcutHint: ShortcutHintTitlebarPolicy.shouldShow(
                            shortcut: shortcut,
                            alwaysShowShortcutHints: alwaysShowShortcutHints,
                            modifierPressed: modeShortcutHintMonitor.isModifierPressed,
                            modifierHoldHintsEnabled: showModifierHoldHints
                        )
                    ) {
                        let mode = item.mode
                        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                            mode: mode,
                            focusFirstItem: true,
                            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                        ) != true {
                            selectMode(mode)
                        }
                    }
                }
                Spacer(minLength: 0)
                if fileExplorerState.mode.canOpenAsPane {
                    openAsPaneButton(mode: fileExplorerState.mode)
                }
                closeButton
            }
        }
        .rightSidebarChromeBar(leadingPadding: 4, trailingPadding: 6, height: titlebarHeight)
        .overlay(alignment: .topLeading) {
            focusShortcutHintOverlay
        }
        .background(TitlebarDoubleClickMonitorView())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RightSidebarModeBar")
        .reportRightSidebarChromeGeometryForBonsplitUITest(
            isVisible: true,
            titlebarHeight: titlebarHeight
        )
    }

    private func openAsPaneButton(mode: RightSidebarMode) -> some View {
        Button {
            onOpenAsPane(mode)
        } label: {
            HeaderChromeIconStyle.symbol("rectangle.split.2x1")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderOpenAsPaneIcon"))
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
            keyPrefix: "rightSidebarHeaderOpenAsPane",
            isVisible: true
        )
        .rightSidebarHeaderControlAlignment()
        .safeHelp(String(localized: "rightSidebar.openAsPane.tooltip", defaultValue: "Open as pane"))
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "rightSidebar.openAsPane.accessibilityLabel", defaultValue: "Open %@ as Pane"),
                mode.label
            )
        )
        .accessibilityIdentifier("RightSidebar.openAsPaneButton")
        .titlebarInteractiveControl()
    }

    private var closeButton: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleRightSidebar)
        let showsShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: closeShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        return ZStack {
            Button(action: onClose) {
                HeaderChromeIconStyle.symbol("xmark")
            }
            .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderCloseIcon"))
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: "rightSidebarHeaderClose",
                isVisible: true
            )
            .safeHelp(
                KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                    String(localized: "rightSidebar.toggle.tooltip", defaultValue: "Toggle right sidebar")
                )
            )
            .accessibilityLabel(String(localized: "rightSidebar.close.accessibilityLabel", defaultValue: "Close Right Sidebar"))
            .accessibilityIdentifier("RightSidebar.closeButton")
        }
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .overlay(alignment: .top) {
            if showsShortcutHint {
                ShortcutHintPill(shortcut: shortcut, fontSize: 9, emphasis: 1.05)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(
                        x: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintXOffset)),
                        y: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintYOffset))
                    )
                    .shortcutHintTransition()
                    .accessibilityIdentifier("rightSidebarCloseShortcutHint")
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .rightSidebarHeaderControlAlignment()
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .titlebarInteractiveControl()
    }

    @ViewBuilder
    private var focusShortcutHintOverlay: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .focusRightSidebar)
        let showsFocusShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: focusShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        if showsFocusShortcutHint {
            ShortcutHintPill(
                shortcut: shortcut,
                fontSize: 9,
                emphasis: 1.05
            )
                .padding(.leading, 6)
                .padding(.top, 5)
                .offset(
                    x: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintXOffset)),
                    y: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintYOffset))
                )
                .shortcutHintTransition()
                .accessibilityIdentifier("rightSidebarFocusShortcutHint")
                .allowsHitTesting(false)
                .zIndex(10)
        }
    }

    @ViewBuilder
    private var contentForMode: some View {
        if RightSidebarContentMountPolicy.shouldMountContent(isRightSidebarVisible: fileExplorerState.isVisible, hasMountedContent: hasMountedRightSidebarContent) {
            switch fileExplorerState.mode {
            case .files:
                FileExplorerPanelView(
                    store: fileExplorerStore,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .files
                )
            case .find:
                FileExplorerPanelView(
                    store: fileExplorerStore,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .find
                )
            case .sessions:
                SessionIndexView(store: sessionIndexStore, onResume: onResumeSession)
                    .onAppear {
                        sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
                    }
            case .feed:
                FeedPanelView()
            case .dock:
                dockPanel(windowAppearance: windowAppearance)
            case .gitlab:
                if let ws = workspace {
                    GitLabSidebarView(workspace: ws, tabManager: tabManager)
                        .id(ws.id)
                } else {
                    Color.clear
                }
            case .gitStatus:
                if let ws = workspace {
                    GitStatusSidebarView(workspace: ws, onOpenFilePreview: onOpenFilePreview)
                        .id(ws.id)
                } else {
                    Color.clear
                }
            case .autoTasks:
                AutoTaskListView(
                    store: .shared,
                    projectId: workspace.flatMap(AutoTaskLauncher.owningProjectId(for:)),
                    actions: AutoTaskPanelActions.make(tabManager: tabManager),
                    onOpenConfig: { onOpenAsPane(.autoTaskConfig) }
                )
            case .autoTaskConfig:
                if let ws = workspace {
                    AutoTaskConfigView(repositoryPath: ws.currentDirectory)
                        .id(ws.currentDirectory)
                } else {
                    Color.clear
                }
            case .customSidebar:
                EmptyView()
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var notesHeaderSection: some View {
        if let ws = workspace, let editingBinding = editingNoteId {
            VStack(spacing: 0) {
                notesHeaderBar(workspace: ws, editingNoteId: editingBinding)
                if !notesCollapsed {
                    WorkspaceNotesPanelView(
                        workspace: ws,
                        editingNoteId: editingBinding,
                        darkBackground: false,
                        showsHeader: false
                    )
                    .frame(height: clampedNotesHeight)
                    notesResizeDivider
                }
            }
            .rightSidebarChromeBottomBorder()
        }
    }

    private var clampedNotesHeight: CGFloat {
        let raw = CGFloat(notesPanelHeight)
        return min(max(raw, Self.notesPanelMinHeight), Self.notesPanelMaxHeight)
    }

    private func notesHeaderBar(
        workspace: Workspace,
        editingNoteId: Binding<UUID?>
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                notesCollapsed.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(notesCollapsed ? 0 : 90))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(notesCollapsed
                ? String(localized: "rightSidebar.notes.expand", defaultValue: "Expand notes")
                : String(localized: "rightSidebar.notes.collapse", defaultValue: "Collapse notes"))

            Text(String(localized: "notes.sidebar.title", defaultValue: "Notes"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !workspace.notes.isEmpty {
                Text("\(workspace.notes.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if !notesCollapsed,
               workspace.notes.contains(where: { $0.isCompleted }) {
                Button {
                    deleteCompletedNotes(in: workspace, editingNoteId: editingNoteId)
                } label: {
                    Image(systemName: "checkmark.circle.badge.xmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "notes.sidebar.deleteCompleted", defaultValue: "Delete completed notes"))
            }

            Button {
                if notesCollapsed { notesCollapsed = false }
                let note = WorkspaceNote()
                workspace.notes.append(note)
                editingNoteId.wrappedValue = note.id
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "rightSidebar.notes.add", defaultValue: "Add note"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            notesCollapsed.toggle()
        }
    }

    private var notesResizeDivider: some View {
        Rectangle()
            .fill(isDraggingNotesDivider ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15))
            .frame(height: isDraggingNotesDivider ? 2 : 1)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { value in
                        if notesDragStartHeight == nil {
                            notesDragStartHeight = clampedNotesHeight
                        }
                        isDraggingNotesDivider = true
                        let start = notesDragStartHeight ?? clampedNotesHeight
                        let proposed = start + value.translation.height
                        notesPanelHeight = Double(
                            min(max(proposed, Self.notesPanelMinHeight), Self.notesPanelMaxHeight)
                        )
                    }
                    .onEnded { _ in
                        notesDragStartHeight = nil
                        isDraggingNotesDivider = false
                    }
            )
    }

    private func deleteCompletedNotes(
        in workspace: Workspace,
        editingNoteId: Binding<UUID?>
    ) {
        let removedIds = Set(workspace.notes.filter { $0.isCompleted }.map { $0.id })
        guard !removedIds.isEmpty else { return }
        if let editing = editingNoteId.wrappedValue, removedIds.contains(editing) {
            editingNoteId.wrappedValue = nil
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            workspace.notes.removeAll { removedIds.contains($0.id) }
        }
    }

    private var sessionIndexDirectory: String? {
        sessionIndexStore.currentDirectory
    }

    /// Renders this window's own Dock (created lazily on first show); no
    /// window ever defers to a Dock rendered elsewhere.
    @ViewBuilder
    private func dockPanel(windowAppearance: WindowAppearanceSnapshot) -> some View {
        if let app = AppDelegate.shared, let dock = app.windowDock(for: tabManager) {
            DockPanelView(
                store: dock,
                isSidebarVisible: fileExplorerState.isVisible,
                mode: fileExplorerState.mode,
                rootDirectory: nil,
                windowAppearance: windowAppearance,
                rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus
            )
            .id("dock.window.\(dock.workspaceId.uuidString)")
        } else {
            Color.clear
        }
    }

    private func selectMode(_ mode: RightSidebarMode) {
        fileExplorerState.mode = mode
        if fileExplorerState.mode == .sessions {
            sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
            if sessionIndexStore.entries.isEmpty {
                sessionIndexStore.reload()
            }
        }
    }

    private func refreshModeAvailabilityAndFocusIfNeeded() {
        let previousMode = fileExplorerState.mode
        fileExplorerState.refreshModeAvailability()
        let mode = fileExplorerState.mode
        // The Dock manages its own lifecycle from DockPanelView, so no dock sync
        // is needed here when the mode is unchanged.
        guard previousMode != mode,
              fileExplorerState.isVisible,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else { return }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: fileExplorerState.mode,
            focusFirstItem: false,
            preferredWindow: window
        )
    }
}

private struct RightSidebarKeyboardFocusBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> RightSidebarKeyboardFocusView {
        let view = RightSidebarKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return view
    }

    func updateNSView(_ nsView: RightSidebarKeyboardFocusView, context: Context) {
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class RightSidebarKeyboardFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
#if DEBUG
        dlog(
            "rs.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if event.keyCode == 53 {
            if let window,
               AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else {
#if DEBUG
            dlog("rs.focus.host.focus result=0 reason=noWindow")
#endif
            return false
        }
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "rs.focus.host.focus result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }
}

extension NSView {
    var cmuxCanAcceptRightSidebarKeyboardFocus: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var view: NSView? = self
        while let current = view {
            if current.bounds.width <= 0.5 || current.bounds.height <= 0.5 {
                return false
            }
            view = current.superview
        }
        return true
    }
}

// MARK: - Git status sidebar mode

/// A changed file in the working copy.
struct GitStatusFile: Identifiable, Equatable {
    enum Group: Int { case staged, unstaged, untracked }
    let id: String        // "<group>:<path>" so a file staged AND modified lists twice
    let path: String
    let code: String      // one-letter status (M/A/D/R/?/…)
    let group: Group
}

/// Runs `git status --porcelain` on the workspace repo and groups the files.
enum WorkingCopyStatusProvider {
    static func compute(workingDirectory: String) -> [GitStatusFile] {
        guard !workingDirectory.isEmpty else { return [] }
        guard let output = runGit(
            in: workingDirectory,
            arguments: ["status", "--porcelain"]
        ) else { return [] }

        var files: [GitStatusFile] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count >= 3 else { continue }
            let chars = Array(line)
            let x = chars[0]   // staged (index)
            let y = chars[1]   // unstaged (working tree)
            var path = String(line.dropFirst(3))
            // Renames come as "old -> new"; keep the new path.
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            if x == "?" && y == "?" {
                files.append(GitStatusFile(id: "u:\(path)", path: path, code: "?", group: .untracked))
                continue
            }
            if x != " " {
                files.append(GitStatusFile(id: "s:\(path)", path: path, code: String(x), group: .staged))
            }
            if y != " " {
                files.append(GitStatusFile(id: "w:\(path)", path: path, code: String(y), group: .unstaged))
            }
        }
        return files
    }

    static func branchName(workingDirectory: String) -> String? {
        guard !workingDirectory.isEmpty else { return nil }
        guard let output = runGit(
            in: workingDirectory,
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"]
        ) else { return nil }
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func runGit(in directory: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// Loads the working-copy status off the main thread and publishes it.
@MainActor
final class GitStatusStore: ObservableObject {
    @Published private(set) var files: [GitStatusFile] = []
    @Published private(set) var branch: String?
    @Published private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?

    func load(directory: String) {
        loadTask?.cancel()
        guard !directory.isEmpty else {
            files = []
            isLoading = false
            return
        }
        isLoading = true
        loadTask = Task { [weak self] in
            let (result, branchName) = await Task.detached(priority: .userInitiated) {
                (
                    WorkingCopyStatusProvider.compute(workingDirectory: directory),
                    WorkingCopyStatusProvider.branchName(workingDirectory: directory)
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            self.files = result
            self.branch = branchName
            self.isLoading = false
        }
    }
}

/// SourceTree-style "changes" viewer: lists working-copy files grouped by
/// staged / modified / untracked. Click a row to open the working-tree diff;
/// right-click to open the file itself.
struct GitStatusSidebarView: View {
    @ObservedObject var workspace: Workspace
    /// Same opener the file explorer uses, so "Open in Editor" here lands in
    /// the same place — and honours the same preference — as double-clicking
    /// the file in the Files panel.
    let onOpenFilePreview: (String) -> Void
    @StateObject private var store = GitStatusStore()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.darculaBorder).frame(height: 1)
            content
        }
        .background(Color.darculaSidebarBackground)
        .onAppear { store.load(directory: workspace.currentDirectory) }
        .onChange(of: workspace.currentDirectory) { newDirectory in
            store.load(directory: newDirectory)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "gitStatus.title", defaultValue: "Changes"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.darculaForeground)
                if let branch = store.branch, !branch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text(branch)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Color.darculaForeground.opacity(0.6))
                }
            }
            Spacer()
            Button {
                store.load(directory: workspace.currentDirectory)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.darculaForeground.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(workspace.currentDirectory.isEmpty)
            .help(String(localized: "gitStatus.refresh", defaultValue: "Refresh"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.currentDirectory.isEmpty {
            emptyState(String(localized: "gitStatus.noRepo", defaultValue: "No repository for this workspace"))
        } else if store.files.isEmpty {
            emptyState(store.isLoading
                ? String(localized: "gitStatus.loading", defaultValue: "Loading…")
                : String(localized: "gitStatus.clean", defaultValue: "No changes — working tree clean"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    fileGroup(.staged, title: String(localized: "gitStatus.group.staged", defaultValue: "Staged"))
                    fileGroup(.unstaged, title: String(localized: "gitStatus.group.modified", defaultValue: "Modified"))
                    fileGroup(.untracked, title: String(localized: "gitStatus.group.untracked", defaultValue: "Untracked"))
                }
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private func fileGroup(_ group: GitStatusFile.Group, title: String) -> some View {
        let items = store.files.filter { $0.group == group }
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.darculaForeground.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(items) { file in
                fileRow(file)
            }
        }
    }

    private func fileRow(_ file: GitStatusFile) -> some View {
        HStack(spacing: 8) {
            Text(file.code)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color(for: file.code))
                .frame(width: 14, alignment: .center)
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(Color.darculaForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { openDiff(file) }
        .contextMenu { fileRowMenuItems(file) }
        .help(file.path)
    }

    @ViewBuilder
    private func fileRowMenuItems(_ file: GitStatusFile) -> some View {
        // A deleted file has no working-copy content left, so opening or
        // revealing it would fail silently. Its diff still works.
        let url = absoluteURL(for: file)
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        Button {
            guard let url else { return }
            performFileExplorerFileOpen(path: url.path, onOpenFilePreview: onOpenFilePreview)
        } label: {
            Text(String(localized: "gitStatus.row.openInEditor", defaultValue: "Open in Editor"))
        }
        .disabled(!exists)
        Button {
            openDiff(file)
        } label: {
            Text(String(localized: "gitStatus.row.showDiff", defaultValue: "Show Diff"))
        }
        Divider()
        Button {
            guard let url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Text(String(localized: "fileExplorer.contextMenu.revealInFinder", defaultValue: "Reveal in Finder"))
        }
        .disabled(!exists)
        Button {
            guard let url else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
        } label: {
            Text(String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"))
        }
        .disabled(url == nil)
    }

    /// `git status --porcelain` reports paths relative to the repository root,
    /// which is the workspace directory here.
    private func absoluteURL(for file: GitStatusFile) -> URL? {
        guard !workspace.currentDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: workspace.currentDirectory)
            .appendingPathComponent(file.path)
    }

    private func color(for code: String) -> Color {
        switch code {
        case "A": return .green
        case "D": return .red
        case "M": return .orange
        case "?": return Color.darculaForeground.opacity(0.5)
        default: return Color.darculaForeground.opacity(0.85)
        }
    }

    private func openDiff(_ file: GitStatusFile) {
        guard !workspace.currentDirectory.isEmpty else { return }
        // Scope the diff to the clicked file only. `compare == nil` diffs the
        // working tree against HEAD, so a modified/staged file shows exactly
        // its own uncommitted changes instead of the whole working tree.
        let spec = GitDiffSpec(
            base: "HEAD",
            compare: nil,
            directory: workspace.currentDirectory,
            title: (file.path as NSString).lastPathComponent,
            pathspec: [file.path]
        )
        GitDiffWindowRegistry.show(spec: spec)
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color.darculaForeground.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
