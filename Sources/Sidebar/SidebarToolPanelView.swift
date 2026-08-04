import SwiftUI

/// Which tool the workspace sidebar's bottom section is showing.
///
/// Files and Find are the same underlying view (`FileExplorerPanelView`) with a
/// different `presentation`, so this is only a selection, not two hierarchies.
enum SidebarBottomTool: String, CaseIterable, Codable, Sendable {
    case files
    case find

    var label: String {
        switch self {
        case .files:
            return String(localized: "sidebar.tool.files", defaultValue: "Files")
        case .find:
            return String(localized: "sidebar.tool.find", defaultValue: "Find")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        }
    }

    var presentation: FileExplorerPanelPresentation {
        switch self {
        case .files: return .files
        case .find: return .find
        }
    }
}

/// The bottom section of the workspace sidebar: a small Files/Find switcher
/// over the file-explorer panel.
///
/// Deliberately measurement-free. This view sits directly below the workspace
/// `LazyVStack`, and the sidebar's lazy-layout contract has regressed into a
/// main-thread livelock five times (#5323, #5764, #5845, #6210, #6556) — every
/// time through something that measured the list. The split gives this panel an
/// explicit height and lets the workspace list take the remainder, so nothing
/// here ever asks the list how big it is. See
/// `scripts/check-sidebar-lazy-layout.py`.
struct SidebarToolPanelView: View {
    @ObservedObject var store: FileExplorerStore
    @ObservedObject var state: FileExplorerState
    let onOpenFilePreview: (String) -> Void
    @Binding var tool: SidebarBottomTool

    var body: some View {
        VStack(spacing: 0) {
            switcher
            Divider()
            FileExplorerPanelView(
                store: store,
                state: state,
                onOpenFilePreview: onOpenFilePreview,
                presentation: tool.presentation,
                placement: .leftSidebar
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var switcher: some View {
        HStack(spacing: 4) {
            ForEach(SidebarBottomTool.allCases, id: \.self) { candidate in
                switcherButton(for: candidate)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func switcherButton(for candidate: SidebarBottomTool) -> some View {
        let isSelected = candidate == tool
        return Button {
            guard candidate != tool else { return }
            tool = candidate
        } label: {
            HStack(spacing: 4) {
                Image(systemName: candidate.symbolName)
                    .font(.system(size: 10, weight: .medium))
                Text(candidate.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        // `.plain` keeps this out of AppKit's button machinery. Every SwiftUI
        // Button that bridges to NSButton allocates an NSAppearance pair per
        // size query, and this switcher sits next to a list that is measured
        // often.
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Draggable separator between the workspace list and the tool section.
///
/// Reports raw translation and owns no height itself; the sidebar clamps and
/// persists. Same split of responsibilities as the sidebar's width resizer
/// (`resizerConfig(for:availableWidth:)`), which captures a start value, applies
/// the translation and writes inside a `Transaction(animation: nil)` so the drag
/// tracks the pointer instead of easing behind it.
struct SidebarToolPanelDivider: View {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack {
            Divider()
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
        }
        .frame(height: 8)
        .background(ResizeCursorRect())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { onDragChanged($0.translation.height) }
                .onEnded { _ in onDragEnded() }
        )
        .accessibilityLabel(String(
            localized: "sidebar.tool.resizeHandle",
            defaultValue: "Resize the Files and Find panel"
        ))
    }
}

/// Shows the up/down resize cursor over the divider.
///
/// A cursor rect rather than SwiftUI's `.onHover`: `.onHover` installs an
/// `NSTrackingArea` in the sidebar's hosting subtree, which CLAUDE.md flags as
/// the #8004 lifecycle hazard (AppKit running tracking callbacks while SwiftUI
/// renders the same hierarchy). Cursor rects are resolved by the window during
/// `resetCursorRects`, so there is no tracking area and no SwiftUI state — and
/// unlike a hover-driven `NSCursor.push()/pop()` pair, the cursor cannot get
/// stuck pushed if the pointer leaves during a drag.
private struct ResizeCursorRect: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorRectView { CursorRectView() }
    func updateNSView(_ nsView: CursorRectView, context: Context) {}

    final class CursorRectView: NSView {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }
}
