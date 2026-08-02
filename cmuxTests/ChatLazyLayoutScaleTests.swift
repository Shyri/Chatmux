import Testing
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral gate for the Claude chat transcript's lazy-layout contract:
/// layout work must stay O(visible rows) no matter how long the conversation
/// is, and a quiet panel must converge (no self-sustaining invalidation).
///
/// This mirrors `SidebarLazyLayoutScaleTests`. The sidebar contract regressed
/// five times through five different mechanisms (#5323 per-row anchorPreference,
/// #5764 per-row String ids, #5845 animated height interpolation, #6210 a
/// force-measuring custom Layout, #6556 GeometryReader → @State feedback), and
/// each shipped to stable before detection. The chat panel carries the same
/// shape — `chatContent`'s `GeometryReader` wrapping three nested negotiating
/// stacks that probe `messageList`'s `ScrollView`, which answers by measuring
/// the whole `LazyVStack` — and had no guard at all until a user's installed
/// build wedged the main thread for 3.5 hours at 8.6 GB of footprint.
///
/// `scripts/check-chat-lazy-layout.py` bans the known source shapes; this is
/// the mechanism-independent backstop.
@Suite(.serialized)
final class ChatLazyLayoutScaleTests {
    static let messageCount = 300

    /// Generous ceiling for "how many rows may be realized for one viewport".
    /// A 640pt window shows roughly 8-12 transcript rows; LazyVStack prefetch
    /// plus a second layout pass can multiply that, but a virtualization
    /// defeat realizes all `messageCount` rows on *every* pass, so the failing
    /// counts are in the thousands — nowhere near this bound.
    private static let realizedRowCeiling = 150

    /// Plain class (not `@MainActor`) so the probe's nonisolated `() -> Void`
    /// closures can mutate it; bodies only run on the main thread. Same shape
    /// as `RowBodyCounter` in `SidebarLazyLayoutScaleTests`.
    final class RowBodyCounter {
        var rowBodies = 0
        var rowsProjections = 0

        func reset() {
            rowBodies = 0
            rowsProjections = 0
        }
    }

    @MainActor
    struct Harness {
        let panel: ClaudeChatPanel
        let counter: RowBodyCounter
        let window: NSWindow

        func tearDown() {
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    static func mountChat(messageCount: Int) async throws -> Harness {
        _ = NSApplication.shared

        // Multi-line bodies so rows have realistic heights: a transcript of
        // one-word rows would fit far more rows per viewport than any real
        // conversation and would soften the realization signal.
        let messages: [ChatMessage] = (0..<messageCount).map { index in
            let role: ChatMessageRole = index.isMultiple(of: 2) ? .user : .assistant
            return ChatMessage.text(
                role,
                """
                Transcript row \(index) for the lazy-layout scale gate.
                It carries a second line so the row height is representative
                of a real chat turn rather than a single glyph.
                """
            )
        }

        let panel = ClaudeChatPanel(
            workspaceId: UUID(),
            workingDirectory: NSTemporaryDirectory(),
            initialMessages: messages
        )
        // `init` caps the render window at `defaultVisibleMessageWindow` (60).
        // Reveal everything — the same thing the "show all" affordance does —
        // so the `LazyVStack` really holds `messageCount` rows and a
        // virtualization defeat shows up as a realization count instead of
        // being hidden behind the cap.
        panel.revealAllMessages()

        let counter = RowBodyCounter()

        let root = ClaudeChatPanelView(
            panel: panel,
            isFocused: true,
            isVisibleInUI: true,
            portalPriority: 0,
            hasUnreadNotification: false,
            onRequestPanelFocus: {}
        )
        .environment(
            \.chatLazyContractProbe,
            ChatLazyContractProbe(
                chatRowBody: { counter.rowBodies += 1 },
                chatRowsProjection: { counter.rowsProjections += 1 }
            )
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // ARC owns this window; without this, `close()` performs AppKit's own
        // release on top of ARC's and the double-release SEGVs the test host.
        // Same hazard as #5641 in the sidebar suite.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)

        return Harness(panel: panel, counter: counter, window: window)
    }

    /// One synchronous run-loop turn. Kept out of the async context so the
    /// `RunLoop.run(_:before:)` call is legal under Swift 6, and wrapped in its
    /// own autorelease pool so drained main-queue work cannot pile objects into
    /// the enclosing job's pool.
    @MainActor
    static func turnMainRunLoopOnce(layingOut window: NSWindow?) {
        autoreleasepool {
            window?.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
    }

    @MainActor
    static func drainMainRunLoop(for window: NSWindow, iterations: Int = 25) async {
        for _ in 0..<iterations {
            Self.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
        }
    }

    /// Mounting a 300-message transcript must realize only the rows one
    /// viewport needs. Realizing all of them is the defeat: every subsequent
    /// layout pass then pays O(N), and with three nested stacks probing the
    /// ScrollView with varying proposals the cost multiplies until the main
    /// thread livelocks.
    @Test
    @MainActor
    func testMountRealizesOnlyViewportRowsAt300Messages() async throws {
        let harness = try await Self.mountChat(messageCount: Self.messageCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)

        let realized = harness.counter.rowBodies
        print("[scale] mount: realized=\(realized) of \(Self.messageCount) rows")
        #expect(realized > 0, "Chat panel mounted but no transcript row body ran; harness is broken.")
        #expect(
            realized < Self.realizedRowCeiling,
            """
            \(realized) transcript row bodies evaluated for a single ~10-row viewport with \
            \(Self.messageCount) messages. The LazyVStack is being defeated (the whole \
            transcript measured per pass). Look for a GeometryReader wrapping the scroll \
            subtree, nested flexible stacks probing the ScrollView for an intrinsic size, or \
            per-row geometry feedback; see scripts/check-chat-lazy-layout.py.
            """
        )
    }

    /// With no state changes at all, the panel must go quiet. Continued row
    /// re-evaluation on an idle transcript is the #6556 signature: a layout ⇄
    /// state feedback loop that livelocks the main thread at scale.
    @Test
    @MainActor
    func testQuietTranscriptStopsReevaluatingRows() async throws {
        let harness = try await Self.mountChat(messageCount: Self.messageCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        harness.counter.reset()

        await Self.drainMainRunLoop(for: harness.window, iterations: 30)

        let quietEvals = harness.counter.rowBodies
        print("[scale] quiet: rowBodies=\(quietEvals) projections=\(harness.counter.rowsProjections)")
        #expect(
            quietEvals < 20,
            """
            \(quietEvals) transcript row bodies evaluated with no state changes at all. The \
            chat panel is re-invalidating itself — a layout/state feedback loop. This is what \
            livelocks the main thread once the transcript is long enough.
            """
        )

        let quietProjections = harness.counter.rowsProjections
        #expect(
            quietProjections < 20,
            """
            The LazyVStack content closure re-projected the transcript \(quietProjections) \
            times with nothing changing. Row projection must happen when the transcript \
            changes, not once per layout pass.
            """
        )
    }

    /// Resizing the panel must stay row-scoped.
    ///
    /// A static mount converges fine — that is measured above and it passes —
    /// so the defeat this suite exists for is dynamic: every resize hands the
    /// nested stacks a fresh proposal, every fresh proposal misses
    /// `ViewSizeCache`, and a miss re-measures the transcript. This is the
    /// stimulus the profile of the real 3.5-hour hang pointed at.
    @Test
    @MainActor
    func testResizeStormStaysRowScoped() async throws {
        let harness = try await Self.mountChat(messageCount: Self.messageCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        harness.counter.reset()

        let resizes = 20
        for i in 0..<resizes {
            harness.window.setContentSize(
                NSSize(width: i.isMultiple(of: 2) ? 700 : 1200, height: 640)
            )
            await Self.drainMainRunLoop(for: harness.window, iterations: 3)
        }
        await Self.drainMainRunLoop(for: harness.window)

        let evals = harness.counter.rowBodies
        print("[scale] resize: rowBodies=\(evals) over \(resizes) resizes (ceiling \(resizes * 50))")
        #expect(
            evals < resizes * 50,
            """
            \(evals) transcript row bodies evaluated across \(resizes) resizes with \
            \(Self.messageCount) messages. A resize must re-evaluate the visible rows, not \
            the whole transcript: at this scale that is the multiplicative probing that \
            livelocks the main thread.
            """
        )
    }

    /// Opening and closing the diff pane must stay row-scoped.
    ///
    /// The diff pane is what introduces the second `HStack` branch, the
    /// `.frame(width:)` derived from the container's width, and an 0.18s
    /// animation over the chat column — i.e. a continuous stream of new
    /// proposals aimed straight at the transcript.
    @Test
    @MainActor
    func testDiffPaneToggleStaysRowScoped() async throws {
        let harness = try await Self.mountChat(messageCount: Self.messageCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        harness.counter.reset()

        let toggles = 12
        for i in 0..<toggles {
            harness.panel.diffPaneOpen = !i.isMultiple(of: 2)
            await Self.drainMainRunLoop(for: harness.window, iterations: 4)
        }
        await Self.drainMainRunLoop(for: harness.window)

        let evals = harness.counter.rowBodies
        print("[scale] diffToggle: rowBodies=\(evals) over \(toggles) toggles (ceiling \(toggles * 50))")
        #expect(
            evals < toggles * 50,
            """
            \(evals) transcript row bodies evaluated across \(toggles) diff-pane toggles. \
            Resizing the chat column must not re-measure the whole transcript.
            """
        )
    }

    /// Appending to the transcript — what streaming does, several times a
    /// second — must cost the appended row, not the list. Both chats that were
    /// live when the real hang started were mid-stream.
    @Test
    @MainActor
    func testAppendStormStaysRowScoped() async throws {
        let harness = try await Self.mountChat(messageCount: Self.messageCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        harness.counter.reset()

        let appends = 30
        for i in 0..<appends {
            harness.panel.appendSystemNotice("streamed chunk \(i)")
            await Self.drainMainRunLoop(for: harness.window, iterations: 2)
        }
        await Self.drainMainRunLoop(for: harness.window)

        let evals = harness.counter.rowBodies
        print("[scale] append: rowBodies=\(evals) over \(appends) appends (ceiling \(appends * 30))")
        #expect(
            evals < appends * 30,
            """
            \(evals) transcript row bodies evaluated for \(appends) appended messages. \
            Appending must invalidate the new row (TextBlockRow.== + .equatable()), not \
            re-realize the transcript on every chunk.
            """
        )
    }

    /// Harness self-test: prove the drain loop and the body counter actually
    /// detect a layout feedback loop. This fixture reproduces the historical
    /// GeometryReader → @State shape (#6556); if the harness cannot flag THIS,
    /// the tests above are vacuous.
    @Test
    @MainActor
    func testHarnessDetectsGeometryFeedbackLoopCanary() async throws {
        _ = NSApplication.shared

        let counter = RowBodyCounter()
        let rows = 8
        let root = VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { _ in
                DivergentChatGeometryFeedbackRowFixture(onBody: { counter.rowBodies += 1 })
            }
        }
        .frame(width: 200)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = NSHostingView(rootView: root)

        await Self.drainMainRunLoop(for: window, iterations: 40)

        #expect(
            counter.rowBodies > rows * 3,
            """
            The divergent GeometryReader → @State fixture only produced \
            \(counter.rowBodies) body evaluations for \(rows) rows; the harness can no longer \
            observe layout feedback loops, so the lazy-contract tests above are not protecting \
            anything. Fix the harness before trusting them.
            """
        )
    }
}

/// Reproduces the #6556 anti-pattern in deliberately divergent form: a
/// GeometryReader writes measured height back into `@State` that feeds the
/// row's own frame, so every layout pass invalidates the next. Test fixture
/// only — this shape is banned in real chat rows by
/// `scripts/check-chat-lazy-layout.py`.
private struct DivergentChatGeometryFeedbackRowFixture: View {
    let onBody: () -> Void
    @State private var rowHeight: CGFloat = 20
    /// The divergence is capped. Left unbounded, the row grows on every pass
    /// until AppKit's own layout-loop guard raises an ObjC exception inside
    /// `_NSViewLayout`, and `+[NSApplication _crashOnException:]` turns that
    /// into a SIGTRAP that kills the test host mid-run — observed as
    /// "Restarting after unexpected exit, crash, or test timeout". A crashing
    /// canary proves nothing, so it feeds back just long enough to be counted
    /// and then goes quiet.
    @State private var feedbackIterations = 0
    private static let maxFeedbackIterations = 60

    var body: some View {
        let _ = { onBody() }()
        Color.gray
            .frame(height: rowHeight)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { bumpHeight(from: proxy.size.height) }
                        .onChange(of: proxy.size.height) { _, newHeight in
                            bumpHeight(from: newHeight)
                        }
                }
            }
    }

    private func bumpHeight(from measured: CGFloat) {
        guard feedbackIterations < Self.maxFeedbackIterations else { return }
        feedbackIterations += 1
        rowHeight = measured + 1
    }
}
