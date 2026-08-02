import SwiftUI

#if DEBUG
/// Test-only probe for the Claude chat transcript's virtualization contract:
/// the `LazyVStack` in `ClaudeChatPanelView.messageList` must realize
/// viewport-many rows, never the whole `visibleMessageWindow`, and a quiet
/// panel must stop re-evaluating row bodies. `ChatLazyLayoutScaleTests` mounts
/// a several-hundred-message panel and fails on realization or convergence
/// churn.
///
/// This is the chat-side pendant of `SidebarLazyContractProbe`. The sidebar
/// regressed into a main-thread livelock five times through five different
/// mechanisms (#5323, #5764, #5845, #6210, #6556); the chat panel reproduces
/// the same shape — a `GeometryReader` wrapping nested negotiating stacks that
/// probe a `ScrollView` + `LazyVStack` — and had no equivalent guard until a
/// user's installed build wedged for 3.5 hours at 8.6 GB.
///
/// Same pattern as `SidebarLazyContractProbe`; compiled out of Release.
struct ChatLazyContractProbe {
    /// A transcript row evaluated its body. The realization counter: with a
    /// healthy `LazyVStack` this stays proportional to the viewport, not to
    /// `visibleMessageWindow`.
    var chatRowBody: (() -> Void)?

    /// The `LazyVStack` content closure ran and projected the transcript into
    /// rows. Re-projecting the whole list once per layout pass is its own
    /// O(N)-per-pass defeat, independent of how many rows get realized.
    var chatRowsProjection: (() -> Void)?
}
#endif
