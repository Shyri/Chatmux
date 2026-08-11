import SwiftUI

/// Immutable snapshot of one queued run, plus the actions available on it.
///
/// Rows below a `LazyVStack` must never hold an `ObservableObject` — that is
/// the class of bug that pegged the main thread five separate times in this
/// repo's sidebar (#2586, #6556 and friends). So the row gets values and
/// closures and nothing else.
struct AutoTaskRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let issueIID: Int
    let issueTitle: String
    let repositoryName: String
    let scheduledAt: Date
    let state: ScheduledAutoTask.State
    let failureReason: String?
    let canOpenChat: Bool

    init(task: ScheduledAutoTask) {
        id = task.id
        issueIID = task.issueIID
        issueTitle = task.issueTitle
        repositoryName = URL(fileURLWithPath: task.repositoryPath).lastPathComponent
        scheduledAt = task.scheduledAt
        state = task.state
        failureReason = task.failureReason
        canOpenChat = task.chatPanelId != nil
    }
}

/// Action bundle handed down to rows. Closures only — see `AutoTaskRowSnapshot`.
struct AutoTaskRowActions {
    let runNow: (UUID) -> Void
    let cancel: (UUID) -> Void
    let remove: (UUID) -> Void
    let openChat: (UUID) -> Void
}

/// The Auto-Tasks panel: what is queued, what missed its window, and what has
/// already been launched.
struct AutoTaskListView: View {
    @ObservedObject var store: AutoTaskStore
    /// The project whose tasks this panel shows — the one the surrounding
    /// workspace belongs to. `nil` for a workspace that is not a saved project,
    /// which then sees the whole queue.
    let projectId: UUID?
    let actions: AutoTaskRowActions
    let onOpenConfig: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visibleTasks.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Color.darculaSidebarBackground)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(String(localized: "autoTask.panel.title", defaultValue: "Auto-Tasks"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.darculaForeground.opacity(0.85))
            Spacer()
            Button(action: onOpenConfig) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.darculaForeground.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.darculaBorder, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help(String(
                localized: "autoTask.panel.openConfig",
                defaultValue: "Edit auto-task configuration"
            ))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 22))
                .foregroundStyle(Color.darculaForeground.opacity(0.35))
            Text(String(
                localized: "autoTask.panel.empty",
                defaultValue: "No auto-tasks scheduled"
            ))
            .font(.system(size: 11))
            .foregroundStyle(Color.darculaForeground.opacity(0.6))
            Text(String(
                localized: "autoTask.panel.emptyHint",
                defaultValue: "Right-click an issue in the GitLab panel to run or schedule one."
            ))
            .font(.system(size: 10))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.darculaForeground.opacity(0.4))
            .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Scoped to the active project. Ownerless tasks come through too — see
    /// `AutoTaskStore.tasks(inProject:)` for why hiding them would be worse.
    private var visibleTasks: [ScheduledAutoTask] {
        store.tasks(inProject: projectId)
    }

    /// Sections are computed once here, above the `LazyVStack`, into plain
    /// value snapshots. Nothing below this line can reach the store.
    private var sections: [(title: String, rows: [AutoTaskRowSnapshot])] {
        var missed: [AutoTaskRowSnapshot] = []
        var upcoming: [AutoTaskRowSnapshot] = []
        var history: [AutoTaskRowSnapshot] = []
        for task in visibleTasks {
            let row = AutoTaskRowSnapshot(task: task)
            switch task.state {
            case .missed: missed.append(row)
            case .pending: upcoming.append(row)
            case .launched, .cancelled, .failed: history.append(row)
            }
        }
        missed.sort { $0.scheduledAt < $1.scheduledAt }
        upcoming.sort { $0.scheduledAt < $1.scheduledAt }
        history.sort { $0.scheduledAt > $1.scheduledAt }

        var out: [(String, [AutoTaskRowSnapshot])] = []
        if !missed.isEmpty {
            out.append((String(localized: "autoTask.section.missed", defaultValue: "Missed"), missed))
        }
        if !upcoming.isEmpty {
            out.append((String(localized: "autoTask.section.scheduled", defaultValue: "Scheduled"), upcoming))
        }
        if !history.isEmpty {
            out.append((String(localized: "autoTask.section.history", defaultValue: "History"), history))
        }
        return out
    }

    private var list: some View {
        let snapshot = sections
        let rowActions = actions
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(snapshot, id: \.title) { section in
                    Section {
                        ForEach(section.rows) { row in
                            AutoTaskRowView(row: row, actions: rowActions)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.darculaForeground.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.darculaSidebarBackground)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// One queued run. Values and closures only.
private struct AutoTaskRowView: View {
    let row: AutoTaskRowSnapshot
    let actions: AutoTaskRowActions
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: stateSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stateColor)
                Text("#\(row.issueIID)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.darculaForeground.opacity(0.9))
                Spacer()
                Text(row.repositoryName)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.darculaForeground.opacity(0.45))
                    .lineLimit(1)
            }
            if !row.issueTitle.isEmpty {
                Text(row.issueTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.darculaForeground.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text(Self.timestamp(row.scheduledAt))
                Text("·")
                Text(stateLabel)
                    .foregroundStyle(stateColor)
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.darculaForeground.opacity(0.5))

            if let reason = row.failureReason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.darculaCardHover : Color.darculaCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.darculaBorder, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if row.state != .launched {
                Button {
                    actions.runNow(row.id)
                } label: {
                    Label(
                        String(localized: "autoTask.row.runNow", defaultValue: "Run Now"),
                        systemImage: "bolt.circle"
                    )
                }
            }
            if row.canOpenChat {
                Button {
                    actions.openChat(row.id)
                } label: {
                    Label(
                        String(localized: "autoTask.row.openChat", defaultValue: "Go to Chat"),
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
            }
            Divider()
            if row.state == .pending {
                Button {
                    actions.cancel(row.id)
                } label: {
                    Label(
                        String(localized: "autoTask.row.cancel", defaultValue: "Cancel"),
                        systemImage: "xmark.circle"
                    )
                }
            }
            Button(role: .destructive) {
                actions.remove(row.id)
            } label: {
                Label(
                    String(localized: "autoTask.row.remove", defaultValue: "Remove from List"),
                    systemImage: "trash"
                )
            }
        }
    }

    private var stateSymbol: String {
        switch row.state {
        case .pending: return "clock"
        case .missed: return "exclamationmark.triangle"
        case .launched: return "bolt.fill"
        case .cancelled: return "xmark.circle"
        case .failed: return "xmark.octagon"
        }
    }

    private var stateColor: Color {
        switch row.state {
        case .pending: return Color.darculaAccent
        case .missed: return .orange
        case .launched: return .green
        case .cancelled: return Color.darculaForeground.opacity(0.45)
        case .failed: return .red
        }
    }

    private var stateLabel: String {
        switch row.state {
        case .pending:
            return String(localized: "autoTask.state.pending", defaultValue: "scheduled")
        case .missed:
            return String(localized: "autoTask.state.missed", defaultValue: "missed its window")
        case .launched:
            return String(localized: "autoTask.state.launched", defaultValue: "launched")
        case .cancelled:
            return String(localized: "autoTask.state.cancelled", defaultValue: "cancelled")
        case .failed:
            return String(localized: "autoTask.state.failed", defaultValue: "could not start")
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
