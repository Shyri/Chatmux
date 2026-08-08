import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: the scheduled `/auto-task` queue.
///
/// The queue file lives in the shared `com.cmuxterm.app` Application Support
/// folder, so every cmux on the machine — installed app, second install, tagged
/// DEV builds — reads and writes the same file, and several are routinely open
/// at once. The claim protocol is what stops three instances from launching the
/// same autonomous agent three times on the same repository, so it is what
/// these tests are mostly about.
@MainActor
@Suite struct AutoTaskStoreTests {
    private func withStore(_ body: (AutoTaskStore, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoTaskStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(AutoTaskStore(directory: dir), dir)
    }

    private func task(
        iid: Int = 4529,
        at date: Date = Date(timeIntervalSince1970: 1_800_000_000),
        state: ScheduledAutoTask.State = .pending
    ) -> ScheduledAutoTask {
        ScheduledAutoTask(
            issueIID: iid,
            issueTitle: "Fix the login crash",
            repositoryPath: "/tmp/project",
            scheduledAt: date,
            state: state
        )
    }

    // MARK: - persistence

    @Test func addedTaskSurvivesAReload() throws {
        try withStore { store, dir in
            store.add(task())
            #expect(store.tasks.count == 1)

            // A second store over the same directory is what another cmux
            // instance looks like.
            let other = AutoTaskStore(directory: dir)
            #expect(other.tasks.count == 1)
            #expect(other.tasks.first?.issueIID == 4529)
            #expect(other.tasks.first?.issueTitle == "Fix the login crash")
        }
    }

    @Test func datesRoundTripExactly() throws {
        try withStore { store, dir in
            let when = Date(timeIntervalSince1970: 1_800_003_600)
            store.add(task(at: when))
            let reloaded = AutoTaskStore(directory: dir).tasks.first
            // ISO8601 keeps whole seconds; the queue never needs finer.
            #expect(reloaded?.scheduledAt.timeIntervalSince1970 == when.timeIntervalSince1970)
        }
    }

    /// A corrupt queue must not wedge the panel shut.
    @Test func corruptFileYieldsAnEmptyQueueRatherThanFailing() throws {
        try withStore { _, dir in
            try "{ not json".write(
                to: dir.appendingPathComponent("auto-tasks.json"),
                atomically: true,
                encoding: .utf8
            )
            #expect(AutoTaskStore(directory: dir).tasks.isEmpty)
        }
    }

    /// A task written by a newer build must not take the rest of the queue with
    /// it when it decodes.
    @Test func unknownStateDegradesToFailedWithoutLosingTheQueue() throws {
        try withStore { _, dir in
            let json = """
            [{"id":"\(UUID().uuidString)","issueIID":1,"issueTitle":"A",
              "repositoryPath":"/tmp/p","scheduledAt":"2027-01-01T03:00:00Z","state":"teleported"},
             {"id":"\(UUID().uuidString)","issueIID":2,"issueTitle":"B",
              "repositoryPath":"/tmp/p","scheduledAt":"2027-01-01T04:00:00Z","state":"pending"}]
            """
            try json.write(
                to: dir.appendingPathComponent("auto-tasks.json"),
                atomically: true,
                encoding: .utf8
            )
            let store = AutoTaskStore(directory: dir)
            #expect(store.tasks.count == 2)
            #expect(store.tasks.first?.state == .failed)
            #expect(store.tasks.first?.failureReason?.contains("teleported") == true)
            #expect(store.tasks.last?.state == .pending)
        }
    }

    // MARK: - the claim protocol

    /// The whole point: two instances race to launch the same task and exactly
    /// one wins.
    @Test func onlyOneClaimWins() throws {
        try withStore { store, dir in
            let t = task()
            store.add(t)
            let other = AutoTaskStore(directory: dir)

            let first = store.claimForLaunch(id: t.id)
            let second = other.claimForLaunch(id: t.id)

            #expect(first != nil)
            #expect(second == nil, "a second instance must not also launch it")
            #expect(first?.claimedByPID == ProcessInfo.processInfo.processIdentifier)
        }
    }

    @Test func claimingRecordsLaunchedState() throws {
        try withStore { store, dir in
            let t = task()
            store.add(t)
            let when = Date(timeIntervalSince1970: 1_800_000_060)
            _ = store.claimForLaunch(id: t.id, now: when)

            let reloaded = AutoTaskStore(directory: dir).tasks.first
            #expect(reloaded?.state == .launched)
            #expect(reloaded?.launchedAt?.timeIntervalSince1970 == when.timeIntervalSince1970)
        }
    }

    @Test func cancelledTaskCannotBeClaimed() throws {
        try withStore { store, _ in
            let t = task()
            store.add(t)
            store.cancel(id: t.id)
            #expect(store.claimForLaunch(id: t.id) == nil)
            #expect(store.tasks.first?.state == .cancelled)
        }
    }

    /// A missed task is claimable — that is what the panel's "Run now" does.
    @Test func missedTaskCanStillBeClaimedOnDemand() throws {
        try withStore { store, _ in
            let t = task(state: .missed)
            store.add(t)
            #expect(store.claimForLaunch(id: t.id) != nil)
        }
    }

    /// Writes made through one store must not clobber a concurrent write made
    /// through another: every mutation re-reads under the lock first.
    @Test func concurrentInstancesDoNotClobberEachOther() throws {
        try withStore { store, dir in
            let other = AutoTaskStore(directory: dir)
            store.add(task(iid: 1))
            other.add(task(iid: 2))   // `other` last read before `store` wrote

            let final = AutoTaskStore(directory: dir)
            #expect(Set(final.tasks.map(\.issueIID)) == [1, 2])
        }
    }

    // MARK: - rescheduling and cancellation

    @Test func reschedulingClearsTheFailure() throws {
        try withStore { store, _ in
            let t = task()
            store.add(t)
            store.markFailed(id: t.id, reason: "no workspace open")
            #expect(store.tasks.first?.state == .failed)

            let later = Date(timeIntervalSince1970: 1_800_090_000)
            store.reschedule(id: t.id, to: later)
            #expect(store.tasks.first?.state == .pending)
            #expect(store.tasks.first?.failureReason == nil)
            #expect(store.tasks.first?.scheduledAt == later)
        }
    }

    @Test func cancellingASettledTaskIsANoOp() throws {
        try withStore { store, _ in
            let t = task()
            store.add(t)
            _ = store.claimForLaunch(id: t.id)
            store.cancel(id: t.id)
            #expect(store.tasks.first?.state == .launched, "a launched run cannot be un-launched")
        }
    }

    // MARK: - marking issues in the GitLab list
    //
    // Purely local: the badge reflects this machine's queue and nothing is ever
    // written to GitLab.

    @Test func outstandingIsKeyedByIssueForTheRightRepository() throws {
        try withStore { store, _ in
            store.add(task(iid: 1))
            store.add(ScheduledAutoTask(
                issueIID: 2, issueTitle: "other repo",
                repositoryPath: "/tmp/elsewhere",
                scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)
            ))
            let found = store.outstandingByIssue(repositoryPath: "/tmp/project")
            #expect(Set(found.keys) == [1])
        }
    }

    /// A launched or cancelled task is history. Marking the issue "scheduled"
    /// for one of those would be false.
    @Test func settledTasksDoNotMarkTheIssue() throws {
        try withStore { store, _ in
            let t = task(iid: 7)
            store.add(t)
            #expect(store.outstandingByIssue(repositoryPath: "/tmp/project").keys.contains(7))

            _ = store.claimForLaunch(id: t.id)
            #expect(store.outstandingByIssue(repositoryPath: "/tmp/project").isEmpty)
        }
    }

    /// A missed one still marks it — it is a schedule that never ran, and
    /// hiding it would be worse than showing it.
    @Test func missedTasksStillMarkTheIssue() throws {
        try withStore { store, _ in
            store.add(task(iid: 9, state: .missed))
            let found = store.outstandingByIssue(repositoryPath: "/tmp/project")
            #expect(found[9]?.state == .missed)
        }
    }

    @Test func theSoonestTaskWinsForOneIssue() throws {
        try withStore { store, _ in
            let early = Date(timeIntervalSince1970: 1_800_000_000)
            store.add(task(iid: 5, at: early.addingTimeInterval(7200)))
            store.add(task(iid: 5, at: early))
            #expect(store.outstandingByIssue(repositoryPath: "/tmp/project")[5]?.scheduledAt == early)
        }
    }

    /// The workspace may report a path through a symlink while the task was
    /// scheduled from the resolved one, or vice versa.
    @Test func repositoryPathsAreComparedResolved() throws {
        try withStore { store, _ in
            store.add(ScheduledAutoTask(
                issueIID: 3, issueTitle: "t",
                repositoryPath: "/tmp/project/",
                scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)
            ))
            #expect(store.outstandingByIssue(repositoryPath: "/tmp/project").keys.contains(3),
                    "a trailing slash must not hide the badge")
        }
    }

    // MARK: - overdue policy

    @Test func markOverdueMovesOnlyPastPendingTasks() throws {
        try withStore { store, _ in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            store.add(task(iid: 1, at: now.addingTimeInterval(-3600)))
            store.add(task(iid: 2, at: now.addingTimeInterval(3600)))

            let moved = store.markOverdueAsMissed(now: now)
            #expect(moved.map(\.issueIID) == [1])
            #expect(store.tasks.first(where: { $0.issueIID == 2 })?.state == .pending)
        }
    }

    @Test func nextPendingIsTheSoonestFutureTask() throws {
        try withStore { store, _ in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            store.add(task(iid: 1, at: now.addingTimeInterval(7200)))
            store.add(task(iid: 2, at: now.addingTimeInterval(600)))
            store.add(task(iid: 3, at: now.addingTimeInterval(-600)))  // past: not next
            #expect(store.nextPending(after: now)?.issueIID == 2)
        }
    }
}

/// The scheduler's firing policy, kept pure so it can be tested without a
/// clock, a run loop, or a filesystem.
@Suite struct AutoTaskSchedulerPolicyTests {
    private func task(
        iid: Int,
        at date: Date,
        state: ScheduledAutoTask.State = .pending
    ) -> ScheduledAutoTask {
        ScheduledAutoTask(
            issueIID: iid,
            issueTitle: "t\(iid)",
            repositoryPath: "/tmp/p",
            scheduledAt: date,
            state: state
        )
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aTaskDueNowFires() {
        let due = AutoTaskScheduler.dueTasks(
            [task(iid: 1, at: now)], now: now, grace: AutoTaskScheduler.lateGrace
        )
        #expect(due.map(\.issueIID) == [1])
    }

    @Test func aFutureTaskDoesNotFire() {
        let due = AutoTaskScheduler.dueTasks(
            [task(iid: 1, at: now.addingTimeInterval(60))], now: now, grace: AutoTaskScheduler.lateGrace
        )
        #expect(due.isEmpty)
    }

    /// A lid closed over lunch should still run the task. This is the grace
    /// window, and it is the reason the policy is not a bare `scheduledAt <= now`.
    @Test func aSlightlyLateTaskStillFires() {
        let due = AutoTaskScheduler.dueTasks(
            [task(iid: 1, at: now.addingTimeInterval(-10 * 60))],
            now: now,
            grace: AutoTaskScheduler.lateGrace
        )
        #expect(due.map(\.issueIID) == [1])
    }

    /// The important one. An autonomous agent must not start on a repository
    /// hours after its window with nobody watching — it becomes `.missed` and
    /// waits for a human.
    @Test func aTaskPastItsWindowDoesNotFireOnItsOwn() {
        let overnight = now.addingTimeInterval(-8 * 3600)
        let due = AutoTaskScheduler.dueTasks(
            [task(iid: 1, at: overnight)], now: now, grace: AutoTaskScheduler.lateGrace
        )
        #expect(due.isEmpty, "an 8-hour-late autonomous run must not fire unattended")
        #expect(task(iid: 1, at: overnight).isOverdue(now: now), "…but it is overdue, so it becomes .missed")
    }

    @Test func nonPendingStatesNeverFire() {
        let states: [ScheduledAutoTask.State] = [.missed, .launched, .cancelled, .failed]
        for state in states {
            let due = AutoTaskScheduler.dueTasks(
                [task(iid: 1, at: now, state: state)], now: now, grace: AutoTaskScheduler.lateGrace
            )
            #expect(due.isEmpty, "state \(state.rawValue) must not fire")
        }
    }

    @Test func dueTasksComeOutOldestFirst() {
        let due = AutoTaskScheduler.dueTasks(
            [
                task(iid: 1, at: now.addingTimeInterval(-60)),
                task(iid: 2, at: now.addingTimeInterval(-600)),
                task(iid: 3, at: now.addingTimeInterval(-300)),
            ],
            now: now,
            grace: AutoTaskScheduler.lateGrace
        )
        #expect(due.map(\.issueIID) == [2, 3, 1])
    }
}
