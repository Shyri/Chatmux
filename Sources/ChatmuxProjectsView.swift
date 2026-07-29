import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manager window for saved projects. Structure follows the session-presets
/// manager it replaces; what changed is the payload (one workspace instead of
/// every window) and, with it, what the detail pane can usefully report.
struct ChatmuxProjectsView: View {
    @ObservedObject private var store = ChatmuxProjectStore.shared
    @State private var selection: UUID?
    @State private var renamingId: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260)
            detail
                .frame(minWidth: 320)
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear {
            store.loadIfNeeded()
            if selection == nil {
                selection = store.projects.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatmuxProjectsDidChange)) { _ in
            if let selection, store.project(for: selection) == nil {
                self.selection = store.projects.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.projects) { project in
                    projectRow(project)
                        .tag(project.id)
                        .contextMenu { contextMenu(for: project) }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 6) {
                Button {
                    AppDelegate.shared?.presentSaveCurrentWorkspaceAsProjectPrompt()
                } label: {
                    Image(systemName: "plus")
                }
                .help(String(
                    localized: "projects.action.saveFromCurrent.help",
                    defaultValue: "Save the current workspace as a new project"
                ))

                Button {
                    if let id = selection {
                        confirmAndDelete(id)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help(String(localized: "projects.action.delete.help", defaultValue: "Delete selected project"))

                Button {
                    if let id = selection { _ = store.duplicate(id: id) }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(selection == nil)
                .help(String(localized: "projects.action.duplicate.help", defaultValue: "Duplicate selected project"))

                Spacer()

                Menu {
                    Button(String(localized: "projects.action.import", defaultValue: "Import…")) {
                        importProject()
                    }
                    Button(String(localized: "projects.action.export", defaultValue: "Export…")) {
                        if let id = selection { exportProject(id) }
                    }
                    .disabled(selection == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func projectRow(_ project: ChatmuxProject) -> some View {
        HStack(spacing: 6) {
            if renamingId == project.id {
                TextField("", text: $renameDraft, onCommit: { commitRename(project) })
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand { renamingId = nil }
            } else {
                Text(project.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if isOpen(project) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundColor(.accentColor)
                    .help(String(localized: "projects.label.open", defaultValue: "Currently open"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openProject(project)
        }
    }

    @ViewBuilder
    private func contextMenu(for project: ChatmuxProject) -> some View {
        Button(String(localized: "projects.action.open", defaultValue: "Open")) {
            openProject(project)
        }
        Button(String(
            localized: "projects.action.updateFromCurrent",
            defaultValue: "Update from Current Workspace"
        )) {
            updateFromCurrentWorkspace(project)
        }
        Divider()
        Button(String(localized: "projects.action.rename", defaultValue: "Rename…")) {
            beginRename(project)
        }
        Button(String(localized: "projects.action.duplicate", defaultValue: "Duplicate")) {
            _ = store.duplicate(id: project.id)
        }
        Divider()
        Button(String(localized: "projects.action.export", defaultValue: "Export…")) {
            exportProject(project.id)
        }
        Divider()
        Button(String(localized: "projects.action.delete", defaultValue: "Delete"), role: .destructive) {
            confirmAndDelete(project.id)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let id = selection, let project = store.project(for: id) {
                detailContent(project)
            } else {
                VStack {
                    Spacer()
                    Text(String(localized: "projects.empty.title", defaultValue: "No project selected"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(String(
                        localized: "projects.empty.subtitle",
                        defaultValue: "Save the current workspace as a project, or pick one from the list."
                    ))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    @ViewBuilder
    private func detailContent(_ project: ChatmuxProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                if renamingId == project.id {
                    TextField("", text: $renameDraft, onCommit: { commitRename(project) })
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onExitCommand { renamingId = nil }
                } else {
                    Text(project.name)
                        .font(.title2.weight(.semibold))
                    Button {
                        beginRename(project)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "projects.action.rename", defaultValue: "Rename…"))
                }
                Spacer()
                if isOpen(project) {
                    Label(
                        String(localized: "projects.label.open", defaultValue: "Currently open"),
                        systemImage: "circle.fill"
                    )
                    .foregroundColor(.accentColor)
                    .font(.subheadline)
                }
            }

            statsBlock(project)

            HStack(spacing: 8) {
                Button(String(localized: "projects.action.open", defaultValue: "Open")) {
                    openProject(project)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(String(
                    localized: "projects.action.updateFromCurrent",
                    defaultValue: "Update from Current Workspace"
                )) {
                    updateFromCurrentWorkspace(project)
                }

                Button(String(localized: "projects.action.duplicate", defaultValue: "Duplicate")) {
                    _ = store.duplicate(id: project.id)
                }

                Spacer()

                Button(String(localized: "projects.action.export", defaultValue: "Export…")) {
                    exportProject(project.id)
                }

                Button(String(localized: "projects.action.delete", defaultValue: "Delete")) {
                    confirmAndDelete(project.id)
                }
                .tint(.red)
            }

            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private func statsBlock(_ project: ChatmuxProject) -> some View {
        let panels = project.snapshot.panels
        let chatCount = panels.filter { $0.claudeChat?.sessionId?.isEmpty == false }.count
        VStack(alignment: .leading, spacing: 6) {
            statRow(
                String(localized: "projects.detail.directory", defaultValue: "Directory"),
                value: project.snapshot.currentDirectory
            )
            statRow(
                String(localized: "projects.detail.panels", defaultValue: "Panels"),
                value: "\(panels.count)"
            )
            statRow(
                String(localized: "projects.detail.chats", defaultValue: "Chats"),
                value: "\(chatCount)"
            )
            statRow(
                String(localized: "projects.detail.lastOpened", defaultValue: "Last opened"),
                value: relativeDate(project.lastOpenedAt)
            )
            statRow(
                String(localized: "projects.detail.updated", defaultValue: "Updated"),
                value: relativeDate(project.updatedAt)
            )
        }
        .font(.callout)
        .foregroundColor(.secondary)
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func relativeDate(_ epoch: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    // MARK: - Actions

    private func isOpen(_ project: ChatmuxProject) -> Bool {
        AppDelegate.shared?.liveWorkspace(forStableId: project.workspaceStableId) != nil
    }

    private func openProject(_ project: ChatmuxProject) {
        _ = AppDelegate.shared?.openProject(project)
    }

    /// Only meaningful for the workspace this project owns — refreshing from an
    /// unrelated workspace would silently rebind the project to it.
    private func updateFromCurrentWorkspace(_ project: ChatmuxProject) {
        guard let delegate = AppDelegate.shared,
              let live = delegate.liveWorkspace(forStableId: project.workspaceStableId) else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "projects.dialog.notOpen.title",
                defaultValue: "Project is not open"
            )
            alert.informativeText = String(
                localized: "projects.dialog.notOpen.message",
                defaultValue: "Open this project first; it then updates itself when you close its workspace."
            )
            alert.runModal()
            return
        }
        _ = store.update(id: project.id, snapshot: delegate.projectSnapshot(for: live.workspace))
    }

    private func beginRename(_ project: ChatmuxProject) {
        renameDraft = project.name
        renamingId = project.id
    }

    private func commitRename(_ project: ChatmuxProject) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != project.name {
            _ = store.rename(id: project.id, to: trimmed)
        }
        renamingId = nil
    }

    private func confirmAndDelete(_ id: UUID) {
        guard let project = store.project(for: id) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(
                localized: "projects.dialog.delete.title.format",
                defaultValue: "Delete project \u{201C}%@\u{201D}?"
            ),
            project.name
        )
        alert.informativeText = String(
            localized: "projects.dialog.delete.message",
            defaultValue: "This deletes the saved layout and its copied chat transcripts. Any open workspace stays open."
        )
        alert.addButton(withTitle: String(localized: "common.delete", defaultValue: "Delete"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.delete(id: id)
        }
    }

    private func importProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "projects.import.panelTitle", defaultValue: "Import Project")
        panel.prompt = String(localized: "projects.import.panelPrompt", defaultValue: "Import")
        if let projectType = UTType(filenameExtension: ChatmuxProjectSchema.fileExtension) {
            panel.allowedContentTypes = [projectType, .json]
        } else {
            panel.allowedContentTypes = [.json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let imported = store.importFromURL(url) {
            selection = imported.id
        } else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "projects.import.failed.title",
                defaultValue: "Import failed"
            )
            alert.informativeText = String(
                localized: "projects.import.failed.message",
                defaultValue: "The selected file is not a valid Chatmux project."
            )
            alert.runModal()
        }
    }

    private func exportProject(_ id: UUID) {
        guard let project = store.project(for: id) else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "projects.export.panelTitle", defaultValue: "Export Project")
        panel.nameFieldStringValue = sanitizedFilename(project.name)
        if let projectType = UTType(filenameExtension: ChatmuxProjectSchema.fileExtension) {
            panel.allowedContentTypes = [projectType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.exportToURL(id: id, url) {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "projects.export.failed.title",
                defaultValue: "Export failed"
            )
            alert.informativeText = String(
                localized: "projects.export.failed.message",
                defaultValue: "Could not write the project to the selected location."
            )
            alert.runModal()
        }
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\u{0000}")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "project" : trimmed
    }
}
