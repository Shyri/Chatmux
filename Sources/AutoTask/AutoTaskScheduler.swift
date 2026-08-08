import AppKit
import Combine
import Foundation

/// Fires scheduled `/auto-task` runs while cmux is open.
///
/// Deliberately *not* a polling loop: one timer, armed at the soonest pending
/// task, re-armed whenever the queue changes or the machine wakes.
///
/// **A timer does not fire while the Mac is asleep, and can be late by hours.**
/// So the wall clock is re-checked on wake and at launch rather than trusted.
/// Anything already overdue becomes `.missed` and is *not* run: starting an
/// autonomous agent on a repository hours after its window, with nobody
/// watching, is worse than not starting it. The panel surfaces missed tasks and
/// the user decides.
@MainActor
final class AutoTaskScheduler {
    static let shared = AutoTaskScheduler()

    /// Set by the app at startup. Left nil in tests, where `dueTasks` and the
    /// missed-task policy are exercised without launching anything.
    var launch: ((ScheduledAutoTask) -> Void)?

    private let store: AutoTaskStore
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    init(store: AutoTaskStore = .shared) {
        self.store = store
    }

    /// Call once, after the app has finished launching.
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        )
        // Coming back to the app is also a good moment to notice writes made by
        // another cmux instance sharing the queue file.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        )
        // `objectWillChange` rather than `$tasks`: it is part of
        // `ObservableObject` and carries no access-level surprises from the
        // store's `private(set)`.
        store.objectWillChange
            .sink { [weak self] _ in
                // Re-arm on the next turn: this fires from inside the store's
                // own write, and re-entering it here would deadlock on the
                // file lock.
                Task { @MainActor in self?.armTimer() }
            }
            .store(in: &cancellables)

        reconcile()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        cancellables.removeAll()
    }

    /// Re-read the queue, fire anything due right now, retire what is too late,
    /// and re-arm.
    func reconcile(now: Date = Date()) {
        store.reload()

        // Fire tasks due within the grace window — the timer can land a moment
        // early, and a task due "now" should not have to wait for another pass.
        let due = Self.dueTasks(store.tasks, now: now, grace: Self.lateGrace)
        for task in due {
            fire(task, now: now)
        }

        // Anything still pending and past its window while we were away.
        store.markOverdueAsMissed(now: now)
        armTimer(now: now)
    }

    /// How late a task may be and still fire automatically. Beyond this the run
    /// is considered to have missed its window.
    ///
    /// Fifteen minutes covers a laptop lid closed over lunch or a timer that
    /// slipped; it does not cover overnight.
    nonisolated static let lateGrace: TimeInterval = 15 * 60

    /// Pending tasks that should fire at `now`. Pure and `nonisolated`, so the
    /// policy is testable without a clock, a run loop, or a filesystem.
    /// Written as an explicit loop rather than a chain of `filter`/`sorted`
    /// closures: the chained form made the type checker time out (`unable to
    /// type-check this expression in reasonable time`), which is a recurring
    /// hazard in this codebase.
    nonisolated static func dueTasks(
        _ tasks: [ScheduledAutoTask],
        now: Date,
        grace: TimeInterval
    ) -> [ScheduledAutoTask] {
        var due: [ScheduledAutoTask] = []
        for task in tasks {
            guard task.state == .pending else { continue }
            guard task.scheduledAt <= now else { continue }
            let lateness: TimeInterval = now.timeIntervalSince(task.scheduledAt)
            guard lateness <= grace else { continue }
            due.append(task)
        }
        due.sort { (lhs: ScheduledAutoTask, rhs: ScheduledAutoTask) -> Bool in
            lhs.scheduledAt < rhs.scheduledAt
        }
        return due
    }

    private func fire(_ task: ScheduledAutoTask, now: Date) {
        // The claim is the race guard: several cmux instances share this queue.
        guard let claimed = store.claimForLaunch(id: task.id, now: now) else { return }
        guard let launch else {
            store.markFailed(id: claimed.id, reason: "No launcher wired.")
            return
        }
        launch(claimed)
    }

    private func armTimer(now: Date = Date()) {
        timer?.invalidate()
        timer = nil
        guard let next = store.nextPending(after: now) else { return }

        // Cap the interval: `Timer` loses accuracy over very long waits, and a
        // capped wake-up simply re-arms. Also means a queue scheduled a week out
        // still re-checks the clock daily.
        let interval = min(max(next.scheduledAt.timeIntervalSince(now), 1), Self.maxTimerInterval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        // `.common` so the timer still fires while a menu is open or a window
        // is being resized — both put the run loop in a tracking mode that
        // would otherwise hold it back.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static let maxTimerInterval: TimeInterval = 60 * 60
}
