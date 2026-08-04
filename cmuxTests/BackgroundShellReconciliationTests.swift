import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: the "Background shells" popover kept showing shells as
/// "Running" long after they had exited. cmux is a passive observer of the
/// `claude` CLI, so the only reliable "the shell finished" signal is the
/// `<task-notification>…<status>completed|failed|killed</status>` the harness
/// injects — which lands in the transcript as a `.text` block of a `role: .user`
/// message. On resume/reopen, `applyResumedTranscript` rebuilds the list from
/// the transcript but historically only replayed the `Bash` tool_use/tool_result
/// blocks (which leave every shell `.running`) and ignored those notifications.
///
/// These tests reconstruct that exact path and assert the terminal state is
/// recovered. Without the reconciliation fix they fail (the shell stays
/// `.running`).
@MainActor
@Suite struct BackgroundShellReconciliationTests {
    private func bashToolUse(id: String, command: String) -> ChatMessageBlock {
        let input = try! JSONSerialization.data(
            withJSONObject: ["command": command, "run_in_background": true]
        )
        return .toolUse(.init(
            id: id,
            name: "Bash",
            inputJSON: String(data: input, encoding: .utf8) ?? "{}"
        ))
    }

    private func taskNotification(taskId: String, toolUseId: String, status: String) -> ChatMessageBlock {
        .text(
            "<task-notification> <task-id>\(taskId)</task-id> "
            + "<tool-use-id>\(toolUseId)</tool-use-id> "
            + "<output-file>/tmp/tasks/\(taskId).output</output-file> "
            + "<status>\(status)</status> </task-notification>"
        )
    }

    private func resumedPanel(status: String, toolUseId: String, shellId: String) -> ClaudeChatPanel {
        let panel = ClaudeChatPanel(workspaceId: UUID(), workingDirectory: "/tmp")
        let messages: [ChatMessage] = [
            ChatMessage(role: .assistant, blocks: [
                bashToolUse(id: toolUseId, command: "sleep 100")
            ]),
            ChatMessage(role: .user, blocks: [
                .toolResult(.init(
                    toolUseId: toolUseId,
                    content: "Command running in background with ID: \(shellId)",
                    isError: false
                ))
            ]),
            ChatMessage(role: .user, blocks: [
                taskNotification(taskId: shellId, toolUseId: toolUseId, status: status)
            ])
        ]
        panel.applyResumedTranscript(sessionId: "sess1", messages: messages)
        return panel
    }

    @Test func resumeReconcilesCompletedShell() {
        let panel = resumedPanel(status: "completed", toolUseId: "toolu_bg1", shellId: "sh_done")
        #expect(panel.backgroundShells.count == 1)
        guard case .completed = panel.backgroundShells.first?.status else {
            Issue.record("expected .completed, got \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }

    @Test func resumeReconcilesFailedShell() {
        let panel = resumedPanel(status: "failed", toolUseId: "toolu_bg2", shellId: "sh_fail")
        guard case .completed = panel.backgroundShells.first?.status else {
            Issue.record("expected failed→completed, got \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }

    @Test func resumeHidesTaskNotificationFromTranscript() {
        // The raw <task-notification> must not surface as a chat bubble after a
        // resume; the real Bash tool_use/tool_result blocks stay.
        let panel = resumedPanel(status: "completed", toolUseId: "toolu_bg4", shellId: "sh_hide")
        for message in panel.messages {
            for block in message.blocks {
                if case .text(let value) = block {
                    #expect(!value.contains("<task-notification>"))
                }
            }
        }
        // …but the shell status was still reconciled from it.
        guard case .completed = panel.backgroundShells.first?.status else {
            Issue.record("expected status still reconciled to .completed")
            return
        }
    }

    // MARK: - live events, no `run_in_background` flag
    //
    // Every fixture above sets `run_in_background: true` on the Bash input,
    // which is why they stayed green while the popover was broken in
    // practice: claude no longer sets that flag. It moves commands to the
    // background on its own and announces them with `task_started`
    // (task_type: local_bash, plus a human `description`), so the panel first
    // hears about a shell from the event, not from the tool_use. Captured
    // from a real session:
    //
    //   {"subtype":"task_started","task_id":"b6s60dihx",
    //    "tool_use_id":"toolu_01KHH…","description":"Fast-forward de dev…",
    //    "task_type":"local_bash"}
    //   {"subtype":"task_notification","task_id":"b6s60dihx",
    //    "tool_use_id":"toolu_01KHH…","status":"completed"}

    private func plainBashToolUse(id: String, command: String) -> ChatMessageBlock {
        // No `run_in_background` — exactly what claude sends today.
        let input = try! JSONSerialization.data(withJSONObject: ["command": command])
        return .toolUse(.init(
            id: id,
            name: "Bash",
            inputJSON: String(data: input, encoding: .utf8) ?? "{}"
        ))
    }

    private func panelWithPlainBash(toolUseId: String, command: String) -> ClaudeChatPanel {
        let panel = ClaudeChatPanel(workspaceId: UUID(), workingDirectory: "/tmp")
        panel.applyResumedTranscript(sessionId: "sess-live", messages: [
            ChatMessage(role: .assistant, blocks: [
                plainBashToolUse(id: toolUseId, command: command)
            ])
        ])
        // Nothing to detect from the tool_use alone: no flag, no row.
        #expect(panel.backgroundShells.isEmpty)
        return panel
    }

    @Test func liveShellTakesItsNameFromTheOriginatingCommand() {
        let panel = panelWithPlainBash(toolUseId: "toolu_live1", command: "git push origin dev")
        panel.applyBackgroundTaskEvent(
            phase: .started,
            taskId: "b6s60dihx",
            toolUseId: "toolu_live1",
            taskType: "local_bash",
            status: "running",
            exitCode: nil,
            description: "Fast-forward de dev, tag 5.32.1 y push"
        )
        #expect(panel.backgroundShells.count == 1)
        #expect(panel.backgroundShells.first?.commandPreview == "git push origin dev")
    }

    @Test func liveShellFallsBackToTheHarnessDescription() {
        // Shell launched in a previous session: the tool_use is not in this
        // transcript, but the event still names it.
        let panel = ClaudeChatPanel(workspaceId: UUID(), workingDirectory: "/tmp")
        panel.applyBackgroundTaskEvent(
            phase: .started,
            taskId: "bho802ib3",
            toolUseId: "toolu_absent",
            taskType: "local_bash",
            status: "running",
            exitCode: nil,
            description: "Crear meta 5.32.1, asignar issues y cerrarla"
        )
        #expect(panel.backgroundShells.first?.commandPreview == "Crear meta 5.32.1, asignar issues y cerrarla")
    }

    @Test func liveShellFallsBackToTaskIdWhenNothingNamesIt() {
        let panel = ClaudeChatPanel(workspaceId: UUID(), workingDirectory: "/tmp")
        panel.applyBackgroundTaskEvent(
            phase: .started,
            taskId: "bnameless",
            toolUseId: nil,
            taskType: "local_bash",
            status: "running",
            exitCode: nil,
            description: nil
        )
        #expect(
            panel.backgroundShells.first?.commandPreview
                == ClaudeChatPanel.anonymousShellPreview(taskId: "bnameless")
        )
    }

    @Test func liveNotificationMarksTheShellCompleted() {
        let panel = panelWithPlainBash(toolUseId: "toolu_live2", command: "sleep 1")
        panel.applyBackgroundTaskEvent(
            phase: .started, taskId: "bdone", toolUseId: "toolu_live2",
            taskType: "local_bash", status: "running", exitCode: nil,
            description: "Esperar un segundo"
        )
        panel.applyBackgroundTaskEvent(
            phase: .notification, taskId: "bdone", toolUseId: "toolu_live2",
            taskType: nil, status: "completed", exitCode: "0", description: nil
        )
        guard case .completed = panel.backgroundShells.first?.status else {
            Issue.record("expected .completed, got \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }

    @Test func bashToolResultDoesNotResurrectACompletedShell() {
        // Live order on the wire: task_started, task_notification(completed),
        // *then* the Bash tool_result — which only reports the launch and
        // must not drag the row back to .running.
        let panel = panelWithPlainBash(toolUseId: "toolu_live3", command: "make build")
        panel.applyBackgroundTaskEvent(
            phase: .started, taskId: "blate", toolUseId: "toolu_live3",
            taskType: "local_bash", status: "running", exitCode: nil,
            description: "Compilar"
        )
        panel.applyBackgroundTaskEvent(
            phase: .notification, taskId: "blate", toolUseId: "toolu_live3",
            taskType: nil, status: "completed", exitCode: "0", description: nil
        )
        panel.noteBackgroundShellResult(.init(
            toolUseId: "toolu_live3",
            content: "Command running in background with ID: blate",
            isError: false
        ))
        guard case .completed = panel.backgroundShells.first?.status else {
            Issue.record("tool_result resurrected a finished shell as \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }

    @Test func notificationAloneStillRegistersAFinishedShell() {
        // If the started event is missed, the notification must not be
        // dropped — otherwise an exited shell never appears at all.
        let panel = ClaudeChatPanel(workspaceId: UUID(), workingDirectory: "/tmp")
        panel.applyBackgroundTaskEvent(
            phase: .notification, taskId: "borphan", toolUseId: "toolu_orphan",
            taskType: nil, status: "completed", exitCode: "0",
            description: nil
        )
        #expect(panel.backgroundShells.count == 1)
        guard case .completed = panel.backgroundShells.first?.status else {
            Issue.record("expected .completed, got \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }

    @Test func resumeLeavesShellWithoutNotificationRunning() {
        // A shell whose notification never arrived must stay live, not be
        // spuriously marked terminal.
        let panel = ClaudeChatPanel(workspaceId: UUID(), workingDirectory: "/tmp")
        let toolUseId = "toolu_bg3"
        let messages: [ChatMessage] = [
            ChatMessage(role: .assistant, blocks: [
                bashToolUse(id: toolUseId, command: "cd /x && flutter run")
            ]),
            ChatMessage(role: .user, blocks: [
                .toolResult(.init(
                    toolUseId: toolUseId,
                    content: "Command running in background with ID: sh_live",
                    isError: false
                ))
            ])
        ]
        panel.applyResumedTranscript(sessionId: "sess2", messages: messages)
        #expect(panel.backgroundShells.count == 1)
        guard case .running = panel.backgroundShells.first?.status else {
            Issue.record("expected still .running, got \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }
}
