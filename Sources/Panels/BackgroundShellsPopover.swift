import AppKit
import Combine
import SwiftUI

/// Inline `/bashes`-style panel for the Claude chat. Lists every Bash
/// invocation we have seen run with `run_in_background: true`, with
/// its current state (starting / running / completed / killed) and a
/// Kill button that asks claude to invoke `KillShell`. We intentionally
/// don't surface the shell's output — the user wants visibility and
/// control, not log streaming.
struct BackgroundShellsPopover: View {
    @ObservedObject var panel: ClaudeChatPanel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if panel.backgroundShells.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(panel.backgroundShells) { shell in
                            row(shell)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(14)
        .frame(width: 460)
    }

    private var header: some View {
        let running = panel.backgroundShells.filter { isLive($0.status) }.count
        let finished = panel.backgroundShells.filter { !isLive($0.status) }.count
        return HStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundColor(ChatPalette.cyan)
            Text(String(
                localized: "claudeChat.bashes.title",
                defaultValue: "Background shells"
            ))
            .font(.system(size: 13, weight: .semibold))
            if running > 0 {
                Text("(\(running))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if finished > 0 {
                Button {
                    panel.dismissFinishedBackgroundShells()
                } label: {
                    Text(String(
                        localized: "claudeChat.bashes.clearFinished",
                        defaultValue: "Clear finished"
                    ))
                    .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(String(
                    localized: "claudeChat.bashes.clearFinished.tooltip",
                    defaultValue: "Remove all finished shells from the list"
                ))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text(String(
                localized: "claudeChat.bashes.empty",
                defaultValue: "No background shells. They appear here when claude runs a command in the background."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func row(_ shell: ClaudeChatPanel.BackgroundShell) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot(shell.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if shell.kind == .agentTask {
                        Image(systemName: "gearshape.2")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .help(String(
                                localized: "claudeChat.bashes.agentTaskLabel",
                                defaultValue: "The agent's own background task"
                            ))
                    }
                    Text(shell.commandPreview)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    if let shellId = shell.shellId, !shellId.isEmpty {
                        Text(shellId)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text(String(
                            localized: "claudeChat.bashes.noId",
                            defaultValue: "(no shell_id yet)"
                        ))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                    statusBadge(shell.status)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(Self.relativeAge(shell.startedAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                // Why a stop did not take. Without this the row silently rolled
                // back to Running and the click looked like it did nothing.
                if let reason = shell.stopFailureReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundColor(ChatPalette.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            actionButtons(for: shell)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackground(for: shell.status))
        )
    }

    @ViewBuilder
    private func actionButtons(for shell: ClaudeChatPanel.BackgroundShell) -> some View {
        HStack(spacing: 6) {
            outputButton(for: shell)
            killOrDismissButton(for: shell)
        }
    }

    @ViewBuilder
    private func outputButton(for shell: ClaudeChatPanel.BackgroundShell) -> some View {
        if let path = shell.outputFilePath, !path.isEmpty {
            Button {
                BackgroundShellOutputWindow.present(
                    title: shell.shellId ?? shell.commandPreview,
                    outputPath: path,
                    isDark: colorScheme == .dark
                )
            } label: {
                Label(String(
                    localized: "claudeChat.bashes.output",
                    defaultValue: "Output"
                ), systemImage: "doc.plaintext")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.bashes.output.tooltip",
                defaultValue: "Open this shell's live output in a window"
            ))
        }
    }

    @ViewBuilder
    private func killOrDismissButton(for shell: ClaudeChatPanel.BackgroundShell) -> some View {
        // Addressable by *either* id: a `shell_id` from a Bash tool_result, or
        // a `task_id` from the harness' events — nearly every background
        // command arrives as the latter now. Gating on `shellId` alone hid the
        // button for exactly the shells people want to stop.
        let identifier = shell.taskId ?? shell.shellId
        if isLive(shell.status), let identifier, !identifier.isEmpty {
            Button {
                panel.killBackgroundShell(rowId: shell.id)
            } label: {
                Label(String(
                    localized: "claudeChat.bashes.kill",
                    defaultValue: "Kill"
                ), systemImage: "xmark.octagon")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(shell.status == .stopping)
            .help(String(
                localized: "claudeChat.bashes.kill.tooltip",
                defaultValue: "Ask claude to stop this shell"
            ))
        } else {
            Button {
                panel.dismissBackgroundShell(toolUseId: shell.toolUseId)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.bashes.dismiss.tooltip",
                defaultValue: "Hide this row from the list"
            ))
        }
    }

    private func statusDot(_ status: ClaudeChatPanel.BackgroundShell.Status) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
            .padding(.top, 3)
    }

    private func statusBadge(_ status: ClaudeChatPanel.BackgroundShell.Status) -> some View {
        Text(statusText(status))
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(statusColor(status).opacity(0.15)))
    }

    private func statusText(_ status: ClaudeChatPanel.BackgroundShell.Status) -> String {
        switch status {
        case .starting:
            return String(
                localized: "claudeChat.bashes.status.starting",
                defaultValue: "Starting…"
            )
        case .running:
            return String(
                localized: "claudeChat.bashes.status.running",
                defaultValue: "Running"
            )
        case .completed(let code):
            if let code, !code.isEmpty {
                return String(
                    format: String(
                        localized: "claudeChat.bashes.status.completedCode",
                        defaultValue: "Exited (%@)"
                    ),
                    code
                )
            }
            return String(
                localized: "claudeChat.bashes.status.completed",
                defaultValue: "Exited"
            )
        case .stopping:
            return String(
                localized: "claudeChat.bashes.status.stopping",
                defaultValue: "Stopping…"
            )
        case .killed:
            return String(
                localized: "claudeChat.bashes.status.killed",
                defaultValue: "Killed"
            )
        case .unknown:
            return String(
                localized: "claudeChat.bashes.status.unknown",
                defaultValue: "Unknown"
            )
        }
    }

    private func statusColor(_ status: ClaudeChatPanel.BackgroundShell.Status) -> Color {
        switch status {
        case .starting: return ChatPalette.yellow
        case .running: return ChatPalette.cyan
        case .completed: return ChatPalette.green
        case .stopping: return ChatPalette.yellow
        case .killed: return ChatPalette.red
        case .unknown: return .secondary
        }
    }

    private func rowBackground(for status: ClaudeChatPanel.BackgroundShell.Status) -> Color {
        statusColor(status).opacity(0.08)
    }

    private func isLive(_ status: ClaudeChatPanel.BackgroundShell.Status) -> Bool {
        switch status {
        case .starting, .running, .unknown, .stopping: return true
        case .completed, .killed: return false
        }
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// Locale-aware "5 min ago"; gives the user a sense of how long a shell has
    /// been sitting in the list.
    private static func relativeAge(_ date: Date) -> String {
        ageFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Background shell output window

/// Presents a background shell's output file in a standalone, resizable floating
/// window that tails the file while the shell keeps writing. Mirrors the mermaid
/// diagram pop-out: instances retain themselves in `live` until their window
/// closes, so the transient popover view doesn't have to own them.
@MainActor
private final class BackgroundShellOutputWindow: NSObject, NSWindowDelegate {
    private static var live: [BackgroundShellOutputWindow] = []
    private var window: NSWindow?

    static func present(title: String, outputPath: String, isDark: Bool) {
        let controller = BackgroundShellOutputWindow()
        controller.show(title: title, outputPath: outputPath, isDark: isDark)
        live.append(controller)
    }

    private func show(title: String, outputPath: String, isDark: Bool) {
        let content = BackgroundShellOutputView(outputPath: outputPath)
            .frame(minWidth: 480, minHeight: 300)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = String(
            format: String(
                localized: "claudeChat.bashes.output.window.title",
                defaultValue: "Output — %@"
            ),
            title
        )
        window.setContentSize(NSSize(width: 720, height: 460))
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        Self.live.removeAll { $0 === self }
    }
}

/// Reads a background shell's output file on appear and re-reads it once a
/// second, auto-scrolling to the tail. Text is selectable/copyable. Only the
/// last chunk is loaded so a multi-megabyte log never stalls the main thread.
private struct BackgroundShellOutputView: View {
    let outputPath: String

    @State private var text: String = ""
    /// Fires on the main run loop; the subscription is torn down automatically
    /// when the view (and its window) goes away.
    private let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private static let tailByteLimit = 512 * 1024

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayText)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("cmux-output-end")
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { reload(proxy: proxy) }
            .onReceive(ticker) { _ in reload(proxy: proxy) }
        }
    }

    private var displayText: String {
        text.isEmpty
            ? String(
                localized: "claudeChat.bashes.output.empty",
                defaultValue: "Waiting for output…"
            )
            : text
    }

    private func reload(proxy: ScrollViewProxy) {
        guard let data = FileManager.default.contents(atPath: outputPath) else { return }
        let slice = data.count > Self.tailByteLimit ? data.suffix(Self.tailByteLimit) : data
        text = String(decoding: slice, as: UTF8.self)
        proxy.scrollTo("cmux-output-end", anchor: .bottom)
    }
}
