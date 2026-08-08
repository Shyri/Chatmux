import Foundation

/// One `/auto-task` run: either scheduled for later or already launched.
///
/// The states are deliberately limited to what cmux can *observe*. cmux opens a
/// chat and sends the command; from that point the run belongs to the agent and
/// to `/auto-task`'s own flow (verify, MR, review). Nothing reports back, so a
/// `.completed` state would be a guess dressed up as a fact. `.launched` is the
/// last thing this app actually knows.
struct ScheduledAutoTask: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        /// Waiting for its time.
        case pending
        /// Its time passed while cmux was not running. Never launched
        /// automatically — see `AutoTaskScheduler`.
        case missed
        /// The chat was opened and `/auto-task <iid>` was sent. Whether the run
        /// succeeded is not something cmux can see.
        case launched
        /// The user cancelled it before it ran.
        case cancelled
        /// cmux could not launch it: no workspace open on that repository, or
        /// `/auto-task` not installed there.
        case failed
    }

    let id: UUID
    let issueIID: Int
    /// Snapshotted so the list renders without going back to GitLab — and still
    /// reads correctly if the issue is later renamed or closed.
    let issueTitle: String
    /// The run belongs to a repository, not to whichever workspace happens to
    /// be selected when the timer fires.
    let repositoryPath: String
    var scheduledAt: Date
    var state: State
    var launchedAt: Date?
    /// The chat this run opened, so the row can jump back to it.
    ///
    /// Panel + workspace rather than claude's session id: the session id does
    /// not exist yet at the moment the chat is created — the runner assigns it
    /// when the CLI first answers — so capturing it here would always be nil.
    /// These two are known immediately.
    var chatPanelId: UUID?
    var chatWorkspaceId: UUID?
    /// Why `.failed`. Shown verbatim in the row.
    var failureReason: String?
    /// PID of the cmux instance that claimed the launch. Several instances
    /// share one queue file on this machine (`com.cmuxterm.app` in Application
    /// Support), so a claim has to be recorded, not assumed.
    var claimedByPID: Int32?

    init(
        id: UUID = UUID(),
        issueIID: Int,
        issueTitle: String,
        repositoryPath: String,
        scheduledAt: Date,
        state: State = .pending,
        launchedAt: Date? = nil,
        chatPanelId: UUID? = nil,
        chatWorkspaceId: UUID? = nil,
        failureReason: String? = nil,
        claimedByPID: Int32? = nil
    ) {
        self.id = id
        self.issueIID = issueIID
        self.issueTitle = issueTitle
        self.repositoryPath = repositoryPath
        self.scheduledAt = scheduledAt
        self.state = state
        self.launchedAt = launchedAt
        self.chatPanelId = chatPanelId
        self.chatWorkspaceId = chatWorkspaceId
        self.failureReason = failureReason
        self.claimedByPID = claimedByPID
    }

    /// Whether the queue still owes this task a launch.
    var isWaiting: Bool {
        switch state {
        case .pending: return true
        case .missed, .launched, .cancelled, .failed: return false
        }
    }

    /// Whether it is finished as far as cmux is concerned, and belongs in the
    /// history section rather than the active one.
    var isSettled: Bool {
        switch state {
        case .launched, .cancelled, .failed: return true
        case .pending, .missed: return false
        }
    }

    /// A pending task whose time has passed. `now` is injected so the policy is
    /// testable without waiting for a clock.
    func isOverdue(now: Date) -> Bool {
        state == .pending && scheduledAt <= now
    }
}

extension ScheduledAutoTask {
    /// Decoding tolerates unknown states rather than throwing away the whole
    /// queue file: a task written by a newer build lands as `.failed` with a
    /// readable reason instead of taking every other row down with it.
    enum CodingKeys: String, CodingKey {
        case id, issueIID, issueTitle, repositoryPath, scheduledAt
        case state, launchedAt, chatPanelId, chatWorkspaceId, failureReason, claimedByPID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        issueIID = try c.decode(Int.self, forKey: .issueIID)
        issueTitle = try c.decodeIfPresent(String.self, forKey: .issueTitle) ?? ""
        repositoryPath = try c.decode(String.self, forKey: .repositoryPath)
        scheduledAt = try c.decode(Date.self, forKey: .scheduledAt)
        launchedAt = try c.decodeIfPresent(Date.self, forKey: .launchedAt)
        chatPanelId = try c.decodeIfPresent(UUID.self, forKey: .chatPanelId)
        chatWorkspaceId = try c.decodeIfPresent(UUID.self, forKey: .chatWorkspaceId)
        claimedByPID = try c.decodeIfPresent(Int32.self, forKey: .claimedByPID)

        let rawState = try c.decodeIfPresent(String.self, forKey: .state) ?? State.pending.rawValue
        if let known = State(rawValue: rawState) {
            state = known
            failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        } else {
            state = .failed
            failureReason = "Unknown state '\(rawState)' — written by a newer version of cmux."
        }
    }
}
