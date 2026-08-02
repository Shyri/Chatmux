import AppKit
import Bonsplit
import CmuxSidebar
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Chat palette

/// Palette for the Claude Chat panel. The base background and foreground
/// follow the user's Ghostty terminal config (`backgroundColor`,
/// `foregroundColor`) so the chat blends with their terminals; card and
/// code surfaces are derived by lightening/darkening the base. Accent
/// colors are kept on a fixed Darcula-inspired hue set so semantics
/// (success/error/warning) read consistently across themes.
struct ChatPalette {
    /// The terminal background — used as the chat panel canvas in dark
    /// mode and as the seed for derived layer backgrounds.
    let terminalBg: NSColor
    /// The terminal foreground — used for primary chat text in dark mode.
    let terminalFg: NSColor

    static let `default` = ChatPalette(
        terminalBg: NSColor(srgbRed: 0x2B/255.0, green: 0x2B/255.0, blue: 0x2B/255.0, alpha: 1.0),
        terminalFg: NSColor(srgbRed: 0xBB/255.0, green: 0xBB/255.0, blue: 0xBB/255.0, alpha: 1.0)
    )

    // MARK: Static accents (Darcula-inspired, fixed regardless of theme)
    static let pink   = Color(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x68/255.0)  // #FF6B68
    static let red    = Color(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x68/255.0)
    static let orange = Color(red: 0xCC/255.0, green: 0x78/255.0, blue: 0x32/255.0)  // #CC7832
    static let yellow = Color(red: 0xD6/255.0, green: 0xBF/255.0, blue: 0x55/255.0)  // #D6BF55
    static let green  = Color(red: 0xA8/255.0, green: 0xC0/255.0, blue: 0x23/255.0)  // #A8C023
    static let cyan   = Color(red: 0x6C/255.0, green: 0xDA/255.0, blue: 0xDA/255.0)  // #6CDADA
    static let purple = Color(red: 0xAE/255.0, green: 0x8A/255.0, blue: 0xBE/255.0)  // #AE8ABE
    static let blue   = Color(red: 0x53/255.0, green: 0x94/255.0, blue: 0xEC/255.0)  // #5394EC

    // MARK: Layer helpers (dark = derived from terminalBg/Fg, light = neutral)

    func panelBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: terminalBg) : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }
    func headerBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.04)) : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
    }
    func cardBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: +0.07)) : Color(nsColor: NSColor(white: 0.94, alpha: 1.0))
    }
    func cardSubtleBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.04)) : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
    }
    func codeBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.06)) : Color(nsColor: NSColor(white: 0.93, alpha: 1.0))
    }
    func resultBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.04)) : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
    }
    func inputBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.04)) : Color.white
    }
    func borderSubtle(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: +0.18)).opacity(0.7) : Color.secondary.opacity(0.18)
    }
    func fg(_ isDark: Bool) -> Color {
        // Slightly brighter than the terminal fg — chat messages are read
        // prose, not code, so a touch more contrast helps long-form
        // readability without diverging from the terminal palette.
        isDark ? Color(nsColor: shifted(terminalFg, by: 0.14)) : .primary
    }
    func accent(_ isDark: Bool) -> Color {
        isDark ? Self.purple : cmuxAccentColor()
    }

    /// Shift `color`'s perceived brightness by `delta` (negative = darker,
    /// positive = lighter). Operates in HSB so works for any base hue.
    private func shifted(_ color: NSColor, by delta: CGFloat) -> NSColor {
        let normalized = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        normalized.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newB = max(0, min(1, b + delta))
        return NSColor(hue: h, saturation: s, brightness: newB, alpha: a)
    }
}

// MARK: - Diff side pane

/// Right-hand pane showing every Edit/Write/MultiEdit/NotebookEdit
/// claude has emitted in the current (or just-finished) turn. Reuses
/// `EditDiffView` & friends so the visual is identical to the in-line
/// tool cards, just consolidated in one column.
private struct DiffPaneView: View {
    let edits: [ClaudeChatPanel.TurnEdit]
    let isDark: Bool
    let onClose: () -> Void

    @Environment(\.chatPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if edits.isEmpty {
                emptyState
            } else {
                scrollList
            }
        }
        .background(palette.headerBg(isDark))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(String(
                localized: "claudeChat.diffPane.title",
                defaultValue: "Last turn changes"
            ))
            .font(.system(size: 12, weight: .semibold))
            if !edits.isEmpty {
                Text("\(edits.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(palette.cardBg(isDark)))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.diffPane.close.tooltip",
                defaultValue: "Hide diff pane"
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text(String(
                localized: "claudeChat.diffPane.empty",
                defaultValue: "No edits yet in this turn."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var scrollList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(edits) { edit in
                    DiffPaneEditCard(edit: edit, isDark: isDark)
                }
            }
            .padding(12)
        }
    }
}

private struct DiffPaneEditCard: View {
    let edit: ClaudeChatPanel.TurnEdit
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    private var parsed: [String: Any]? {
        guard let data = edit.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private var headerSummary: String {
        switch edit.toolName {
        case "Edit", "Write", "NotebookEdit":
            if let path = parsed?["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        case "MultiEdit":
            if let path = parsed?["file_path"] as? String,
               let edits = parsed?["edits"] as? [[String: Any]] {
                return "\((path as NSString).lastPathComponent) · \(edits.count) edits"
            }
        default:
            break
        }
        return edit.toolName
    }

    private var iconName: String {
        switch edit.toolName {
        case "Write": return "doc.badge.plus"
        case "NotebookEdit": return "book"
        default: return "pencil"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(edit.toolName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(headerSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ToolInputDetailView(
                toolName: edit.toolName,
                input: parsed,
                rawJSON: edit.inputJSON,
                isDark: isDark
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
    }
}

// MARK: - Drop container (AppKit-backed)

/// Wraps SwiftUI content in an `NSView` that doubles as an
/// `NSDraggingDestination`. Clicks fall through to the embedded
/// `NSHostingView` naturally; drags are captured by the container because
/// it is the registered destination for the relevant pasteboard types.
struct ChatDropContainer<Content: View>: NSViewRepresentable {
    let onURLs: ([URL]) -> Void
    let onImageData: ([Data]) -> Void
    let onTargetedChange: (Bool) -> Void
    let onPointerDown: (() -> Void)?
    let content: Content

    init(
        onURLs: @escaping ([URL]) -> Void,
        onImageData: @escaping ([Data]) -> Void,
        onTargetedChange: @escaping (Bool) -> Void,
        onPointerDown: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.onURLs = onURLs
        self.onImageData = onImageData
        self.onTargetedChange = onTargetedChange
        self.onPointerDown = onPointerDown
        self.content = content()
    }

    func makeNSView(context: Context) -> ChatDropZoneNSView {
        let view = ChatDropZoneNSView()
        view.onURLs = onURLs
        view.onImageData = onImageData
        view.onTargetedChange = onTargetedChange
        view.onPointerDown = onPointerDown

        let host = NSHostingView(rootView: AnyView(content))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.hostingView = host
        return view
    }

    func updateNSView(_ nsView: ChatDropZoneNSView, context: Context) {
        nsView.hostingView?.rootView = AnyView(content)
        nsView.onURLs = onURLs
        nsView.onImageData = onImageData
        nsView.onTargetedChange = onTargetedChange
        nsView.onPointerDown = onPointerDown
    }
}

final class ChatDropZoneNSView: NSView {
    weak var hostingView: NSHostingView<AnyView>?
    var onURLs: (([URL]) -> Void)?
    var onImageData: (([Data]) -> Void)?
    var onTargetedChange: ((Bool) -> Void)?
    /// Kept for source compatibility with `ChatDropContainer`. We no longer
    /// install a global mouse-down monitor here because doing so was
    /// stealing focus mid-drag-select and breaking text selection inside
    /// the chat. The chat input's own `becomeFirstResponder` hook is enough
    /// to keep bonsplit's focused-pane bookkeeping in sync for the typing
    /// case (which was the only real leak).
    var onPointerDown: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerDraggedTypes()
        #if DEBUG
        dlog("ChatDropZone init frame=\(frameRect)")
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func registerDraggedTypes() {
        registerForDraggedTypes([
            .fileURL,
            .URL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerDraggedTypes()
        #if DEBUG
        dlog("ChatDropZone viewDidMoveToWindow window=\(window != nil ? "yes" : "no") frame=\(frame) bounds=\(bounds)")
        #endif
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        #if DEBUG
        dlog("ChatDropZone resize frame=\(frame)")
        #endif
    }

    // No hitTest override — the embedded NSHostingView naturally receives
    // pointer events as the topmost subview, and AppKit's dragging
    // destination scan still considers `self` because it is registered.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        dlog("ChatDropZone draggingEntered types=\(sender.draggingPasteboard.types ?? [])")
        #endif
        guard hasUsableContent(sender.draggingPasteboard) else { return [] }
        onTargetedChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasUsableContent(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var handledAny = false

        // Always clear the SwiftUI "targeted" state once we get to perform —
        // the overlay routing in FileDropOverlayView does not always send
        // us a matching draggingExited.
        onTargetedChange?(false)

        #if DEBUG
        dlog("ChatDropZone performDragOperation types=\(pb.types ?? [])")
        #endif

        // 1. File URLs (Finder, browser dock, descargas, etc.).
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            #if DEBUG
            dlog("ChatDropZone got \(urls.count) URL(s) — first=\(urls.first?.path ?? "?")")
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.onURLs?(urls)
            }
            handledAny = true
        } else if let propertyList = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !propertyList.isEmpty {
            // Legacy: NSFilenamesPboardType emitted by older drag sources.
            let urls = propertyList.map { URL(fileURLWithPath: $0) }
            #if DEBUG
            dlog("ChatDropZone got \(urls.count) legacy filename(s)")
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.onURLs?(urls)
            }
            handledAny = true
        }

        // 2. In-memory bitmap images (Preview, Photos, browser image drag).
        if !handledAny,
           let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            let datas: [Data] = images.compactMap { image in
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff)
                else { return nil }
                return rep.representation(using: .png, properties: [:])
            }
            if !datas.isEmpty {
                #if DEBUG
                dlog("ChatDropZone got \(datas.count) image(s) from NSImage providers")
                #endif
                DispatchQueue.main.async { [weak self] in
                    self?.onImageData?(datas)
                }
                handledAny = true
            }
        }

        #if DEBUG
        if !handledAny {
            dlog("ChatDropZone unable to extract URLs or images from pasteboard")
        }
        #endif
        return handledAny
    }

    private func hasUsableContent(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        return false
    }
}

// MARK: - FileDropPaneTarget conformance
//
// `FileDropOverlayView` sits above the SwiftUI hosting view to intercept
// file/image drags (nested `NSHostingController` layers block AppKit's
// native drag-destination routing from reaching deeply embedded views like
// `ChatDropZoneNSView`). The overlay forwards drops to whatever target
// implements `FileDropPaneTarget` under the cursor. Without this
// conformance the drop is routed to the outer `PaneDropTargetView` and
// opens the file in a sibling file-preview pane instead of attaching it
// to the pending chat message.
extension ChatDropZoneNSView: FileDropPaneTarget {
    func fileDropDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }
    func fileDropDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }
    func fileDropDraggingExited(_ sender: (any NSDraggingInfo)?) {
        draggingExited(sender)
    }
    func fileDropPrepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        prepareForDragOperation(sender)
    }
    func fileDropPerformDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        performDragOperation(sender)
    }
    func fileDropConcludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        concludeDragOperation(sender)
    }
}

// MARK: - Attachment chip

/// Inline thumbnails shown on a `.user` message bubble for files that
/// were attached when the message was sent. Read-only — no remove button.
private struct SentAttachmentsRow: View {
    let urls: [URL]
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(urls, id: \.self) { url in
                SentAttachmentThumb(url: url, isDark: isDark)
            }
        }
    }
}

private struct SentAttachmentThumb: View {
    let url: URL
    let isDark: Bool

    @Environment(\.chatPalette) private var palette
    @State private var thumb: NSImage?

    private var isImage: Bool {
        ChatAttachment.isImageFile(at: url)
    }

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else if isImage {
                Color.clear
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "doc")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                    Text(url.lastPathComponent)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 80)
                }
                .padding(4)
            }
        }
        .frame(width: 96, height: 96)
        .background(palette.codeBg(isDark))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
        .help(url.lastPathComponent)
        .onAppear(perform: loadThumb)
    }

    private func loadThumb() {
        guard isImage, thumb == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                thumb = image
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let isDark: Bool
    let onRemove: () -> Void

    @Environment(\.chatPalette) private var palette
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbView
                    .frame(width: 44, height: 44)
                    .background(palette.codeBg(isDark))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.isImage ? "image" : "file")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
        .onAppear(perform: loadThumbnail)
    }

    @ViewBuilder
    private var thumbView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipped()
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
                .frame(width: 44, height: 44)
        }
    }

    private func loadThumbnail() {
        guard attachment.isImage, thumbnail == nil else { return }
        let url = attachment.url
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                thumbnail = image
            }
        }
    }
}

// MARK: - Always-allowed popover

/// Popover that lists every tool the user has marked as "Allow always" in
/// the current workspace. Each row can be revoked individually. The
/// underlying source of truth is `<cwd>/.claude/settings.local.json`, so
/// changes here also propagate to any other tool that reads that file.
private struct AlwaysAllowedPopover: View {
    @ObservedObject var panel: ClaudeChatPanel
    @Environment(\.dismiss) private var dismiss

    private var sortedTools: [String] {
        Array(panel.alwaysAllowedTools).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(ChatPalette.green)
                Text(String(
                    localized: "claudeChat.alwaysAllowed.title",
                    defaultValue: "Always allowed tools"
                ))
                .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(String(
                localized: "claudeChat.alwaysAllowed.subtitle",
                defaultValue: "These tools auto-allow for any chat in this workspace. Persisted in .claude/settings.local.json."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            if sortedTools.isEmpty {
                emptyState
            } else {
                toolList
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(String(
                localized: "claudeChat.alwaysAllowed.empty",
                defaultValue: "Nothing here yet. Click \"Allow always\" on a tool prompt to add it."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var toolList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sortedTools, id: \.self) { tool in
                    HStack(spacing: 8) {
                        Text(tool)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            panel.revokeAlwaysAllowed(toolName: tool)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(String(
                            localized: "claudeChat.alwaysAllowed.revokeTooltip",
                            defaultValue: "Click to revoke — future uses of this tool will ask again."
                        ))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(ChatPalette.green.opacity(0.10))
                    )
                }
            }
        }
        .frame(maxHeight: 280)
    }
}

private struct ChatPaletteKey: EnvironmentKey {
    static let defaultValue = ChatPalette.default
}

extension EnvironmentValues {
    var chatPalette: ChatPalette {
        get { self[ChatPaletteKey.self] }
        set { self[ChatPaletteKey.self] = newValue }
    }
}

/// Body font size of the chat transcript, injected via environment so rows read
/// it without holding the panel store (snapshot-boundary rule). A change forces
/// a re-render of the rows that read it even though `TextBlockRow.==` ignores it,
/// exactly like `chatPalette`.
private struct ChatFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 13
}

extension EnvironmentValues {
    var chatFontSize: CGFloat {
        get { self[ChatFontSizeKey.self] }
        set { self[ChatFontSizeKey.self] = newValue }
    }
}

/// SwiftUI view that renders a `ClaudeChatPanel`. Fase 1 ships the layout
/// (message list, tool cards, input bar) wired to the panel's mock state;
/// fase 2 connects it to the live `ClaudeChatRunner` subprocess.
struct ClaudeChatPanelView: View {
    @ObservedObject var panel: ClaudeChatPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    /// Mirror of the same prop the terminal panel receives — driven by
    /// `TerminalNotificationStore` via WorkspaceContentView. We use this
    /// (rather than the panel's local pendingApprovals/pendingQuestions)
    /// so the blue ring follows the exact same lifecycle as in a Claude
    /// Code terminal session: appears when claude posts a notification,
    /// disappears when the user marks it read by interacting with the
    /// pane.
    let hasUnreadNotification: Bool
    let onRequestPanelFocus: () -> Void
#if DEBUG
    // Test-only virtualization probe; default no-op. See ChatLazyContractProbe.
    @Environment(\.chatLazyContractProbe) private var chatLazyContractProbe
#endif

    // (`draft` lives on `panel` — see `ClaudeChatPanel.draft`. Read/write
    // it as `panel.draft` and pass `Binding($panel.draft)` to the input
    // view. Lifting it onto the panel keeps the in-progress message
    // alive across workspace switches.)
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    /// True when the bottom sentinel is currently visible in the scroll
    /// viewport. When false, the user has scrolled up to read history; we
    /// then suppress auto-scroll so streaming events do not jerk the view.
    @State private var isAtBottom: Bool = true
    /// Bumped every time the user submits, to force a scroll-to-bottom
    /// even if they were reading earlier history.
    @State private var forceScrollToBottomToken: Int = 0
    /// Bumped to demand keyboard focus on the chat input — used after a
    /// drop completes so the next keystroke goes here, not to whichever
    /// pane the bonsplit focus manager last remembered.
    @State private var inputFocusToken: Int = 0
    /// Controls whether the always-allowed-tools popover is visible.
    @State private var showingAlwaysAllowedPopover: Bool = false
    /// Single source of truth for the popovers I added to the toolbar.
    /// Multiple `.popover(isPresented:)` siblings on the same toolbar
    /// can confuse SwiftUI under macOS Mission Control space switches
    /// (every Image(systemName:) in the bar would flash to zero-width
    /// on return), so we route through a shared enum + one
    /// `.popover(item:)` instead.
    @State private var activeChatPopover: ChatPopover?

    enum ChatPopover: String, Identifiable {
        case mcp
        case bashes
        var id: String { rawValue }
    }
    // Diff side pane state (open/close + "auto-opened once this session"
    // memo) lives on `panel` so it survives SwiftUI re-instantiating
    // this view. See the matching @Published fields on `ClaudeChatPanel`
    // for the rationale — keeping these as @State here regressed the
    // "once user closes it, never auto-reopen" rule because workspace
    // / bonsplit churn dropped the memo and re-triggered the auto-open.
    /// Confirmation dialog for the trash button / `/clear`. Mirrors the
    /// pattern used by the undo/rewind dialog so destructive actions are
    /// consistent.
    @State private var showingClearConfirmation: Bool = false
    /// Collapse state of the persistent todo banner that sits above the
    /// status line. Default expanded so a freshly-emitted list is
    /// immediately visible; the user can fold it after that.
    @State private var todosBannerExpanded: Bool = true
    @State private var showingUndoConfirmation: Bool = false
    /// Non-nil when the dialog is being raised from an inline rewind
    /// button — the rewind targets that user message. nil means rewind
    /// the last turn (header button).
    @State private var pendingRewindUserMessageId: UUID? = nil
    /// Highlights the chat area while a drag is hovering.
    @State private var isDropTargeted: Bool = false
    /// Slash-command autocomplete state. The popup only appears while the
    /// draft starts with a single `/` followed by an alphanumeric run (no
    /// whitespace yet) — i.e. while the user is typing a command name.
    @State private var slashAllCommands: [SlashCommand] = []
    @State private var slashFilteredCommands: [SlashCommand] = []
    @State private var slashSelectedIndex: Int = 0
    @State private var showingSlashPopup: Bool = false
    /// Measured intrinsic height of the chat input. The composer grows with
    /// the text up to `Self.inputMaxHeight`, after which the NSTextView
    /// scrolls internally. Initialized to the single-line height so the
    /// frame does not jump on first render.
    @State private var inputMeasuredHeight: CGFloat = Self.inputMinHeight
    /// Index into `userHistoryEntries` while the user is navigating
    /// previously-sent messages with ↑/↓. `nil` means "not browsing,
    /// the draft is the user's own in-progress text". Set on the first
    /// ↑ at the document edge, cleared when the user types anything new
    /// (so the draft becomes the new in-progress text) or steps past
    /// the most recent entry via ↓.
    @State private var historyIndex: Int? = nil
    /// Snapshot of the draft taken when the user entered history mode,
    /// so ↓ past the newest entry can restore it instead of dropping
    /// what they were typing.
    @State private var historyDraftSnapshot: String? = nil
    /// Last draft value we wrote programmatically while navigating
    /// history. Lets the `onChange(of: panel.draft)` observer tell
    /// "the user actually typed something" from "history just applied
    /// a value" without comparing against an entire list each time.
    @State private var lastHistoryAppliedDraft: String? = nil
    /// Mirror of the global "show blue ring on panes that need attention"
    /// preference (same key the terminal panel uses).
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    @Environment(\.colorScheme) private var colorScheme

    private static let bottomSentinelId = "__claudechat_bottom__"

    /// Cap the chat content width when the panel is unusually wide
    /// (full-screen, large external displays). Prose at 1500pt wide is
    /// uncomfortable to read; matches the convention used by ChatGPT,
    /// Claude.ai, Slack thread panes, etc.
    private static let maxContentWidth: CGFloat = 760

    /// Composer auto-grow bounds. The input grows with the typed text from
    /// `inputMinHeight` (one visible line, matching the previous fixed
    /// height) up to `inputMaxHeight`, after which the NSTextView scrolls
    /// internally instead of pushing the rest of the chat off-screen.
    private static let inputMinHeight: CGFloat = 24
    private static let inputMaxHeight: CGFloat = 220

    /// Drives the blue notification ring around the chat panel. We follow
    /// the same path as the terminal panel: the host (WorkspaceContentView)
    /// computes `hasUnreadNotification` from the global
    /// `TerminalNotificationStore` and passes it down. When the user
    /// directly interacts with the pane, cmux's `dismissNotificationOnDirectInteraction`
    /// flips it back to false — exactly as in a Claude Code terminal
    /// session.
    private var showsNotificationRing: Bool {
        notificationPaneRingEnabled && hasUnreadNotification
    }

    /// Palette derived from the panel's terminal-config-driven base colors.
    /// Recomputed on every render — cheap, just two NSColors.
    private var palette: ChatPalette {
        ChatPalette(
            terminalBg: panel.terminalBackgroundColor,
            terminalFg: panel.terminalForegroundColor
        )
    }

    var body: some View {
        ChatDropContainer(
            onURLs: { urls in
                for url in urls { _ = panel.attachFile(at: url) }
            },
            onImageData: { datas in
                for data in datas {
                    _ = panel.attachImageData(data, suggestedExtension: "png", baseName: "drop")
                }
            },
            onTargetedChange: { value in isDropTargeted = value },
            onPointerDown: {
                // Any click anywhere in the chat panel area: tell the host
                // that this pane should become bonsplit's focused pane, so
                // subsequent keystrokes route here instead of leaking to a
                // sibling terminal pane that bonsplit still remembers.
                onRequestPanelFocus()
            }
        ) {
            chatContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .background(
            // Hidden Markdown view that exercises every block type
            // we render so Swift's generic-metadata cache and
            // SwiftUI's view-graph cache are warm by the time the
            // user scrolls the real transcript. See
            // `ChatMarkdownPrewarmView` for the rationale.
            ChatMarkdownPrewarmView(isDark: colorScheme == .dark, palette: palette)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(palette.accent(colorScheme == .dark).opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: palette.accent(colorScheme == .dark).opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            // Pendant of the terminal panel's "unread notification" blue
            // ring: when claude needs the user (pending approval or open
            // ask_user_question) we draw the same ring around the chat
            // panel so the user spots it from anywhere on screen, just
            // like in their terminal claude sessions.
            if showsNotificationRing {
                RoundedRectangle(cornerRadius: PanelOverlayRingMetrics.cornerRadius)
                    .stroke(Color(nsColor: .systemBlue), lineWidth: PanelOverlayRingMetrics.lineWidth)
                    .shadow(color: Color(nsColor: .systemBlue).opacity(0.35), radius: 3)
                    .padding(PanelOverlayRingMetrics.inset)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        // (`.environment(\.chatPalette, palette)` deliberately moved into
        // `chatContent` — see note there.)
        .onChange(of: panel.pendingAttachments.count) { newCount in
            // After a drop, AppKit leaves the dragging container as first
            // responder — and bonsplit's focus manager then routes the
            // next keystroke to whichever pane it last marked focused
            // (often a sibling terminal). Pull focus back to the chat
            // input so the user can keep typing.
            if newCount > 0 {
                inputFocusToken &+= 1
            }
        }
        .onChange(of: panel.lastTurnEdits.count) { newCount in
            // Auto-open the diff side pane *once* per panel session, the
            // first time a turn produces edits. After that — and crucially
            // after the user manually closes it — leave the pane state
            // alone for the rest of the session. Both flags live on
            // `panel` so they survive view re-creation; otherwise the
            // memo would reset and we'd re-pop the pane every time
            // SwiftUI rebuilt this view.
            if !panel.hasAutoOpenedDiffPaneThisSession,
               newCount > 0,
               !panel.diffPaneOpen {
                panel.diffPaneOpen = true
                panel.hasAutoOpenedDiffPaneThisSession = true
            }
        }
        .onChange(of: panel.inputFocusRequestToken) { _ in
            // Panel asked for keyboard focus (e.g. bonsplit selected this
            // pane). Mirror it onto our local token so the input view
            // claims first-responder.
            inputFocusToken &+= 1
        }
        .onChange(of: panel.exitPlanModePresentedToken) { _ in
            // An ExitPlanMode card just appeared. Its
            // `.borderedProminent` "Auto-accept edits" button is
            // promoted by AppKit to default responder on mount, which
            // steals first-responder from the composer the user is
            // typing in. Re-assert composer focus AFTER the card has
            // mounted — a single `DispatchQueue.main.async` defers
            // past the current SwiftUI render pass, which is enough
            // for the card to be in the view tree by the time we call
            // makeFirstResponder again.
            DispatchQueue.main.async {
                inputFocusToken &+= 1
            }
        }
        .onChange(of: panel.status) { newStatus in
            // When a turn completes (.idle / .error after .sending) the
            // user is almost always about to type the next prompt — make
            // sure their keystrokes land in the input even if they had
            // clicked away mid-turn.
            if case .idle = newStatus {
                inputFocusToken &+= 1
            }
        }
        .onAppear {
            slashAllCommands = SlashCommandRegistry.availableCommands(
                cwd: panel.workingDirectory,
                reportedByCLI: panel.cliSlashCommands
            )
            updateSlashPopupForDraft(panel.draft)
        }
        .onChange(of: panel.workingDirectory) { newCwd in
            // The cwd governs which project-scope custom commands the
            // registry includes; refresh on rare changes.
            slashAllCommands = SlashCommandRegistry.availableCommands(
                cwd: newCwd,
                reportedByCLI: panel.cliSlashCommands
            )
            updateSlashPopupForDraft(panel.draft)
        }
        .onChange(of: panel.cliSlashCommands) { _ in
            // Arrives with the first `system/init`, i.e. after the initial
            // scan. Rebuild so skills and CLI built-ins show up without
            // waiting for a cwd change or a panel reopen.
            slashAllCommands = SlashCommandRegistry.availableCommands(
                cwd: panel.workingDirectory,
                reportedByCLI: panel.cliSlashCommands
            )
            updateSlashPopupForDraft(panel.draft)
        }
        .onChange(of: panel.draft) { newValue in
            updateSlashPopupForDraft(newValue)
            // Drop out of history navigation as soon as the user types
            // something — keeps the next ↑ honoring their new in-progress
            // draft, the way Claude Code CLI behaves.
            if historyIndex != nil, newValue != lastHistoryAppliedDraft {
                exitHistoryMode()
            }
        }
    }

    /// The actual SwiftUI tree of the chat panel, embedded inside the
    /// AppKit dragging container. Kept as a separate computed property so
    /// the body's outer view is just the container.
    /// User-chosen width of the diff pane, persisted across sessions/panels.
    /// Clamped to the container on use so neither side can collapse.
    @AppStorage("cmux.claudeChat.diffPaneWidth") private var diffPaneWidthStored: Double = 360
    @State private var diffDragStartWidth: CGFloat?

    private static let diffPaneMinWidth: CGFloat = 240
    private static let chatColumnMinWidth: CGFloat = 360

    private func clampDiffWidth(_ value: CGFloat, total: CGFloat) -> CGFloat {
        let maxDiff = max(Self.diffPaneMinWidth, total - Self.chatColumnMinWidth)
        return min(max(value, Self.diffPaneMinWidth), maxDiff)
    }

    private var chatContent: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    chatColumn
                    if panel.diffPaneOpen {
                        diffResizeHandle(totalWidth: geo.size.width)
                        DiffPaneView(
                            edits: panel.lastTurnEdits,
                            isDark: colorScheme == .dark,
                            onClose: {
                                panel.diffPaneOpen = false
                                // User just expressed an explicit preference —
                                // suppress any future auto-open for the rest
                                // of this session.
                                panel.hasAutoOpenedDiffPaneThisSession = true
                            }
                        )
                        .frame(width: clampDiffWidth(CGFloat(diffPaneWidthStored), total: geo.size.width))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                // Composer spans the full width, beneath both the chat and the
                // diff pane, instead of being confined to the chat column.
                composerBar
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(ChatPalette.green, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                        .background(ChatPalette.green.opacity(0.06))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: panel.diffPaneOpen)
            // The chat palette must be injected here, INSIDE the AppKit
            // hosting container — environments do not cross the
            // NSHostingView boundary, so an outer `.environment` would never
            // reach DiffPaneView/DiffBlock and they'd render with the static
            // default palette.
            .environment(\.chatPalette, palette)
            .environment(\.chatFontSize, CGFloat(panel.fontSize))
        }
    }

    /// The divider between chat and diff, widened into a drag handle so the
    /// user can pick the split. Dragging left (toward the chat) grows the diff
    /// pane; the width is clamped and persisted.
    private func diffResizeHandle(totalWidth: CGFloat) -> some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if diffDragStartWidth == nil {
                                    diffDragStartWidth = clampDiffWidth(
                                        CGFloat(diffPaneWidthStored), total: totalWidth
                                    )
                                }
                                let base = diffDragStartWidth ?? CGFloat(diffPaneWidthStored)
                                let proposed = base - value.translation.width
                                diffPaneWidthStored = Double(clampDiffWidth(proposed, total: totalWidth))
                            }
                            .onEnded { _ in diffDragStartWidth = nil }
                    )
            )
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            workingDirectoryHeader
            Divider()
            messageList
            if case .error(let message) = panel.status {
                errorBanner(message)
            }
            if let todos = panel.currentTodos, !todos.isEmpty {
                Divider()
                todosBanner(todos)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The composer (status line + git state + attachments + input), pulled out
    /// of `chatColumn` so it spans the full width beneath both the chat and the
    /// diff pane.
    private var composerBar: some View {
        VStack(spacing: 0) {
            if let line = panel.statusLineText, !line.isEmpty {
                statusLineRow(line)
            }
            if let branchState = panel.gitBranchState {
                branchSummaryRow(branchState: branchState, summary: panel.gitPendingSummary)
            }
            if !panel.pendingAttachments.isEmpty {
                attachmentsRow
            }
            inputBar
        }
    }

    /// Persistent banner above the status line that mirrors Claude
    /// Code's TUI todo list. Updates in place on every `TodoWrite`
    /// (handled in ClaudeChatPanel.handle(event:)), can be collapsed via
    /// the chevron, and disappears when the panel has no todos yet or
    /// after `clearTranscript`.
    @ViewBuilder
    private func todosBanner(_ todos: [ClaudeChatPanel.TodoItem]) -> some View {
        let total = todos.count
        let done = todos.filter { $0.status == "completed" }.count
        let inProgress = todos.filter { $0.status == "in_progress" }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        todosBannerExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: todosBannerExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                        Image(systemName: "checklist")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(String(
                            localized: "claudeChat.todos.summary",
                            defaultValue: "Todos"
                        ))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        Text("\(done)/\(total)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        if inProgress > 0 {
                            Text("· \(inProgress) in progress")
                                .font(.system(size: 10))
                                .foregroundColor(ChatPalette.cyan)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        panel.dismissTodos()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(
                    localized: "claudeChat.todos.dismiss.tooltip",
                    defaultValue: "Hide the todo list — it reappears the next time Claude updates it."
                ))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if todosBannerExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(todos) { todo in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: todoIcon(todo.status))
                                .font(.system(size: 11))
                                .foregroundColor(todoColor(todo.status))
                                .padding(.top, 1)
                            Text(todoDisplayText(todo))
                                .font(.system(size: 11))
                                .foregroundColor(todo.status == "completed" ? .secondary : .primary)
                                .strikethrough(todo.status == "completed")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        .background(palette.cardBg(colorScheme == .dark))
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func todoIcon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.square.fill"
        case "in_progress": return "circle.dotted"
        default: return "square"
        }
    }

    private func todoColor(_ status: String) -> Color {
        switch status {
        case "completed": return ChatPalette.green
        case "in_progress": return ChatPalette.cyan
        default: return .secondary
        }
    }

    private func todoDisplayText(_ todo: ClaudeChatPanel.TodoItem) -> String {
        if todo.status == "in_progress",
           let active = todo.activeForm,
           !active.isEmpty {
            return active
        }
        return todo.content
    }

    /// One-line status row driven by the user's `statusLine.command`
    /// (read from `.claude/settings.json`). Sits between the chat
    /// transcript and the input — same vertical position Claude Code
    /// interactive uses for its status line. The output may contain
    /// ANSI/SGR escapes (colors, bold, etc.); we parse them into an
    /// AttributedString so the rendered chip matches what the script
    /// intended.
    private func statusLineRow(_ text: String) -> some View {
        // Hard-truncate at the string level so SwiftUI never has to
        // ask `Text(AttributedString)` to compute mid-line truncation
        // for selection. The combo `.textSelection(.enabled)` +
        // `.lineLimit(1).truncationMode(.tail)` on a Text fed by an
        // AttributedString recomputed every render (ANSIRenderer is
        // not idempotent under value-equality once style identities
        // diverge) lands in a SelectionOverlay ↔ NSTextField intrinsic-
        // size invalidation loop that leaks NSMutableAttributedString
        // and pegs the main thread at 100% CPU. The status line is a
        // pure status indicator — selection is not a useful affordance
        // here; removing it kills the feedback path entirely.
        let attributed = ChatStatusLineAttributedCache.shared.attributed(
            for: text,
            baseFont: .system(size: 11, design: .monospaced),
            defaultColor: .secondary
        )
        return HStack(spacing: 0) {
            Text(attributed)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(palette.headerBg(colorScheme == .dark))
    }

    /// Fila inferior con el branch actual + resumen de cambios git
    /// pendientes (ahead/behind/staged/modified/untracked/stashed).
    /// Vive bajo `statusLineRow` para que el header quede limpio y el
    /// usuario tenga un descriptor concreto de qué le queda por subir/
    /// bajar/commitear, en lugar del antiguo asterisco binario.
    private func branchSummaryRow(
        branchState: SidebarGitBranchState,
        summary: ClaudeChatPanel.GitPendingSummary?
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(branchState.branch)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            branchSummaryChips(branchState: branchState, summary: summary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(palette.headerBg(colorScheme == .dark))
        .help(branchSummaryTooltip(branchState: branchState, summary: summary))
    }

    @ViewBuilder
    private func branchSummaryChips(
        branchState: SidebarGitBranchState,
        summary: ClaudeChatPanel.GitPendingSummary?
    ) -> some View {
        if let summary {
            if summary.isEmpty {
                Text(String(
                    localized: "claudeChat.gitSummary.clean",
                    defaultValue: "clean"
                ))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    if let ahead = summary.ahead, ahead > 0 {
                        summaryChip(
                            label: String(
                                localized: "claudeChat.gitSummary.label.push",
                                defaultValue: "push"
                            ),
                            value: ahead,
                            color: ChatPalette.green
                        )
                    }
                    if let behind = summary.behind, behind > 0 {
                        summaryChip(
                            label: String(
                                localized: "claudeChat.gitSummary.label.pull",
                                defaultValue: "pull"
                            ),
                            value: behind,
                            color: ChatPalette.cyan
                        )
                    }
                    if summary.staged > 0 {
                        summaryChip(
                            label: String(
                                localized: "claudeChat.gitSummary.label.staged",
                                defaultValue: "staged"
                            ),
                            value: summary.staged,
                            color: ChatPalette.green
                        )
                    }
                    if summary.modified > 0 {
                        summaryChip(
                            label: String(
                                localized: "claudeChat.gitSummary.label.modified",
                                defaultValue: "modified"
                            ),
                            value: summary.modified,
                            color: ChatPalette.yellow
                        )
                    }
                    if summary.conflicted > 0 {
                        summaryChip(
                            label: String(
                                localized: "claudeChat.gitSummary.label.conflicts",
                                defaultValue: "conflicts"
                            ),
                            value: summary.conflicted,
                            color: ChatPalette.red
                        )
                    }
                    if summary.untracked > 0 {
                        summaryChip(
                            label: String(
                                localized: "claudeChat.gitSummary.label.untracked",
                                defaultValue: "untracked"
                            ),
                            value: summary.untracked,
                            color: .secondary
                        )
                    }
                    if summary.stashed > 0 {
                        summaryChip(
                            label: String(
                                localized: "claudeChat.gitSummary.label.stash",
                                defaultValue: "stash"
                            ),
                            value: summary.stashed,
                            color: ChatPalette.cyan
                        )
                    }
                }
            }
        } else if branchState.isDirty {
            // Fallback mientras el resumen detallado se está calculando:
            // mantenemos la señal binaria original para que el usuario
            // no vea una fila "limpia" cuando sabemos que hay cambios.
            Text("…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func summaryChip(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
            Text("\(value)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(color)
    }

    private func branchSummaryTooltip(
        branchState: SidebarGitBranchState,
        summary: ClaudeChatPanel.GitPendingSummary?
    ) -> String {
        guard let summary else {
            return branchState.isDirty
                ? String(
                    localized: "claudeChat.gitSummary.tooltip.computing",
                    defaultValue: "Checking pending git changes…"
                )
                : String(
                    localized: "claudeChat.gitSummary.tooltip.fallback",
                    defaultValue: "Current git branch"
                )
        }
        if summary.isEmpty {
            return String(
                localized: "claudeChat.gitSummary.tooltip.clean",
                defaultValue: "Working tree clean and in sync with upstream"
            )
        }
        var lines: [String] = []
        if let ahead = summary.ahead, ahead > 0 {
            lines.append(String(
                localized: "claudeChat.gitSummary.tooltip.ahead",
                defaultValue: "\(ahead) commit(s) to push"
            ))
        }
        if let behind = summary.behind, behind > 0 {
            lines.append(String(
                localized: "claudeChat.gitSummary.tooltip.behind",
                defaultValue: "\(behind) commit(s) to pull"
            ))
        }
        if summary.staged > 0 {
            lines.append(String(
                localized: "claudeChat.gitSummary.tooltip.staged",
                defaultValue: "\(summary.staged) staged change(s)"
            ))
        }
        if summary.modified > 0 {
            lines.append(String(
                localized: "claudeChat.gitSummary.tooltip.modified",
                defaultValue: "\(summary.modified) modified file(s)"
            ))
        }
        if summary.conflicted > 0 {
            lines.append(String(
                localized: "claudeChat.gitSummary.tooltip.conflicted",
                defaultValue: "\(summary.conflicted) file(s) with conflicts"
            ))
        }
        if summary.untracked > 0 {
            lines.append(String(
                localized: "claudeChat.gitSummary.tooltip.untracked",
                defaultValue: "\(summary.untracked) untracked file(s)"
            ))
        }
        if summary.stashed > 0 {
            lines.append(String(
                localized: "claudeChat.gitSummary.tooltip.stashed",
                defaultValue: "\(summary.stashed) stash entry(ies)"
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// Chip del session id: clicarlo copia el id completo al clipboard y
    /// muestra una confirmación efímera. El tooltip explica qué es y qué
    /// pasa al clicar.
    @ViewBuilder
    private func sessionIdChip(sessionId: String) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(sessionId, forType: .string)
            panel.appendSystemNotice(String(
                localized: "claudeChat.sessionId.copied",
                defaultValue: "Copied session id to the clipboard."
            ))
        } label: {
            Text(String(sessionId.prefix(8)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(
            localized: "claudeChat.sessionId.tooltip",
            defaultValue: "Claude session id (resumed across turns). Click to copy."
        ))
    }

    // MARK: - Header

    private var workingDirectoryHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            // The working-directory label is the only flexible item in
            // this row. When the diff pane opens, `chatColumn` narrows
            // and a plain Text + Spacer combo lets the Text keep its
            // intrinsic width, pushing the trailing buttons out of the
            // HStack frame (parent clipping then makes them look
            // invisible). Pinning the Text to `maxWidth: .infinity`
            // with the lowest layout priority makes it the first to
            // yield space, so the buttons always render.
            Text(panel.workingDirectory)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            if let sessionId = panel.sessionId {
                sessionIdChip(sessionId: sessionId)
            }
            undoButton
            diffPaneButton
            alwaysAllowedButton
            mcpManagerButton
            backgroundShellsButton
            fontZoomOutButton
            fontZoomInButton
            copyChatButton
            clearButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .popover(item: $activeChatPopover, arrowEdge: .bottom) { which in
            switch which {
            case .mcp: McpManagerPopover(panel: panel)
            case .bashes: BackgroundShellsPopover(panel: panel)
            }
        }
        .confirmationDialog(
            pendingRewindUserMessageId == nil
                ? String(localized: "claudeChat.undo.confirm.title", defaultValue: "Undo last turn?")
                : String(localized: "claudeChat.rewind.confirm.title", defaultValue: "Rewind to this message?"),
            isPresented: $showingUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                pendingRewindUserMessageId == nil
                    ? String(localized: "claudeChat.undo.confirm.action", defaultValue: "Undo")
                    : String(localized: "claudeChat.rewind.confirm.action", defaultValue: "Rewind"),
                role: .destructive
            ) {
                let restored: Int?
                if let mid = pendingRewindUserMessageId {
                    restored = panel.rewindTo(userMessageId: mid)
                } else {
                    restored = panel.undoLastTurn()
                }
                pendingRewindUserMessageId = nil
                #if DEBUG
                NSLog("ClaudeChatPanel.rewind restored \(restored ?? 0) file(s)")
                #endif
            }
            Button(
                String(localized: "claudeChat.undo.confirm.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {
                pendingRewindUserMessageId = nil
            }
        } message: {
            Text(String(
                localized: "claudeChat.undo.confirm.message",
                defaultValue: "This restores files claude edited (using Claude Code's file history) and removes its responses after the chosen point. The next prompt will start a fresh session."
            ))
        }
        .confirmationDialog(
            String(
                localized: "claudeChat.clear.confirm.title",
                defaultValue: "Clear chat?"
            ),
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(
                    localized: "claudeChat.clear.confirm.action",
                    defaultValue: "Clear"
                ),
                role: .destructive
            ) {
                panel.clearTranscript()
            }
            Button(
                String(
                    localized: "claudeChat.clear.confirm.cancel",
                    defaultValue: "Cancel"
                ),
                role: .cancel
            ) { }
        } message: {
            Text(String(
                localized: "claudeChat.clear.confirm.message",
                defaultValue: "This wipes the visible transcript and starts a fresh session. Files Claude already edited stay on disk."
            ))
        }
    }

    private var undoButton: some View {
        let canUndo = !panel.undoCheckpoints.isEmpty
        return Button {
            showingUndoConfirmation = true
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11))
                .foregroundColor(canUndo ? .secondary : .secondary.opacity(0.35))
        }
        .buttonStyle(.borderless)
        .disabled(!canUndo)
        .help(String(
            localized: "claudeChat.undo.tooltip",
            defaultValue: "Undo the last turn — restores files claude edited and removes its replies"
        ))
    }

    private var diffPaneButton: some View {
        Button {
            panel.diffPaneOpen.toggle()
            // Manual toggle counts as the user having made their
            // choice — don't auto-open again on later turns.
            panel.hasAutoOpenedDiffPaneThisSession = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: panel.diffPaneOpen ? "sidebar.right" : "doc.on.doc")
                    .font(.system(size: 11))
                if !panel.lastTurnEdits.isEmpty {
                    Text("\(panel.lastTurnEdits.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundColor(panel.lastTurnEdits.isEmpty ? .secondary : ChatPalette.green)
        }
        .buttonStyle(.borderless)
        .help(String(
            localized: "claudeChat.diffPane.tooltip",
            defaultValue: "Show a side panel with the edits from the last turn"
        ))
    }

    private var alwaysAllowedButton: some View {
        Button {
            showingAlwaysAllowedPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11))
                if !panel.alwaysAllowedTools.isEmpty {
                    Text("\(panel.alwaysAllowedTools.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundColor(panel.alwaysAllowedTools.isEmpty ? .secondary : ChatPalette.green)
        }
        .buttonStyle(.borderless)
        .help(String(
            localized: "claudeChat.alwaysAllowed.button.tooltip",
            defaultValue: "Manage tools that are always allowed in this workspace"
        ))
        .popover(isPresented: $showingAlwaysAllowedPopover, arrowEdge: .bottom) {
            AlwaysAllowedPopover(panel: panel)
        }
    }

    private var mcpManagerButton: some View {
        let connectedCount = panel.mcpConnectedCount
        let failedCount = panel.mcpFailedCount
        return Button {
            activeChatPopover = (activeChatPopover == .mcp) ? nil : .mcp
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 11))
                if connectedCount > 0 {
                    Text("\(connectedCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundColor(
                failedCount > 0
                    ? ChatPalette.red
                    : (connectedCount > 0 ? ChatPalette.green : .secondary)
            )
        }
        .buttonStyle(.borderless)
        .help(String(
            localized: "claudeChat.mcp.button.tooltip",
            defaultValue: "Manage MCP servers (list, edit, reconnect)"
        ))
    }

    private var backgroundShellsButton: some View {
        let liveCount = panel.backgroundShellLiveCount
        return Button {
            activeChatPopover = (activeChatPopover == .bashes) ? nil : .bashes
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                if liveCount > 0 {
                    Text("\(liveCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundColor(liveCount > 0 ? ChatPalette.cyan : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(panel.backgroundShells.isEmpty)
        .help(String(
            localized: "claudeChat.bashes.button.tooltip",
            defaultValue: "Background shells claude has launched in this chat"
        ))
    }

    private var fontZoomOutButton: some View {
        Button {
            panel.zoomOut()
        } label: {
            Image(systemName: "textformat.size.smaller")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help(String(
            localized: "claudeChat.fontZoom.out.tooltip",
            defaultValue: "Decrease chat font size"
        ))
    }

    private var fontZoomInButton: some View {
        Button {
            panel.zoomIn()
        } label: {
            Image(systemName: "textformat.size.larger")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help(String(
            localized: "claudeChat.fontZoom.in.tooltip",
            defaultValue: "Increase chat font size"
        ))
    }

    private var copyChatButton: some View {
        Button {
            copyEntireTranscriptToClipboard()
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .disabled(panel.messages.isEmpty)
        .help(String(
            localized: "claudeChat.copyChat.tooltip",
            defaultValue: "Copy the whole conversation as Markdown to the clipboard"
        ))
    }

    private var clearButton: some View {
        Button {
            showingClearConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help(String(localized: "claudeChat.clear.tooltip", defaultValue: "Clear chat (start a new conversation)"))
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack so rows outside the viewport stay
                // un-materialised — at a 60-message visible window this
                // is what keeps layout cost flat as conversations grow.
                // Known tradeoff: `scrollTo(.bottom)` uses estimated
                // heights for off-screen rows, so the first jump to
                // bottom on a fresh chat may overshoot or undershoot
                // until SwiftUI materialises the real rows. In practice
                // the auto-scroll-to-bottom code paths re-fire on
                // `panel.messages.count` change (see `.onChange` below)
                // so the landing position corrects itself within one
                // frame as rows materialise.
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Older messages outside the render window get a
                    // single banner instead of N hidden rows — this is
                    // what keeps long chats from staying sluggish after
                    // the panel re-opens.
                    let hiddenOlderCount = max(0, panel.messages.count - panel.visibleMessageWindow)
                    if hiddenOlderCount > 0 {
                        loadOlderBanner(hiddenCount: hiddenOlderCount)
                    }
                    let visibleMessages = Array(panel.messages.suffix(panel.visibleMessageWindow))
                    let rows = ChatRowBuilderCache.shared.rows(
                        for: panel.id,
                        messages: visibleMessages
                    )
#if DEBUG
                    let _ = { chatLazyContractProbe.chatRowsProjection?() }()
#endif
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        rowView(row, isLast: idx == rows.count - 1)
                            .id(row.id)
                    }
                    ForEach(panel.pendingApprovals) { request in
                        ApprovalRequestCard(
                            request: request,
                            isDark: colorScheme == .dark,
                            onApprove: { panel.approve(toolUseId: request.id) },
                            onApproveAlways: {
                                panel.approveAlways(toolUseId: request.id, toolName: request.toolName)
                            },
                            onDeny: { reason in
                                panel.deny(toolUseId: request.id, reason: reason)
                            },
                            onStopTurn: { panel.cancel() }
                        )
                        .id("approval-\(request.id)")
                    }
                    ForEach(panel.pendingQuestions) { request in
                        UserQuestionCard(
                            request: request,
                            isDark: colorScheme == .dark,
                            onAnswer: { answersByIndex in
                                panel.answer(questionId: request.id, answers: answersByIndex)
                            }
                        )
                        .id("question-\(request.id)")
                    }
                    if case .sending = panel.status {
                        statusIndicator
                    }

                    // Sentinel pinned to the bottom of the content. Its
                    // appear/disappear callbacks tell us whether the user
                    // is currently looking at the latest content; we only
                    // auto-scroll while it's visible (logcat-style).
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomSentinelId)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        scrollToBottom(proxy: proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Circle().fill(palette.accent(colorScheme == .dark).opacity(0.85)))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                    .help(String(
                        localized: "claudeChat.scrollToBottom.tooltip",
                        defaultValue: "Jump to latest"
                    ))
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .onChange(of: panel.messages.count) { _ in
                autoScrollIfStuck(proxy: proxy)
            }
            .onChange(of: panel.pendingApprovals.count) { _ in
                autoScrollIfStuck(proxy: proxy)
            }
            .onChange(of: panel.pendingQuestions.count) { _ in
                autoScrollIfStuck(proxy: proxy)
            }
            .onChange(of: forceScrollToBottomToken) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: panel.diffPaneOpen) { _ in
                // Toggling the diff pane resizes `chatColumn` over the
                // 0.18s `.easeInOut` set on `chatContent`. The
                // LazyVStack re-wraps rows mid-animation and the
                // sentinel's estimated offset drifts, so a single
                // post-animation `scrollTo` lands mid-content. Fire
                // across the resize window: each pass re-anchors on
                // the latest row heights, and the final one settles
                // after the layout finishes.
                guard isAtBottom else { return }
                scheduleBottomAnchorPasses(
                    proxy: proxy,
                    delays: [0.0, 0.06, 0.12, 0.18, 0.26]
                )
            }
            .onAppear {
                // When the chat panel becomes visible (switching back from
                // another tab/workspace, or first mount) the ScrollView's
                // initial offset is the top of the content. The user
                // expects to land on the latest exchange instead. One
                // run-loop hop is enough now that rows are eager.
                DispatchQueue.main.async {
                    isAtBottom = true
                    proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow, isLast: Bool) -> some View {
        switch row {
        case .text(let payload):
            TextBlockRow(
                role: payload.role,
                text: payload.text,
                attachmentURLs: payload.attachmentURLs,
                messageId: payload.messageId,
                isDark: colorScheme == .dark,
                canRewindToHere: panel.undoCheckpoints.contains(where: {
                    $0.userMessageId == payload.messageId
                }),
                onRewindToHere: { messageId in
                    pendingRewindUserMessageId = messageId
                    showingUndoConfirmation = true
                },
                isCollapsedByDefault: payload.isCollapsedByDefault,
                slashCommandName: payload.slashCommandName,
                isPending: panel.pendingDrafts.contains(where: { $0.id == payload.messageId }),
                onCancelPending: { messageId in
                    panel.cancelPendingDraft(id: messageId)
                }
            )
            .equatable()
        case .toolBatch(let batch):
            // Filter the global approval/result collections down to just
            // the entries in this batch. Without this every row would
            // re-render whenever an unrelated tool result lands, because
            // the dictionary identity changes. Per-batch slices keep
            // `ToolBatchView`'s Equatable conformance meaningful.
            let toolIds = Set(batch.entries.map { $0.toolUse.id })
            let approvals = panel.pendingApprovals.filter { toolIds.contains($0.id) }
            let results = Dictionary(uniqueKeysWithValues:
                batch.entries.compactMap { entry -> (String, ChatMessageBlock.ToolResult)? in
                    guard let r = panel.toolResultsByToolUseId[entry.toolUse.id] else { return nil }
                    return (entry.toolUse.id, r)
                }
            )
            ToolBatchView(
                entries: batch.entries,
                pendingApprovals: approvals,
                toolResults: results,
                isCurrentBatch: isLast && panel.status == .sending,
                isDark: colorScheme == .dark,
                onApprove: panel.approve(toolUseId:),
                onDeny: { id, reason in panel.deny(toolUseId: id, reason: reason) },
                onStopTurn: panel.cancel,
                onExitPlanApprove: handleExitPlanApprove
            )
            .equatable()
        }
    }

    /// Compact banner shown above the message list when older messages
    /// are hidden by the render window. Two affordances: reveal another
    /// page (default step), or expand to the entire transcript at once.
    @ViewBuilder
    private func loadOlderBanner(hiddenCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(String(
                format: String(
                    localized: "claudeChat.loadOlder.label",
                    defaultValue: "%d earlier messages hidden"
                ),
                hiddenCount
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Button {
                panel.revealOlderMessages()
            } label: {
                Text(String(
                    localized: "claudeChat.loadOlder.loadMore",
                    defaultValue: "Load older"
                ))
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            Button {
                panel.revealAllMessages()
            } label: {
                Text(String(
                    localized: "claudeChat.loadOlder.showAll",
                    defaultValue: "Show all"
                ))
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardSubtleBg(colorScheme == .dark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(colorScheme == .dark), lineWidth: 1)
        )
    }

    private func autoScrollIfStuck(proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        // Re-anchor across a few frames: callers fire from
        // `.onChange(of: <…>.count)`, i.e. a brand-new row was just
        // added. The LazyVStack has not materialised that row yet, so
        // a single `scrollTo(.bottom)` would compute its offset from
        // the ESTIMATED height of the new row + sentinel and land in
        // empty space. Each subsequent pass materialises more of the
        // tail and re-anchors on increasingly accurate heights until
        // the offset settles on the true bottom.
        scheduleBottomAnchorPasses(proxy: proxy, delays: [0.0, 0.05, 0.12])
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        isAtBottom = true
        // From a position far above the bottom (history mode, fresh
        // open, post-resize, or the explicit "jump to latest" button),
        // the LazyVStack has no materialised rows near the sentinel and
        // `scrollTo(.bottom)` uses ESTIMATED row heights — the offset
        // ends up past the real content (visible blank zone) until
        // SwiftUI materialises the tail. Multiple passes let each
        // re-anchor refine the offset as rows come in.
        scheduleBottomAnchorPasses(proxy: proxy, delays: [0.0, 0.04, 0.10, 0.18])
    }

    /// Fire `proxy.scrollTo(bottomSentinel, .bottom)` at each provided
    /// delay (seconds from now). Used to re-anchor across the window
    /// during which the LazyVStack is still materialising the tail —
    /// each pass refines the offset on more accurate row heights.
    private func scheduleBottomAnchorPasses(
        proxy: ScrollViewProxy,
        delays: [Double]
    ) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if !panel.pendingApprovals.isEmpty || !panel.pendingQuestions.isEmpty {
            // Claude itself is paused — the daemon is waiting on the
            // user's reply to the inline approval / question card. Show
            // that explicitly so it doesn't look like a frozen "thinking".
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundColor(ChatPalette.orange)
                Text(String(
                    localized: "claudeChat.status.waitingForUser",
                    defaultValue: "Waiting for your reply…"
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "claudeChat.status.thinking", defaultValue: "Thinking…"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Attachments

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(panel.pendingAttachments) { attachment in
                    AttachmentChip(
                        attachment: attachment,
                        isDark: colorScheme == .dark,
                        onRemove: { panel.removePendingAttachment(id: attachment.id) }
                    )
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: 64)
        .background(headerBackground)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(ChatPalette.orange)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ChatPalette.orange.opacity(0.18))
    }

    // MARK: - Input bar

    private var inputBar: some View {
        // Extracted into `ClaudeChatComposerView` so it can short-circuit
        // its body via `Equatable` when the parent re-evaluates for
        // reasons unrelated to the composer (e.g. `panel.messages`
        // changing during streaming). Values that *do* affect the
        // composer are funnelled through the `==` comparator below.
        ClaudeChatComposerView(
            draft: panel.draft,
            permissionMode: panel.permissionMode,
            modelSelection: panel.modelSelection,
            thinkingEffort: panel.thinkingEffort,
            resolvedCLIDefaultEffort: panel.resolvedCLIDefaultEffort,
            measuredHeight: inputMeasuredHeight,
            modelName: panel.modelName,
            isSending: { if case .sending = panel.status { return true } else { return false } }(),
            isSendButtonDisabled: panel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            palette: palette,
            isDark: colorScheme == .dark,
            textColor: panel.terminalForegroundColor,
            focusToken: inputFocusToken,
            showingSlashPopup: showingSlashPopup,
            slashFilteredCommands: slashFilteredCommands,
            slashSelectedIndex: slashSelectedIndex,
            inputMinHeight: Self.inputMinHeight,
            inputMaxHeight: Self.inputMaxHeight,
            maxContentWidth: Self.maxContentWidth,
            onDraftChange: { panel.draft = $0 },
            onMeasuredHeightChange: { inputMeasuredHeight = $0 },
            onPermissionModeChange: { panel.permissionMode = $0 },
            onModelSelectionChange: { panel.modelSelection = $0 },
            onThinkingEffortChange: { panel.thinkingEffort = $0 },
            onPickSlashCommand: { idx in
                slashSelectedIndex = idx
                confirmSlashSelection()
            },
            onSubmit: submit,
            onCancel: handleEscape,
            onBecomeFirstResponder: { onRequestPanelFocus() },
            onArrowUp: { ctx in
                if moveSlashSelection(by: -1) { return true }
                return tryNavigateHistory(direction: .older, context: ctx)
            },
            onArrowDown: { ctx in
                if moveSlashSelection(by: +1) { return true }
                return tryNavigateHistory(direction: .newer, context: ctx)
            },
            onTabKey: completeSlashCommandPrefixIfPossible,
            onShiftTab: cyclePermissionMode,
            onCancelStreaming: panel.cancel
        )
        .equatable()
    }

    private func cancelIfSending() {
        if case .sending = panel.status {
            panel.cancel()
        }
    }

    /// ⌘A on an empty composer dumps the whole transcript to the
    /// clipboard as Markdown. SwiftUI's per-Text textSelection cannot
    /// span bubbles, so this is the only one-shot "grab the chat" path
    /// the user has.
    private func copyEntireTranscriptToClipboard() {
        let markdown = panel.transcriptAsMarkdown()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        panel.appendSystemNotice(String(
            localized: "claudeChat.copyAll.confirmation",
            defaultValue: "Copied the conversation to the clipboard."
        ))
    }

    /// Esc: close the slash-command popup if it's up; otherwise fall
    /// back to the original "stop the in-flight turn" behavior.
    private func handleEscape() {
        if showingSlashPopup {
            showingSlashPopup = false
            return
        }
        cancelIfSending()
    }

    private func submit() {
        // Slash-command popup intercepts Enter: if the user has filtered
        // down to one (or selected one) we run that instead of sending.
        if showingSlashPopup, !slashFilteredCommands.isEmpty {
            confirmSlashSelection()
            return
        }
        let trimmed = panel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Allow sending while the previous turn is still in flight —
        // panel.send queues it and the panel drains the queue when the
        // current turn completes (mirroring Claude Code's interactive UX).
        panel.send(trimmed)
        panel.draft = ""
        exitHistoryMode()
        // Sending always means the user wants to follow the conversation
        // again — jump to the latest, even if they were reading history.
        forceScrollToBottomToken &+= 1
    }

    // MARK: - Composer history navigation

    private enum HistoryDirection {
        case older
        case newer
    }

    /// Past user prompts the composer can recall with ↑/↓, ordered
    /// oldest → newest. Empty / attachment-only messages are skipped
    /// (recalling a blank entry would be useless).
    private var userHistoryEntries: [String] {
        panel.messages.compactMap { message in
            guard message.role == .user else { return nil }
            let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// Attempt to step the composer one entry through the user history.
    /// Returns `true` (= consume the keypress) when we either applied a
    /// new entry, swallowed an edge press already in history mode, or
    /// restored the snapshot. Returns `false` for the very first ↑ at a
    /// non-edge caret position, so the NSTextView's normal caret movement
    /// still wins inside multi-line drafts.
    @discardableResult
    private func tryNavigateHistory(
        direction: HistoryDirection,
        context: ChatInputArrowContext
    ) -> Bool {
        // Already browsing — every ↑/↓ stays in history mode until ↓
        // walks off the newest entry. Otherwise only enter when the
        // caret is at the matching edge of the draft (or the draft is
        // empty), so ↑ on line 2 of a multi-line draft still moves the
        // caret instead of swapping the content out from under the user.
        let alreadyInHistory = historyIndex != nil
        if !alreadyInHistory {
            switch direction {
            case .older:
                guard context.isAtFirstLine || context.isEmpty else { return false }
            case .newer:
                // ↓ only meaningful when we're already replaying.
                return false
            }
        }

        let entries = userHistoryEntries
        guard !entries.isEmpty else { return false }

        // Index can go stale if claude streams a new response mid-replay
        // (claude messages are filtered out but the user count is stable
        // — still, an extra defensive clamp is cheap).
        let current = min(historyIndex ?? entries.count, entries.count)

        switch direction {
        case .older:
            guard current > 0 else { return true } // pinned to oldest
            apply(historyEntry: entries[current - 1], newIndex: current - 1)
        case .newer:
            if current >= entries.count - 1 {
                // Past the newest → drop back to whatever the user was
                // typing before they hit ↑ the first time.
                restoreHistorySnapshot()
            } else {
                apply(historyEntry: entries[current + 1], newIndex: current + 1)
            }
        }
        return true
    }

    private func apply(historyEntry entry: String, newIndex: Int) {
        if historyDraftSnapshot == nil {
            historyDraftSnapshot = panel.draft
        }
        historyIndex = newIndex
        lastHistoryAppliedDraft = entry
        panel.draft = entry
    }

    private func restoreHistorySnapshot() {
        let snapshot = historyDraftSnapshot ?? ""
        historyIndex = nil
        historyDraftSnapshot = nil
        // Tag the value we are about to write so the draft observer's
        // "user just typed" guard does not re-fire exitHistoryMode().
        // The next user keystroke will diverge from this marker and the
        // observer naturally ignores it because historyIndex is already
        // nil anyway.
        lastHistoryAppliedDraft = snapshot
        panel.draft = snapshot
    }

    private func exitHistoryMode() {
        historyIndex = nil
        historyDraftSnapshot = nil
        lastHistoryAppliedDraft = nil
    }

    /// User clicked one of the inline ExitPlanMode buttons after Claude
    /// surfaced a plan. Headless `claude -p --permission-mode plan` auto-
    /// allows ExitPlanMode (we don't wire `--permission-prompt-tool` for
    /// plan mode), so the SDK never asks us — the user is left looking at
    /// the plan with no way to act on it. The buttons replicate Claude
    /// Code interactive's three-choice prompt: flip the panel's permission
    /// mode for subsequent turns and send a short follow-up so Claude
    /// resumes (or stays in plan mode if the user declined).
    private func handleExitPlanApprove(autoAcceptEdits: Bool) {
        panel.permissionMode = autoAcceptEdits ? .acceptEdits : .normal
        panel.send(String(
            localized: "claudeChat.plan.approveMessage",
            defaultValue: "Please proceed with the plan."
        ))
    }

    /// Cycle the chat permission mode through `ChatPermissionMode.allCases`
    /// (plan → normal → acceptEdits → auto → plan …) so the user can flip
    /// modes from the keyboard, matching Claude Code interactive's
    /// Shift+Tab behavior. Always returns `true` to swallow the key.
    @discardableResult
    private func cyclePermissionMode() -> Bool {
        let modes = ChatPermissionMode.allCases
        guard let current = modes.firstIndex(of: panel.permissionMode) else {
            panel.permissionMode = modes.first ?? .normal
            return true
        }
        panel.permissionMode = modes[(current + 1) % modes.count]
        return true
    }

    // MARK: - Slash command autocomplete

    /// Parse the draft and decide whether to show the popup. The popup
    /// shows iff the trimmed draft starts with `/` and the first token
    /// (everything until whitespace) is just word-characters — i.e. the
    /// user is still typing the command name. Once they type a space we
    /// hide it (the rest of the input is treated as command arguments,
    /// for `sendAsPrompt` commands).
    private func updateSlashPopupForDraft(_ text: String) {
        guard let prefix = slashCommandPrefix(in: text) else {
            if showingSlashPopup { showingSlashPopup = false }
            return
        }
        // Lazy-load guard: SwiftUI does not guarantee `onAppear` runs
        // before the first `onChange(of: panel.draft)`. If the user
        // types `/star` before the registry has populated, our filter
        // returns nothing and the popup never appears the first time.
        // The list always contains the 7 built-ins once loaded, so an
        // empty array reliably means "not loaded yet".
        if slashAllCommands.isEmpty {
            slashAllCommands = SlashCommandRegistry.availableCommands(
                cwd: panel.workingDirectory,
                reportedByCLI: panel.cliSlashCommands
            )
        }
        let filtered = SlashCommandRegistry.filter(slashAllCommands, byPrefix: prefix)
        slashFilteredCommands = filtered
        if filtered.isEmpty {
            showingSlashPopup = false
            return
        }
        if slashSelectedIndex >= filtered.count {
            slashSelectedIndex = 0
        }
        showingSlashPopup = true
    }

    /// Returns the `/`-less prefix the user has typed so far, or `nil`
    /// when the draft is not in "typing a slash command" state.
    private func slashCommandPrefix(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let after = text.dropFirst()
        // No whitespace allowed — once the user adds args we stop
        // suggesting names.
        if after.contains(where: { $0.isWhitespace }) { return nil }
        return String(after)
    }

    /// Move the highlighted row in the popup. Returns true (= key
    /// consumed) when the popup is visible, so the NSTextView default
    /// caret movement does not also fire.
    @discardableResult
    private func moveSlashSelection(by delta: Int) -> Bool {
        guard showingSlashPopup, !slashFilteredCommands.isEmpty else { return false }
        let count = slashFilteredCommands.count
        let next = ((slashSelectedIndex + delta) % count + count) % count
        slashSelectedIndex = next
        return true
    }

    /// Tab: complete the input to the longest unambiguous prefix among
    /// the filtered commands. Returns true to swallow Tab when the popup
    /// is up.
    @discardableResult
    private func completeSlashCommandPrefixIfPossible() -> Bool {
        guard showingSlashPopup, !slashFilteredCommands.isEmpty else { return false }
        if slashFilteredCommands.count == 1 {
            // One match — fully complete (without confirming) so the user
            // can still hit Enter or add args.
            panel.draft = "/" + slashFilteredCommands[0].name
            return true
        }
        // Multiple matches — extend the typed prefix to the longest
        // common name prefix, like a shell.
        let names = slashFilteredCommands.map { $0.name }
        let common = longestCommonPrefix(of: names)
        let typed = slashCommandPrefix(in: panel.draft) ?? ""
        if common.count > typed.count {
            panel.draft = "/" + common
        }
        return true
    }

    private func longestCommonPrefix(of strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        for s in strings.dropFirst() {
            while !s.lowercased().hasPrefix(prefix.lowercased()), !prefix.isEmpty {
                prefix.removeLast()
            }
            if prefix.isEmpty { return "" }
        }
        return prefix
    }

    /// User picked the highlighted command (Enter / click).
    private func confirmSlashSelection() {
        guard slashSelectedIndex < slashFilteredCommands.count else { return }
        let cmd = slashFilteredCommands[slashSelectedIndex]
        showingSlashPopup = false
        switch cmd.action {
        case .runBuiltin(let key):
            runBuiltinSlashCommand(key)
            panel.draft = ""
        case .sendAsPrompt:
            // Headless `claude -p` does not process slash commands —
            // it would just see the literal "/start-task" as the user
            // prompt and ask claude to interpret it (which usually
            // produces nothing useful). Read the .md body ourselves,
            // forward it as the actual prompt, and tag the local
            // transcript message so the UI shows the original
            // `/<name>` in a collapsed tool-card-style row.
            let body = SlashCommandRegistry.readBody(of: cmd)
            if body.isEmpty {
                // Empty file or unreadable — fall back to sending the
                // literal command (claude may at least echo something).
                panel.send("/" + cmd.name)
            } else {
                panel.sendSlashCommand(name: cmd.name, expandedText: body)
            }
            panel.draft = ""
            forceScrollToBottomToken &+= 1
        }
    }

    /// Dispatch a built-in slash command by its registry key.
    private func runBuiltinSlashCommand(_ key: String) {
        switch key {
        case SlashCommandRegistry.BuiltinKey.clear:
            // Route through the same confirmation flow as the trash
            // button — clearing the transcript is destructive and the
            // slash command should not bypass the safety prompt.
            showingClearConfirmation = true
        case SlashCommandRegistry.BuiltinKey.rewind,
             SlashCommandRegistry.BuiltinKey.undo:
            if panel.undoCheckpoints.isEmpty {
                panel.appendSystemNotice(String(
                    localized: "claudeChat.slash.rewind.empty",
                    defaultValue: "Nothing to rewind — no turns recorded yet."
                ))
                return
            }
            // Re-use the same dialog the header button raises.
            pendingRewindUserMessageId = nil
            showingUndoConfirmation = true
        case SlashCommandRegistry.BuiltinKey.model:
            let model = panel.modelName ?? String(
                localized: "claudeChat.slash.model.unknown",
                defaultValue: "(model not yet reported by claude)"
            )
            panel.appendSystemNotice(String(
                format: String(
                    localized: "claudeChat.slash.model.message",
                    defaultValue: "Active model: %@"
                ),
                model
            ))
        case SlashCommandRegistry.BuiltinKey.permissions:
            showingAlwaysAllowedPopover = true
        case SlashCommandRegistry.BuiltinKey.mcp:
            activeChatPopover = .mcp
        case SlashCommandRegistry.BuiltinKey.bashes:
            activeChatPopover = .bashes
        case SlashCommandRegistry.BuiltinKey.help:
            panel.appendSystemNotice(buildHelpMessage())
        default:
            break
        }
    }

    private func buildHelpMessage() -> String {
        var out = String(
            localized: "claudeChat.slash.help.header",
            defaultValue: "Available slash commands:"
        ) + "\n\n"
        for cmd in slashAllCommands {
            let scopeTag: String
            switch cmd.source {
            case .builtin: scopeTag = ""
            case .userCustom: scopeTag = " (user)"
            case .projectCustom: scopeTag = " (project)"
            case .cliReported: scopeTag = " (claude)"
            }
            out += "- `/\(cmd.name)`\(scopeTag) — \(cmd.description)\n"
        }
        return out
    }

    // MARK: - Theme

    private var backgroundColor: Color {
        palette.panelBg(colorScheme == .dark)
    }

    private var headerBackground: Color {
        palette.headerBg(colorScheme == .dark)
    }

    private var inputBackground: Color {
        palette.inputBg(colorScheme == .dark)
    }

    // MARK: - Focus flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        }
    }
}

// MARK: - Composer subview

/// Isolated composer (slash popup + multi-line text input + footer with
/// permission picker / model chip / send button). `ClaudeChatPanelView`
/// hosts this with `.equatable()` so the composer's body short-circuits
/// when the parent re-evaluates for reasons that don't affect the
/// composer (the main offender being `panel.messages` mutating ~20 Hz
/// during streaming).
///
/// Closures and the underlying mutator callbacks are intentionally
/// excluded from `==`. SwiftUI re-installs the struct with the newest
/// closure values every render anyway; we just suppress the body work.
private struct ClaudeChatComposerView: View, Equatable {
    let draft: String
    let permissionMode: ChatPermissionMode
    let modelSelection: ChatModelSelection
    let thinkingEffort: ChatThinkingEffort
    let resolvedCLIDefaultEffort: ChatThinkingEffort?
    let measuredHeight: CGFloat
    let modelName: String?
    let isSending: Bool
    let isSendButtonDisabled: Bool
    let palette: ChatPalette
    let isDark: Bool
    let textColor: NSColor
    let focusToken: Int
    let showingSlashPopup: Bool
    let slashFilteredCommands: [SlashCommand]
    let slashSelectedIndex: Int
    let inputMinHeight: CGFloat
    let inputMaxHeight: CGFloat
    let maxContentWidth: CGFloat

    let onDraftChange: (String) -> Void
    let onMeasuredHeightChange: (CGFloat) -> Void
    let onPermissionModeChange: (ChatPermissionMode) -> Void
    let onModelSelectionChange: (ChatModelSelection) -> Void
    let onThinkingEffortChange: (ChatThinkingEffort) -> Void
    let onPickSlashCommand: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onBecomeFirstResponder: () -> Void
    let onArrowUp: (ChatInputArrowContext) -> Bool
    let onArrowDown: (ChatInputArrowContext) -> Bool
    let onTabKey: () -> Bool
    let onShiftTab: () -> Bool
    let onCancelStreaming: () -> Void

    static func == (lhs: ClaudeChatComposerView, rhs: ClaudeChatComposerView) -> Bool {
        return lhs.draft == rhs.draft
            && lhs.permissionMode == rhs.permissionMode
            && lhs.modelSelection == rhs.modelSelection
            && lhs.thinkingEffort == rhs.thinkingEffort
            && lhs.resolvedCLIDefaultEffort == rhs.resolvedCLIDefaultEffort
            && lhs.measuredHeight == rhs.measuredHeight
            && lhs.modelName == rhs.modelName
            && lhs.isSending == rhs.isSending
            && lhs.isSendButtonDisabled == rhs.isSendButtonDisabled
            && lhs.isDark == rhs.isDark
            && Self.colorsEqual(lhs.textColor, rhs.textColor)
            && Self.colorsEqual(lhs.palette.terminalBg, rhs.palette.terminalBg)
            && Self.colorsEqual(lhs.palette.terminalFg, rhs.palette.terminalFg)
            && lhs.focusToken == rhs.focusToken
            && lhs.showingSlashPopup == rhs.showingSlashPopup
            && lhs.slashSelectedIndex == rhs.slashSelectedIndex
            && lhs.slashFilteredCommands.map(\.id) == rhs.slashFilteredCommands.map(\.id)
    }

    private static func colorsEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        let lhs = a.usingColorSpace(.sRGB) ?? a
        let rhs = b.usingColorSpace(.sRGB) ?? b
        return lhs.redComponent == rhs.redComponent
            && lhs.greenComponent == rhs.greenComponent
            && lhs.blueComponent == rhs.blueComponent
            && lhs.alphaComponent == rhs.alphaComponent
    }

    var body: some View {
        let draftBinding = Binding<String>(
            get: { draft },
            set: { onDraftChange($0) }
        )
        let measuredHeightBinding = Binding<CGFloat>(
            get: { measuredHeight },
            set: { onMeasuredHeightChange($0) }
        )
        let permissionBinding = Binding<ChatPermissionMode>(
            get: { permissionMode },
            set: { onPermissionModeChange($0) }
        )
        let modelBinding = Binding<ChatModelSelection>(
            get: { modelSelection },
            set: { onModelSelectionChange($0) }
        )
        let thinkingBinding = Binding<ChatThinkingEffort>(
            get: { thinkingEffort },
            set: { onThinkingEffortChange($0) }
        )

        VStack(alignment: .leading, spacing: 6) {
            // Slash-command suggestions sit ABOVE the input so the user can
            // see what they're picking while still typing. Inserting it as
            // a sibling (not an overlay) sidesteps the clip/zindex traps
            // that hide an overlay rendered "above" its parent's bounds.
            if showingSlashPopup, !slashFilteredCommands.isEmpty {
                SlashCommandPopup(
                    commands: slashFilteredCommands,
                    selectedIndex: slashSelectedIndex,
                    palette: palette,
                    isDark: isDark,
                    onPick: { idx in onPickSlashCommand(idx) }
                )
                .frame(maxWidth: 460, alignment: .leading)
                .transition(.opacity)
            }

            ChatInputTextView(
                text: draftBinding,
                placeholder: String(
                    localized: "claudeChat.input.placeholder",
                    defaultValue: "Ask Claude…"
                ),
                isDark: isDark,
                textColor: textColor,
                focusToken: focusToken,
                measuredHeight: measuredHeightBinding,
                onSubmit: onSubmit,
                onCancel: onCancel,
                onBecomeFirstResponder: onBecomeFirstResponder,
                onArrowUp: onArrowUp,
                onArrowDown: onArrowDown,
                onTabKey: onTabKey,
                onShiftTab: onShiftTab
            )
            .frame(height: min(max(measuredHeight, inputMinHeight), inputMaxHeight))
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.inputBg(isDark))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            )

            HStack(spacing: 8) {
                Picker("", selection: permissionBinding) {
                    ForEach(ChatPermissionMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.iconName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .help(String(
                    localized: "claudeChat.mode.picker.tooltip",
                    defaultValue: "How tool calls are gated for the next turn. Plan = read-only, Normal = ask each tool, Auto-edits = edits auto + bash asks, Bypass = everything auto."
                ))
                .frame(maxWidth: 110)

                // Model picker. Mirrors the permission-mode picker: the
                // selection is persisted on the panel and bakes into
                // `claude --model` at spawn. `ClaudeChatRunner` tracks
                // `launchedModel` and respawns mid-session (preserving
                // the session via `--resume`) when the user changes it.
                // The live `modelName` from `system/init` shows in the
                // tooltip so the user can confirm the swap took.
                Picker("", selection: modelBinding) {
                    ForEach(ChatModelSelection.allCases) { sel in
                        Label(sel.label, systemImage: sel.iconName).tag(sel)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .layoutPriority(-1)
                .frame(maxWidth: 140)
                .help({
                    let live = (modelName?.isEmpty == false) ? modelName! : "—"
                    return String(format: String(
                        localized: "claudeChat.model.picker.tooltip",
                        defaultValue: "Claude model the next turn will use. Active: %@"
                    ), live)
                }())

                // Thinking-effort picker. Same lifecycle as the model
                // picker — `claude --effort <level>` is baked at spawn
                // and the runner respawns when the selection changes.
                // When the user picks "Default" (no `--effort` flag),
                // the collapsed label shows the resolved value in
                // parentheses (e.g. "Default (xhigh)") so the active
                // effort is always visible without opening the menu.
                Menu {
                    ForEach(ChatThinkingEffort.allCases) { eff in
                        Button {
                            onThinkingEffortChange(eff)
                        } label: {
                            Label(eff.label, systemImage: eff.iconName)
                        }
                    }
                } label: {
                    Label(
                        thinkingEffort.activeLabel(resolvedDefault: resolvedCLIDefaultEffort),
                        systemImage: thinkingEffort.iconName
                    )
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .layoutPriority(-1)
                .fixedSize()
                .help(String(
                    localized: "claudeChat.thinking.picker.tooltip",
                    defaultValue: "Thinking effort for the next turn (--effort flag). Higher levels give Claude a larger thinking budget but cost more tokens."
                ))

                Spacer(minLength: 4)

                // `.fixedSize()` pins this cluster at its ideal width;
                // without it SwiftUI compresses the internal padding of
                // `.borderedProminent` and the 12pt Image gets clipped
                // out of the button's visible frame when the composer
                // narrows.
                HStack(spacing: 6) {
                    if isSending {
                        Button(action: onCancelStreaming) {
                            Image(systemName: "stop.fill")
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help(String(
                            localized: "claudeChat.cancel.button",
                            defaultValue: "Stop (Esc)"
                        ))
                    }
                    Button(action: onSubmit) {
                        Image(systemName: "arrow.up")
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSendButtonDisabled)
                    .help(String(
                        localized: "claudeChat.send.button",
                        defaultValue: "Send (Enter) — queues if Claude is still replying"
                    ))
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .background(palette.headerBg(isDark))
    }
}

private struct ToolUseCard: View {
    let toolUse: ChatMessageBlock.ToolUse
    let pending: ChatApprovalRequest?
    let result: ChatMessageBlock.ToolResult?
    let isDark: Bool
    let onApprove: () -> Void
    /// See ApprovalRequestCard.onDeny — same semantics: an optional
    /// free-text reason flows back to Claude as part of the tool_result.
    let onDeny: (String?) -> Void
    let onStopTurn: () -> Void
    /// Invoked by the inline ExitPlanMode buttons. `autoAcceptEdits == true`
    /// switches the panel into `acceptEdits` mode before the follow-up turn
    /// is sent (mirrors Claude Code's "Yes, and auto-accept edits" option).
    let onExitPlanApprove: (Bool) -> Void

    @Environment(\.chatPalette) private var palette
    @State private var expanded: Bool
    @State private var denyReasonExpanded = false
    @State private var denyReason: String = ""
    /// Set to true once the user clicks any of the plan buttons, so they
    /// disappear after a single choice (matches Claude Code's behavior).
    @State private var planResolved: Bool = false

    init(
        toolUse: ChatMessageBlock.ToolUse,
        pending: ChatApprovalRequest?,
        result: ChatMessageBlock.ToolResult?,
        isDark: Bool,
        onApprove: @escaping () -> Void,
        onDeny: @escaping (String?) -> Void,
        onStopTurn: @escaping () -> Void,
        onExitPlanApprove: @escaping (Bool) -> Void
    ) {
        self.toolUse = toolUse
        self.pending = pending
        self.result = result
        self.isDark = isDark
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onStopTurn = onStopTurn
        self.onExitPlanApprove = onExitPlanApprove
        // ExitPlanMode carries the actual plan markdown as its argument;
        // collapsing it by default would force the user to click before
        // seeing what claude wants to do. Every other tool stays
        // collapsed (the chat view favors a compact transcript).
        _expanded = State(initialValue: toolUse.name == "ExitPlanMode")
    }

    /// `true` while the ExitPlanMode card should advertise the three
    /// approval buttons (auto-accept / approve / keep planning). We skip
    /// them when an SDK-level approval is already pending — the normal
    /// Allow/Deny row covers that case — and once the user has clicked
    /// any plan button on this instance.
    private var showsExitPlanButtons: Bool {
        toolUse.name == "ExitPlanMode" && pending == nil && !planResolved
    }

    private var parsedInput: [String: Any]? {
        guard let data = toolUse.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private var summary: String {
        // Compact one-liner shown when the card is collapsed.
        switch toolUse.name {
        case "Edit", "Write", "NotebookEdit":
            if let path = parsedInput?["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        case "MultiEdit":
            if let path = parsedInput?["file_path"] as? String,
               let edits = parsedInput?["edits"] as? [[String: Any]] {
                return "\((path as NSString).lastPathComponent) · \(edits.count) edits"
            }
        case "Bash":
            if let cmd = parsedInput?["command"] as? String {
                return cmd.replacingOccurrences(of: "\n", with: " ↵ ")
            }
        case "Read":
            if let path = parsedInput?["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        case "Glob", "Grep":
            if let pattern = parsedInput?["pattern"] as? String {
                return pattern
            }
        case "WebFetch":
            if let url = parsedInput?["url"] as? String {
                return url
            }
        case "WebSearch":
            if let q = parsedInput?["query"] as? String {
                return q
            }
        case "Skill":
            if let name = parsedInput?["skill"] as? String {
                if let args = parsedInput?["args"] as? String, !args.isEmpty {
                    return "\(name) · \(args)"
                }
                return name
            }
        case "Task":
            if let desc = parsedInput?["description"] as? String, !desc.isEmpty {
                return desc
            }
            if let agent = parsedInput?["subagent_type"] as? String {
                return agent
            }
        case "TodoWrite":
            if let todos = parsedInput?["todos"] as? [[String: Any]] {
                return "\(todos.count) todos"
            }
        case "TaskCreate":
            // Claude Code 2.x split TodoWrite into per-task tools.
            // TaskCreate carries a single task at a time — show its
            // subject so the card header is meaningful.
            if let subject = parsedInput?["subject"] as? String, !subject.isEmpty {
                return subject
            }
        case "TaskUpdate":
            if let status = parsedInput?["status"] as? String, !status.isEmpty {
                if let subject = parsedInput?["subject"] as? String, !subject.isEmpty {
                    return "\(status): \(subject)"
                }
                return status
            }
        case "TaskList", "TaskGet", "TaskOutput", "TaskStop":
            return ""
        case "ExitPlanMode":
            if let plan = parsedInput?["plan"] as? String {
                // First non-empty line, stripped of leading markdown
                // syntax, so the collapsed header shows the plan's
                // headline rather than a `#` or `-` prefix.
                let headline = plan
                    .components(separatedBy: "\n")
                    .lazy
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first(where: { !$0.isEmpty }) ?? ""
                let stripped = headline.drop(while: { "#-*>•".contains($0) || $0 == " " })
                let cap = 80
                let result = String(stripped)
                return result.count > cap ? String(result.prefix(cap)) + "…" : result
            }
        default:
            break
        }
        return ""
    }

    var body: some View {
        // While we're advertising the plan-approval buttons the card has
        // to stay expanded so the user can read the plan they're about to
        // accept or reject. Lock both the visible detail and the chevron
        // toggle until they pick an option.
        let lockedExpanded = showsExitPlanButtons
        let isExpanded = expanded || lockedExpanded
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                guard !lockedExpanded else { return }
                expanded.toggle()
            }) {
                header
            }
            .buttonStyle(.plain)
            .disabled(lockedExpanded)
            if isExpanded {
                detail
                if let result {
                    Divider().opacity(0.4).padding(.vertical, 2)
                    ToolResultCard(result: result, isDark: isDark, embedded: true)
                }
            }
            if pending != nil {
                if denyReasonExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField(
                                String(
                                    localized: "claudeChat.tool.denyReason.placeholder",
                                    defaultValue: "e.g. \"use a different approach\" or leave empty"
                                ),
                                text: $denyReason
                            )
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit {
                                let trimmed = denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
                                onDeny(trimmed.isEmpty ? nil : trimmed)
                            }
                            Button(String(
                                localized: "claudeChat.tool.denyReason.cancel",
                                defaultValue: "Cancel"
                            )) {
                                denyReasonExpanded = false
                                denyReason = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Button(action: onStopTurn) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .help(String(
                        localized: "claudeChat.tool.stopTurn.tooltip",
                        defaultValue: "Cancel the current turn entirely — Claude stops thinking and waits for your next message."
                    ))
                    Spacer()
                    Button(String(localized: "claudeChat.tool.deny", defaultValue: "Deny")) {
                        handleDenyTap()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(String(localized: "claudeChat.tool.allow", defaultValue: "Allow"), action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else if showsExitPlanButtons {
                exitPlanActions
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    pending != nil || showsExitPlanButtons
                        ? ChatPalette.orange.opacity(0.6)
                        : palette.borderSubtle(isDark),
                    lineWidth: 1
                )
        )
    }

    /// Three-option footer rendered under an ExitPlanMode tool card when
    /// the SDK auto-allowed the tool (the `claude -p --permission-mode plan`
    /// case). Mirrors Claude Code interactive's
    /// "Yes/auto-accept · Yes/manual · No, keep planning" prompt.
    private var exitPlanActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            Text(String(
                localized: "claudeChat.plan.prompt",
                defaultValue: "Proceed with this plan?"
            ))
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            HStack(spacing: 6) {
                Button(action: {
                    planResolved = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                        Text(String(
                            localized: "claudeChat.plan.keepPlanning",
                            defaultValue: "Keep planning"
                        ))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(
                    localized: "claudeChat.plan.keepPlanning.tooltip",
                    defaultValue: "Dismiss these buttons and type your follow-up to keep refining the plan."
                ))
                Spacer()
                Button(String(
                    localized: "claudeChat.plan.approve",
                    defaultValue: "Approve"
                )) {
                    planResolved = true
                    onExitPlanApprove(false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(
                    localized: "claudeChat.plan.approve.tooltip",
                    defaultValue: "Approve the plan and switch to Normal mode — subsequent edits will still ask for permission."
                ))
                Button(String(
                    localized: "claudeChat.plan.autoAcceptEdits",
                    defaultValue: "Auto-accept edits"
                )) {
                    planResolved = true
                    onExitPlanApprove(true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(String(
                    localized: "claudeChat.plan.autoAcceptEdits.tooltip",
                    defaultValue: "Approve the plan and auto-allow file edits — Bash and other tools still ask first."
                ))
            }
        }
        .padding(.top, 2)
    }

    private func handleDenyTap() {
        if !denyReasonExpanded {
            denyReasonExpanded = true
            return
        }
        let trimmed = denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
        onDeny(trimmed.isEmpty ? nil : trimmed)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 12)
            Text(toolUse.name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let result, toolUse.name != "ExitPlanMode" {
                // Skip the success/error glyph for ExitPlanMode: in
                // headless plan mode the SDK frequently returns an
                // `isError` tool_result (because it can't actually swap
                // permission modes after launch), which would render as a
                // red ✖ and read as "the plan failed". The state we care
                // about — "waiting for the user to click approve" vs.
                // "user already chose" — is already conveyed by the
                // orange badge / approval buttons below.
                Image(systemName: result.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(result.isError ? ChatPalette.red : ChatPalette.green.opacity(0.85))
            }
            if showsExitPlanButtons {
                // Replace the chevron with the orange "needs you" glyph so
                // the card visibly signals that it's waiting on approval
                // — and that the user is not meant to collapse it.
                Text(String(
                    localized: "claudeChat.plan.awaitingBadge",
                    defaultValue: "Awaiting approval"
                ))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ChatPalette.orange)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9))
                    .foregroundColor(ChatPalette.orange)
            } else {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch toolUse.name {
        case "Edit", "MultiEdit", "NotebookEdit":
            return "pencil"
        case "Write":
            return "doc.badge.plus"
        case "Read":
            return "doc.text"
        case "Bash":
            return "terminal"
        case "Glob", "Grep":
            return "magnifyingglass"
        case "WebFetch", "WebSearch":
            return "globe"
        case "Skill":
            return "sparkles"
        case "Task":
            return "person.2"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList",
             "TaskGet", "TaskOutput", "TaskStop":
            return "checklist"
        case "ExitPlanMode":
            return "list.bullet.rectangle"
        default:
            return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private var detail: some View {
        ToolInputDetailView(
            toolName: toolUse.name,
            input: parsedInput,
            rawJSON: toolUse.inputJSON,
            isDark: isDark
        )
    }
}

/// Shared tool-input renderer used by both `ToolUseCard` (post-execution
/// summary) and `ApprovalRequestCard` (pre-execution permission prompt).
/// Picks the right specialised view per tool name and falls back to a
/// pretty-printed JSON dump.
private struct ToolInputDetailView: View {
    let toolName: String
    let input: [String: Any]?
    let rawJSON: String
    let isDark: Bool

    @ViewBuilder
    var body: some View {
        switch toolName {
        case "Edit":
            EditDiffView(input: input, isDark: isDark)
        case "MultiEdit":
            MultiEditDiffView(input: input, isDark: isDark)
        case "Write":
            WriteDiffView(input: input, isDark: isDark)
        case "Bash":
            BashCommandView(input: input, isDark: isDark)
        case "Skill":
            SkillInvocationView(input: input, isDark: isDark)
        case "Task":
            TaskInvocationView(input: input, isDark: isDark)
        case "TodoWrite":
            TodoWriteView(input: input, isDark: isDark)
        case "ExitPlanMode":
            ExitPlanModeView(input: input, isDark: isDark)
        default:
            Text(rawJSON)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SkillInvocationView: View {
    let input: [String: Any]?
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "claudeChat.tool.skill.label", defaultValue: "Skill"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                if let name = input?["skill"] as? String {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            if let args = input?["args"] as? String, !args.isEmpty {
                Text(args)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.codeBg(isDark))
                    )
            }
        }
    }
}

private struct TaskInvocationView: View {
    let input: [String: Any]?
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let agent = input?["subagent_type"] as? String {
                    Text(agent)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(palette.accent(isDark).opacity(0.75)))
                }
                if let desc = input?["description"] as? String, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let prompt = input?["prompt"] as? String, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.codeBg(isDark))
                    )
            }
        }
    }
}

private struct TodoWriteView: View {
    let input: [String: Any]?
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(for: todo))
                        .font(.system(size: 11))
                        .foregroundColor(color(for: todo))
                        .padding(.top, 1)
                    Text(activeForm(of: todo))
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .strikethrough(status(of: todo) == "completed")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var todos: [[String: Any]] {
        (input?["todos"] as? [[String: Any]]) ?? []
    }

    private func status(of todo: [String: Any]) -> String {
        (todo["status"] as? String) ?? "pending"
    }

    private func activeForm(of todo: [String: Any]) -> String {
        if let active = todo["activeForm"] as? String, !active.isEmpty { return active }
        return (todo["content"] as? String) ?? ""
    }

    private func icon(for todo: [String: Any]) -> String {
        switch status(of: todo) {
        case "completed": return "checkmark.square.fill"
        case "in_progress": return "circle.dotted"
        default: return "square"
        }
    }

    private func color(for todo: [String: Any]) -> Color {
        switch status(of: todo) {
        case "completed": return ChatPalette.green
        case "in_progress": return ChatPalette.cyan
        default: return .secondary
        }
    }
}

/// Renders the body of an `ExitPlanMode` tool call (Claude Code's
/// "here's the plan I want to execute" handoff used in plan mode).
/// Without this the panel falls back to the raw-JSON dump, which leaves
/// the user staring at an escaped markdown blob; instead we feed the
/// `plan` field straight to the chat markdown theme so headings, lists
/// and code blocks render the same as a normal assistant message.
private struct ExitPlanModeView: View {
    let input: [String: Any]?
    let isDark: Bool

    @Environment(\.chatPalette) private var palette
    @Environment(\.chatFontSize) private var fontSize

    private var planMarkdown: String {
        (input?["plan"] as? String) ?? ""
    }

    var body: some View {
        let trimmed = planMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10))
                    .foregroundColor(ChatPalette.cyan)
                Text(String(
                    localized: "claudeChat.tool.plan.label",
                    defaultValue: "Proposed plan"
                ))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            }
            if trimmed.isEmpty {
                Text(String(
                    localized: "claudeChat.tool.plan.empty",
                    defaultValue: "(empty plan)"
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            } else {
                Markdown(trimmed)
                    .markdownTheme(cmuxChatMarkdownTheme(isDark: isDark, palette: palette, fontSize: fontSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.cardSubtleBg(isDark))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ChatPalette.cyan.opacity(0.35), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Diff previews

private struct EditDiffView: View {
    let input: [String: Any]?
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = input?["file_path"] as? String {
                filePathRow(path)
            }
            DiffBlock(
                old: input?["old_string"] as? String ?? "",
                new: input?["new_string"] as? String ?? "",
                isDark: isDark
            )
        }
    }
}

private struct MultiEditDiffView: View {
    let input: [String: Any]?
    let isDark: Bool

    /// Cap edits rendered to avoid hundreds of DiffBlocks blowing up
    /// SwiftUI layout. Anything beyond is summarised.
    private static let maxEditsRendered = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = input?["file_path"] as? String {
                filePathRow(path)
            }
            let allEdits = (input?["edits"] as? [[String: Any]]) ?? []
            let renderedEdits = Array(allEdits.prefix(Self.maxEditsRendered))
            ForEach(Array(renderedEdits.enumerated()), id: \.offset) { idx, edit in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit \(idx + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    DiffBlock(
                        old: edit["old_string"] as? String ?? "",
                        new: edit["new_string"] as? String ?? "",
                        isDark: isDark
                    )
                }
            }
            if allEdits.count > Self.maxEditsRendered {
                Text("… [\(allEdits.count - Self.maxEditsRendered) more edits hidden]")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct WriteDiffView: View {
    let input: [String: Any]?
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = input?["file_path"] as? String {
                filePathRow(path)
            }
            DiffBlock(old: "", new: input?["content"] as? String ?? "", isDark: isDark)
        }
    }
}

private struct BashCommandView: View {
    let input: [String: Any]?
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    /// Bash commands are usually short, but a paste-in heredoc could be
    /// massive. Cap before handing to Text to keep layout cheap.
    private static let maxCommandChars = 8_000

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let desc = input?["description"] as? String, !desc.isEmpty {
                Text(String(desc.prefix(500)))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let cmd = input?["command"] as? String {
                let displayed: String = {
                    if cmd.count <= Self.maxCommandChars { return cmd }
                    return String(cmd.prefix(Self.maxCommandChars))
                        + "\n\n… [\(cmd.count - Self.maxCommandChars) more chars truncated]"
                }()
                Text(displayed)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(palette.fg(isDark))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.codeBg(isDark))
                    )
            }
        }
    }
}

@ViewBuilder
private func filePathRow(_ path: String) -> some View {
    HStack(spacing: 4) {
        Image(systemName: "doc")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        Text(path)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Renders an old/new pair as a unified-diff-style preview. Lines from
/// `old` are shown red with a leading `-`; lines from `new` are green with
/// `+`. We don't compute a proper LCS diff — the model already gives us
/// pre-aligned old/new strings, and rendering them as two contiguous blocks
/// is enough for visual review.
private struct DiffBlock: View {
    let old: String
    let new: String
    let isDark: Bool

    @Environment(\.chatPalette) private var palette
    @State private var expandedGaps: Set<UUID> = []

    /// Max characters per individual line — keeps Text layout fast for
    /// files with very long lines (e.g. minified JSON).
    private static let maxLineCharWidth = 4_000
    /// Surrounding context lines kept around each change.
    private static let contextLines = 3

    private var diffLines: [UnifiedDiffLine] {
        UnifiedDiff.compute(old: old, new: new, context: Self.contextLines)
    }

    private var addColor: Color { ChatPalette.green }
    private var removeColor: Color { ChatPalette.red }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diffLines) { line in
                row(for: line)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.codeBg(isDark))
        )
    }

    @ViewBuilder
    private func row(for line: UnifiedDiffLine) -> some View {
        switch line {
        case .context(_, let text, let oldNo, let newNo):
            diffLine(
                marker: " ",
                markerColor: .secondary,
                text: text,
                oldNo: oldNo,
                newNo: newNo,
                rowBackground: .clear
            )
        case .removed(_, let text, let oldNo):
            diffLine(
                marker: "-",
                markerColor: removeColor,
                text: text,
                oldNo: oldNo,
                newNo: nil,
                rowBackground: removeColor.opacity(0.16)
            )
        case .added(_, let text, let newNo):
            diffLine(
                marker: "+",
                markerColor: addColor,
                text: text,
                oldNo: nil,
                newNo: newNo,
                rowBackground: addColor.opacity(0.16)
            )
        case .gap(let id, let hiddenLines):
            if expandedGaps.contains(id) {
                ForEach(hiddenLines) { hidden in
                    diffLine(
                        marker: " ",
                        markerColor: .secondary,
                        text: hidden.text,
                        oldNo: hidden.oldLineNo,
                        newNo: hidden.newLineNo,
                        rowBackground: .clear
                    )
                }
            } else {
                gapRow(id: id, count: hiddenLines.count)
            }
        }
    }

    private func diffLine(
        marker: String,
        markerColor: Color,
        text: String,
        oldNo: Int?,
        newNo: Int?,
        rowBackground: Color
    ) -> some View {
        let truncated = String(text.prefix(Self.maxLineCharWidth))
        return HStack(alignment: .top, spacing: 6) {
            Text(oldNo.map { String($0) } ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 30, alignment: .trailing)
            Text(newNo.map { String($0) } ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 30, alignment: .trailing)
            Text(marker)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(markerColor)
                .frame(width: 10, alignment: .leading)
            Text(truncated.isEmpty ? " " : truncated)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(rowBackground)
    }

    private func gapRow(id: UUID, count: Int) -> some View {
        Button {
            expandedGaps.insert(id)
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .center)
                Text(String(
                    localized: "claudeChat.diff.unmodifiedLines",
                    defaultValue: "\(count) unmodified lines"
                ))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardSubtleBg(isDark))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(
            localized: "claudeChat.diff.unmodifiedLines.tooltip",
            defaultValue: "Click to reveal unchanged surrounding lines"
        ))
    }
}

private struct ApprovalRequestCard: View {
    let request: ChatApprovalRequest
    let isDark: Bool
    let onApprove: () -> Void
    let onApproveAlways: () -> Void
    /// Deny with an optional free-text reason that gets surfaced to
    /// Claude as part of the tool_result. With a reason Claude usually
    /// changes course (matches Claude Code's TUI prompt-on-deny UX);
    /// without one (`nil`) Claude just sees a bare denial.
    let onDeny: (String?) -> Void
    /// Hard-stop the current turn (mirrors the trash/stop button on the
    /// composer). Useful when Claude is in a loop the user wants to
    /// abort rather than redirect.
    let onStopTurn: () -> Void

    @Environment(\.chatPalette) private var palette
    @State private var expanded = true
    /// Inline "tell Claude what to do instead" composer. Becomes visible
    /// when the user clicks Deny once; clicking again with a non-empty
    /// reason sends it. A second click with an empty reason sends a
    /// bare deny (legacy behavior).
    @State private var denyReasonExpanded = false
    @State private var denyReason: String = ""

    /// Re-parse the inputJSON we received from the MCP server. The server
    /// pretty-prints it for display; here we want the structured form so we
    /// can route to the right detail view (Edit diff, Bash command, etc.).
    private var parsedInput: [String: Any]? {
        guard let data = request.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundColor(ChatPalette.orange)
                Text(String(localized: "claudeChat.approval.title", defaultValue: "Allow tool?"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(request.toolName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Button(action: { expanded.toggle() }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            if expanded, !request.inputJSON.isEmpty {
                ToolInputDetailView(
                    toolName: request.toolName,
                    input: parsedInput,
                    rawJSON: request.inputJSON,
                    isDark: isDark
                )
            }
            if denyReasonExpanded {
                denyReasonRow
            }
            HStack(spacing: 8) {
                Button(action: onStopTurn) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                        Text(String(
                            localized: "claudeChat.tool.stopTurn",
                            defaultValue: "Stop turn"
                        ))
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help(String(
                    localized: "claudeChat.tool.stopTurn.tooltip",
                    defaultValue: "Cancel the current turn entirely — Claude stops thinking and waits for your next message."
                ))
                Spacer()
                Button(String(localized: "claudeChat.tool.deny", defaultValue: "Deny"), action: handleDenyTap)
                    .buttonStyle(.bordered)
                Button(action: onApproveAlways) {
                    Text(String(
                        localized: "claudeChat.tool.allowAlways",
                        defaultValue: "Allow always"
                    ))
                }
                .buttonStyle(.bordered)
                .help(String(
                    localized: "claudeChat.tool.allowAlways.tooltip",
                    defaultValue: "Allow this and any future call to the same tool in this chat without asking again."
                ))
                Button(String(localized: "claudeChat.tool.allow", defaultValue: "Allow"), action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChatPalette.orange.opacity(0.5), lineWidth: 1)
        )
    }

    /// Inline TextField that mirrors Claude Code's "tell Claude what to
    /// do instead" prompt: appears after the first Deny click, and the
    /// next Deny click sends the typed reason back to Claude as part of
    /// the tool_result.
    private var denyReasonRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(
                localized: "claudeChat.tool.denyReason.label",
                defaultValue: "Tell Claude what to do instead (optional):"
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            HStack(spacing: 6) {
                TextField(
                    String(
                        localized: "claudeChat.tool.denyReason.placeholder",
                        defaultValue: "e.g. \"use a different approach\" or leave empty"
                    ),
                    text: $denyReason
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    let trimmed = denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
                    onDeny(trimmed.isEmpty ? nil : trimmed)
                }
                Button(String(
                    localized: "claudeChat.tool.denyReason.cancel",
                    defaultValue: "Cancel"
                )) {
                    denyReasonExpanded = false
                    denyReason = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// First click expands the reason composer (replicates Claude Code's
    /// inline "what should I do instead?" prompt). Second click either
    /// sends the reason (if typed) or falls back to a bare deny.
    private func handleDenyTap() {
        if !denyReasonExpanded {
            denyReasonExpanded = true
            return
        }
        let trimmed = denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
        onDeny(trimmed.isEmpty ? nil : trimmed)
    }
}

private struct UserQuestionCard: View {
    let request: ChatUserQuestionRequest
    let isDark: Bool
    let onAnswer: ([[String]]) -> Void

    @Environment(\.chatPalette) private var palette
    /// One Set per sub-question, indexed by sub-question position.
    @State private var selectedByIndex: [Set<String>] = []
    /// Free-text answer for the "Other" row, one per sub-question.
    /// Selecting Other without typing anything is treated as no answer
    /// (the Submit button stays disabled for that sub-question).
    @State private var otherTextByIndex: [String] = []

    /// Sentinel label used in `selectedByIndex` to represent the "Other"
    /// row. Picked to be highly unlikely to collide with a real option
    /// label coming from Claude. Replaced by the typed text in
    /// `submitAll()` before the answers go back over MCP.
    private static let otherSentinel = "__cmux_other__"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, sub in
                subQuestionView(index: index, sub: sub)
            }
            HStack {
                Spacer()
                Button(String(localized: "claudeChat.question.submit", defaultValue: "Submit")) {
                    submitAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allAnswered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChatPalette.cyan.opacity(0.5), lineWidth: 1)
        )
        .onAppear {
            if selectedByIndex.count != request.questions.count {
                selectedByIndex = Array(repeating: Set<String>(), count: request.questions.count)
            }
            if otherTextByIndex.count != request.questions.count {
                otherTextByIndex = Array(repeating: "", count: request.questions.count)
            }
        }
    }

    @ViewBuilder
    private func subQuestionView(index: Int, sub: ChatUserQuestionRequest.SubQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(ChatPalette.cyan)
                if let header = sub.header, !header.isEmpty {
                    Text(header)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(ChatPalette.cyan.opacity(0.6)))
                }
                Text(sub.question)
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sub.options) { option in
                    optionButton(index: index, sub: sub, option: option)
                }
                otherRow(index: index, sub: sub)
            }
        }
    }

    /// Trailing free-text row that mirrors Claude Code's "Other" option.
    /// Selecting the row activates the inline TextField; typing into it
    /// auto-selects the row. In single-select questions, picking Other
    /// (or typing) clears the other selections. The typed text is what
    /// gets sent back to Claude — the sentinel label never leaves this
    /// view.
    @ViewBuilder
    private func otherRow(index: Int, sub: ChatUserQuestionRequest.SubQuestion) -> some View {
        let isSelected = selectedByIndex.indices.contains(index)
            && selectedByIndex[index].contains(Self.otherSentinel)
        let otherTextBinding = Binding<String>(
            get: {
                otherTextByIndex.indices.contains(index)
                    ? otherTextByIndex[index] : ""
            },
            set: { newValue in
                guard otherTextByIndex.indices.contains(index) else { return }
                otherTextByIndex[index] = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard selectedByIndex.indices.contains(index) else { return }
                if trimmed.isEmpty {
                    selectedByIndex[index].remove(Self.otherSentinel)
                } else {
                    // Typing implicitly selects the Other row. In
                    // single-select mode it also clears any previous
                    // selection so the radio behavior stays consistent.
                    if !sub.multiSelect {
                        selectedByIndex[index] = []
                    }
                    selectedByIndex[index].insert(Self.otherSentinel)
                }
            }
        )
        HStack(alignment: .top, spacing: 8) {
            Button {
                toggle(index: index, sub: sub, label: Self.otherSentinel)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: optionIcon(sub: sub, isSelected: isSelected))
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .padding(.top, 2)
                    Text(String(
                        localized: "claudeChat.question.other",
                        defaultValue: "Other"
                    ))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.top, 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            TextField(
                String(
                    localized: "claudeChat.question.other.placeholder",
                    defaultValue: "Type your own answer…"
                ),
                text: otherTextBinding
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 12))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? ChatPalette.cyan.opacity(0.18) : Color.clear)
        )
    }

    @ViewBuilder
    private func optionButton(
        index: Int,
        sub: ChatUserQuestionRequest.SubQuestion,
        option: ChatUserQuestionRequest.Option
    ) -> some View {
        let isSelected = selectedByIndex.indices.contains(index)
            && selectedByIndex[index].contains(option.label)
        Button {
            toggle(index: index, sub: sub, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: optionIcon(sub: sub, isSelected: isSelected))
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                        ? ChatPalette.cyan.opacity(0.18)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(index: Int, sub: ChatUserQuestionRequest.SubQuestion, label: String) {
        guard selectedByIndex.indices.contains(index) else { return }
        if sub.multiSelect {
            if selectedByIndex[index].contains(label) {
                selectedByIndex[index].remove(label)
            } else {
                selectedByIndex[index].insert(label)
            }
        } else {
            selectedByIndex[index] = [label]
        }
    }

    private func optionIcon(sub: ChatUserQuestionRequest.SubQuestion, isSelected: Bool) -> String {
        if sub.multiSelect {
            return isSelected ? "checkmark.square.fill" : "square"
        } else {
            return isSelected ? "largecircle.fill.circle" : "circle"
        }
    }

    private var allAnswered: Bool {
        guard selectedByIndex.count == request.questions.count else { return false }
        for (index, selection) in selectedByIndex.enumerated() {
            if selection.isEmpty { return false }
            // "Other" alone is only a real answer if the user typed
            // something. With other concrete options also selected, the
            // empty Other gets silently dropped at submit time.
            if selection == [Self.otherSentinel] {
                let typed = otherTextByIndex.indices.contains(index)
                    ? otherTextByIndex[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                if typed.isEmpty { return false }
            }
        }
        return true
    }

    private func submitAll() {
        let answers: [[String]] = selectedByIndex.enumerated().map { index, selection in
            var labels = Array(selection)
            if let otherIdx = labels.firstIndex(of: Self.otherSentinel) {
                let typed = otherTextByIndex.indices.contains(index)
                    ? otherTextByIndex[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                if typed.isEmpty {
                    labels.remove(at: otherIdx)
                } else {
                    labels[otherIdx] = typed
                }
            }
            return labels
        }
        onAnswer(answers)
    }
}

private struct ToolResultCard: View {
    let result: ChatMessageBlock.ToolResult
    let isDark: Bool
    /// When true, the card is rendered inline inside another card
    /// (e.g. the matching `ToolUseCard`) and skips its own background.
    var embedded: Bool = false

    @Environment(\.chatPalette) private var palette
    @State private var expanded = false

    /// Hard caps applied before handing strings to SwiftUI's Text layout.
    /// A single Text view with multiple MB of content blocks the main
    /// thread for seconds — the cause of the May 8 hang we just shipped
    /// a fix for.
    private static let firstLineCharLimit = 500
    private static let expandedCharLimit = 80_000

    private var trimmed: String {
        result.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var firstLine: String {
        // Take only the first 4KB to find the first newline; if the whole
        // content is one giant line we still cap it.
        let head = trimmed.prefix(4_000)
        let candidate: String
        if let line = head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            candidate = String(line)
        } else {
            candidate = String(head)
        }
        return String(candidate.prefix(Self.firstLineCharLimit))
    }

    private var hasMore: Bool {
        trimmed.contains("\n") || trimmed.count > firstLine.count
    }

    private var lineCount: Int {
        if trimmed.isEmpty { return 0 }
        // Counting `\n` is O(n) and good enough; avoid `components(separatedBy:)`
        // which materialises the whole array.
        var count = 1
        for ch in trimmed where ch == "\n" { count += 1 }
        return count
    }

    private var expandedDisplay: String {
        if trimmed.count <= Self.expandedCharLimit { return trimmed }
        let truncated = String(trimmed.prefix(Self.expandedCharLimit))
        let suffix = "\n\n… [\(trimmed.count - Self.expandedCharLimit) more chars truncated]"
        return truncated + suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: result.isError ? "xmark.octagon" : "checkmark.circle")
                    .foregroundColor(result.isError ? ChatPalette.red : ChatPalette.green)
                    .font(.system(size: 11))
                Text(expanded || !hasMore ? firstLine : firstLine.isEmpty ? "(empty)" : firstLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if hasMore {
                    Button(action: { expanded.toggle() }) {
                        HStack(spacing: 2) {
                            if !expanded {
                                Text("+\(lineCount - 1)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if expanded, hasMore {
                Text(expandedDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
        .padding(embedded ? 0 : 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(embedded
                    ? Color.clear
                    : palette.resultBg(isDark))
        )
    }
}

// MARK: - Theme

/// Process-wide cache for pre-parsed `MarkdownContent` instances keyed
/// by the raw markdown text. `MarkdownUI.Markdown(text:)` parses the
/// string to a `MarkdownContent` AST on every render — for assistant
/// bubbles in a long chat this parse runs again every time LazyVStack
/// materialises an off-screen bubble back into the viewport during
/// scroll (Instruments confirmed multiple CoreAnimation commits over
/// 500 ms here, the dominant scroll-lag source).
///
/// By caching `MarkdownContent(text)` per text and feeding it to
/// `Markdown(_ content:)`, the parse cost collapses to once per unique
/// text. Layout still runs on first materialisation (text shaping
/// can't be skipped), but the AST construction goes away. Crucially
/// this preserves ALL MarkdownUI features (tables, code blocks with
/// syntax highlighting, blockquotes) — unlike substituting `Text(
/// AttributedString(markdown:))`, which would lose them.
///
/// `MarkdownContent` is a value type with `Equatable` conformance, so
/// we box it for `NSCache`. `countLimit` keeps memory bounded (256
/// entries ≈ 256 distinct assistant bubble bodies retained at most).
final class ChatMarkdownContentCache {
    static let shared = ChatMarkdownContentCache()

    private final class Box { let content: MarkdownContent; init(_ c: MarkdownContent) { self.content = c } }
    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 256
    }

    func content(for text: String) -> MarkdownContent {
        let key = text as NSString
        if let box = cache.object(forKey: key) {
            return box.content
        }
        lock.lock()
        defer { lock.unlock() }
        if let box = cache.object(forKey: key) {
            return box.content
        }
        let content = MarkdownContent(text)
        cache.setObject(Box(content), forKey: key)
        return content
    }
}

/// Detector + cache para el "hybrid path" del assistant bubble.
///
/// Profiling con Instruments mostró que el coste de scroll en bubbles
/// del asistente lo concentran las TABLAS y los fenced code blocks de
/// MarkdownUI (Grid + anchorPreference + GeometryReader para tablas;
/// Splash syntax highlighting para code blocks). El resto de markdown
/// común en chats (prosa con bold/italic/inline-code/links/listas/
/// headers) lo renderiza CoreText/AppKit con `Text(AttributedString(
/// markdown:))` de forma órdenes de magnitud más rápida, sin árbol de
/// subviews ni preferences-machinery.
///
/// `ChatMarkdownComplexityProbe` clasifica cada texto en O(n) una sola
/// vez (cacheado) en uno de dos buckets:
///
/// - `.simple`: no contiene tabla ni fenced code → renderiza vía
///   `Text(AttributedString(markdown:, options: .full))` (cheap path).
/// - `.heavy`: contiene tabla o fenced code → cae al path actual de
///   MarkdownUI con `cmuxChatMarkdownTheme` (preserva tabla + syntax
///   highlight + blockquote custom).
enum ChatMarkdownComplexity: Sendable {
    case simple
    case heavy
}

final class ChatMarkdownComplexityProbe {
    static let shared = ChatMarkdownComplexityProbe()

    private let cache = NSCache<NSString, NSNumber>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 512
    }

    func classify(_ text: String) -> ChatMarkdownComplexity {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached.intValue == 0 ? .simple : .heavy
        }
        let result: ChatMarkdownComplexity = Self.detect(text)
        lock.lock()
        cache.setObject(NSNumber(value: result == .simple ? 0 : 1), forKey: key)
        lock.unlock()
        return result
    }

    private static func detect(_ text: String) -> ChatMarkdownComplexity {
        // Fenced code block — three backticks on a line.
        if text.contains("```") { return .heavy }
        // GFM table — header row + separator row pattern. Cheap regex.
        if text.range(
            of: #"(?m)^\s*\|.*\|\s*$\n\s*\|[\s\-:|]+\|\s*$"#,
            options: .regularExpression
        ) != nil {
            return .heavy
        }
        // ATX headers (`# Title`, `## Sub`) — the simple `Text(Attributed
        // String)` path with `.inlineOnlyPreservingWhitespace` would
        // print the literal `#`; humans expect visual hierarchy here.
        if text.range(
            of: #"(?m)^\s{0,3}#{1,6}\s+\S"#,
            options: .regularExpression
        ) != nil {
            return .heavy
        }
        // Unordered list (`- item`, `* item`, `+ item`) — needs proper
        // bullet rendering and indent that MarkdownUI provides.
        if text.range(
            of: #"(?m)^\s{0,3}[-*+]\s+\S"#,
            options: .regularExpression
        ) != nil {
            return .heavy
        }
        // Ordered list (`1. item`, `12) item`).
        if text.range(
            of: #"(?m)^\s{0,3}\d+[.)]\s+\S"#,
            options: .regularExpression
        ) != nil {
            return .heavy
        }
        // Blockquote (`> quoted`) — left-bar + indent rendering.
        if text.range(
            of: #"(?m)^\s{0,3}>\s"#,
            options: .regularExpression
        ) != nil {
            return .heavy
        }
        return .simple
    }
}

/// Cache de `AttributedString` para el simple-prose path. Construir un
/// `AttributedString(markdown:)` no es gratis (parsea + crea runs); con
/// 60 bubbles visibles en LazyVStack se reparsearía en cada re-render
/// si no lo cacheamos.
///
/// Key: `text` literal. Value: NSAttributedString-wrapped (`AttributedString`
/// es struct; lo metemos en un `Box` para `NSCache`).
final class ChatSimpleMarkdownCache {
    static let shared = ChatSimpleMarkdownCache()

    private final class Box { let attr: AttributedString; init(_ a: AttributedString) { self.attr = a } }
    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 512
    }

    func attributed(for text: String) -> AttributedString {
        let key = text as NSString
        if let box = cache.object(forKey: key) {
            return box.attr
        }
        lock.lock()
        defer { lock.unlock() }
        if let box = cache.object(forKey: key) {
            return box.attr
        }
        // `.inlineOnlyPreservingWhitespace` parses inline syntax (bold,
        // italic, inline code, links) but treats block-level tokens as
        // literal text AND keeps `\n` / `\n\n` as real newlines. With
        // `.full` SwiftUI collapses block-level intents (paragraphs,
        // lists, headers) into a single run, which renders the whole
        // message as one wall-of-text glob. The complexity probe
        // promotes any text containing real headers/lists/blockquotes
        // to the heavy MarkdownUI path, so reaching this branch means
        // prose with at most inline emphasis — exactly where preserving
        // whitespace gives the right visual structure.
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let attr = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        cache.setObject(Box(attr), forKey: key)
        return attr
    }
}

/// Pre-warm view for MarkdownUI's generic-type metadata.
///
/// Instruments revealed that the visible microhangs during scroll
/// (~250 ms, ~3 in 30 s) bottom out in
/// `__swift_instantiateGenericMetadata` / `_swift_getGenericMetadata`
/// / `AG::data::zone::alloc_slow` — i.e. the Swift runtime building
/// per-type metadata for every unique `ModifiedContent<…, …>` /
/// `BlockSequence<…, …>` instantiation that MarkdownUI synthesises
/// the FIRST time a given combination of block types is rendered.
/// Once cached (process-wide), subsequent materialisations of the
/// same combinations are essentially free.
///
/// Mounting this view as a zero-frame, fully-transparent background
/// of the chat panel forces SwiftUI to render a Markdown document
/// that exercises every block type the cache cares about (headers,
/// lists, blockquote, inline code, fenced code, table, link, bold,
/// italic) on the very first appearance of the chat panel. After
/// that render, scrolling the real chat doesn't pay the metadata-
/// instantiation cost the first time each block-type combo appears.
///
/// The rendered text is never visible (opacity 0, 1x1 frame, hit-
/// testing off), so it doesn't affect layout or interaction.
private struct ChatMarkdownPrewarmView: View {
    let isDark: Bool
    let palette: ChatPalette

    @Environment(\.chatFontSize) private var fontSize

    /// Touches every MarkdownUI block type we care about. The exact
    /// content is irrelevant — only the AST shape (block kinds, list
    /// nesting, table presence) matters for metadata instantiation.
    private static let prewarmContent = """
        # H1
        ## H2
        ### H3

        Plain paragraph with **bold**, *italic*, `inline code`, and a [link](https://example.com).

        - bullet one
        - bullet two
            - nested
        - bullet three

        1. ordered one
        2. ordered two

        > quote

        ```swift
        let x = 1
        ```

        | A | B |
        |---|---|
        | 1 | 2 |
        """

    var body: some View {
        Markdown(ChatMarkdownContentCache.shared.content(for: Self.prewarmContent))
            .markdownTheme(cmuxChatMarkdownTheme(isDark: isDark, palette: palette, fontSize: fontSize))
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Process-wide cache for `cmuxChatMarkdownTheme`. The theme is purely
/// derived from `(isDark, palette.terminalBg, palette.terminalFg)` —
/// reconstructing it inside every `TextBlockRow.body` evaluation showed
/// up as a hot allocator during streaming. Cache is tiny (the user's
/// terminal palette doesn't change often) and the wrapper class is
/// needed because `MarkdownUI.Theme` is a struct.
private final class ChatMarkdownThemeCache {
    static let shared = ChatMarkdownThemeCache()

    private final class Box { let theme: Theme; init(_ t: Theme) { self.theme = t } }
    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 16
    }

    func theme(isDark: Bool, palette: ChatPalette, fontSize: CGFloat) -> Theme {
        let key = Self.cacheKey(isDark: isDark, palette: palette, fontSize: fontSize) as NSString
        if let box = cache.object(forKey: key) {
            return box.theme
        }
        lock.lock()
        defer { lock.unlock() }
        if let box = cache.object(forKey: key) {
            return box.theme
        }
        let theme = ChatMarkdownThemeCache.build(isDark: isDark, palette: palette, fontSize: fontSize)
        cache.setObject(Box(theme), forKey: key)
        return theme
    }

    private static func cacheKey(isDark: Bool, palette: ChatPalette, fontSize: CGFloat) -> String {
        "\(isDark ? "d" : "l")|\(Self.rgbHex(palette.terminalBg))|\(Self.rgbHex(palette.terminalFg))|\(Int(fontSize.rounded()))"
    }

    private static func rgbHex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    private static func build(isDark: Bool, palette: ChatPalette, fontSize: CGFloat) -> Theme {
        cmuxChatMarkdownThemeUncached(isDark: isDark, palette: palette, fontSize: fontSize)
    }
}

/// Chat-specific markdown theme — public entry point. Returns a cached
/// instance keyed by `(isDark, palette terminal colors)` so repeated
/// `TextBlockRow.body` evaluations during streaming don't reconstruct
/// the closure-heavy `Theme` from scratch.
private func cmuxChatMarkdownTheme(isDark: Bool, palette: ChatPalette, fontSize: CGFloat) -> Theme {
    ChatMarkdownThemeCache.shared.theme(isDark: isDark, palette: palette, fontSize: fontSize)
}

/// Actual builder. Kept as a separate function so the cache wrapper
/// stays tiny and the theme definition reads top-to-bottom unchanged.
/// Mirrors `cmuxMarkdownTheme` from `MarkdownPanelView` but with smaller
/// margins and theme-aware colours. `palette` carries the user's
/// terminal background/foreground so inline code highlight stays
/// legible across themes.
private func cmuxChatMarkdownThemeUncached(isDark: Bool, palette: ChatPalette, fontSize: CGFloat) -> Theme {
    Theme()
        .text {
            ForegroundColor(palette.fg(isDark))
            FontSize(fontSize)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(max(9, fontSize - 1))
            // IntelliJ-Darcula-style: inline code uses the same blue as
            // identifiers/keywords in the editor. Avoid the prior purple
            // because it clashed with the rest of the palette. A brighter
            // shade than `ChatPalette.blue` to read clearly against the
            // terminal-bg-derived inline-code background.
            ForegroundColor(isDark ? Color(red: 0x6F/255.0, green: 0xB1/255.0, blue: 0xFF/255.0) : Color(red: 0.18, green: 0.42, blue: 0.78))
            BackgroundColor(palette.codeBg(isDark))
        }
        .codeBlock { configuration in
            ChatCopyableCodeBlock(
                configuration: configuration,
                isDark: isDark,
                palette: palette,
                fontSize: fontSize
            )
        }
        .link {
            ForegroundColor(isDark ? ChatPalette.cyan : Color.accentColor)
        }
        .strong {
            FontWeight(.semibold)
        }
        .paragraph { configuration in
            configuration.label.markdownMargin(top: 2, bottom: 4)
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: 2, bottom: 2)
        }
}

// MARK: - Chat input

/// Context about the caret captured at the moment an arrow key is
/// pressed. The chat composer uses it to decide whether ↑/↓ should
/// step through the message history (only at the edge of the document,
/// mirroring zsh/bash) or fall through to the NSTextView default
/// caret movement.
struct ChatInputArrowContext {
    var isEmpty: Bool
    var isAtFirstLine: Bool
    var isAtLastLine: Bool
}

/// Multi-line text input with chat semantics:
/// - Enter (Return alone) submits the message.
/// - Shift+Enter inserts a newline.
/// - Escape calls `onCancel` (used to stop an in-flight turn).
/// - Ctrl+U kills from the caret to the start of the document
///   (terminal-style `unix-line-discard`).
/// - Shift+Tab cycles the permission mode via `onShiftTab`.
/// - Auto-grows up to its frame height with internal scrolling.
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isDark: Bool
    let textColor: NSColor
    /// Bumped externally to demand keyboard focus (e.g. after the user
    /// drops an attachment, so the next keystroke goes to the input even
    /// if the panel was sharing a window with another focused pane).
    var focusToken: Int = 0
    /// Reports the intrinsic content height (text + insets) so the host
    /// can grow the composer until its own ceiling. Once the host caps the
    /// frame, the NSTextView scrolls internally.
    @Binding var measuredHeight: CGFloat
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Fired when the underlying NSTextView takes first-responder, so the
    /// host can update bonsplit's "focused pane" bookkeeping. Without this,
    /// clicking into the chat input does not unstick a stale focus that
    /// still points at a sibling terminal pane, and keystrokes leak there.
    var onBecomeFirstResponder: (() -> Void)? = nil
    /// Key intercepts for popup-driven UI (slash-command dropdown) and
    /// for terminal-style affordances (history, mode cycling). Each
    /// returns `true` to swallow the key, `false` to fall through to
    /// NSTextView. The arrow handlers receive the caret context so the
    /// host can scope history navigation to the document edges.
    var onArrowUp: ((ChatInputArrowContext) -> Bool)? = nil
    var onArrowDown: ((ChatInputArrowContext) -> Bool)? = nil
    var onTabKey: (() -> Bool)? = nil
    var onShiftTab: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        let chatTextView = ChatInputNSTextView()
        chatTextView.frame = textView.frame
        chatTextView.autoresizingMask = textView.autoresizingMask
        chatTextView.textContainerInset = NSSize(width: 0, height: 4)
        chatTextView.isRichText = false
        chatTextView.allowsUndo = true
        chatTextView.usesFontPanel = false
        chatTextView.isAutomaticDataDetectionEnabled = false
        chatTextView.isAutomaticLinkDetectionEnabled = false
        chatTextView.isAutomaticTextReplacementEnabled = false
        chatTextView.isAutomaticSpellingCorrectionEnabled = false
        chatTextView.smartInsertDeleteEnabled = false
        chatTextView.font = NSFont.systemFont(ofSize: 13)
        chatTextView.textColor = isDark ? textColor : NSColor.labelColor
        chatTextView.insertionPointColor = isDark ? textColor : NSColor.labelColor
        chatTextView.delegate = context.coordinator
        chatTextView.onSubmit = onSubmit
        chatTextView.onCancel = onCancel
        chatTextView.onBecomeFirstResponder = onBecomeFirstResponder
        chatTextView.onArrowUp = onArrowUp
        chatTextView.onArrowDown = onArrowDown
        chatTextView.onTabKey = onTabKey
        chatTextView.onShiftTab = onShiftTab
        chatTextView.string = text
        chatTextView.placeholderString = placeholder

        scrollView.documentView = chatTextView
        // Measure once the scrollView has been sized by SwiftUI so the
        // text container's width is non-zero and `usedRect` is accurate.
        DispatchQueue.main.async { [weak chatTextView, weak scrollView] in
            guard let tv = chatTextView, let sv = scrollView else { return }
            Self.reportHeight(textView: tv, scrollView: sv, into: context.coordinator)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let chatTextView = nsView.documentView as? ChatInputNSTextView else { return }
        var textDidChange = false
        if chatTextView.string != text {
            chatTextView.string = text
            chatTextView.placeholderString = placeholder
            textDidChange = true
        }
        chatTextView.placeholderString = placeholder
        chatTextView.textColor = isDark ? textColor : NSColor.labelColor
        chatTextView.insertionPointColor = isDark ? textColor : NSColor.labelColor
        chatTextView.onSubmit = onSubmit
        chatTextView.onCancel = onCancel
        chatTextView.onBecomeFirstResponder = onBecomeFirstResponder
        chatTextView.onArrowUp = onArrowUp
        chatTextView.onArrowDown = onArrowDown
        chatTextView.onTabKey = onTabKey
        chatTextView.onShiftTab = onShiftTab
        // Honor an external focus request — bump the token via @State and
        // we steal first-responder on the next render. Mark the
        // upcoming `becomeFirstResponder` as programmatic so it does
        // not feed back into `onRequestPanelFocus()` and re-trigger
        // `Workspace.focusPanel(panel)` — that loop would otherwise
        // alternate the two chat panels' tokens forever when both
        // share a pane (see `suppressNextBecomeFirstResponderNotification`).
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                chatTextView.suppressNextBecomeFirstResponderNotification = true
                chatTextView.window?.makeFirstResponder(chatTextView)
            }
        }
        // Re-measure only when something that affects intrinsic height
        // changed — either the text or the available width. SwiftUI
        // re-evaluates this view on every parent body invalidation
        // (~20 Hz during streaming), and layoutManager.usedRect/
        // ensureLayout on long composers is non-trivial.
        let currentWidth = nsView.contentSize.width
        let widthChanged = abs(currentWidth - context.coordinator.lastMeasuredWidth) > 0.5
        if textDidChange || widthChanged {
            DispatchQueue.main.async { [weak chatTextView, weak nsView] in
                guard let tv = chatTextView, let sv = nsView else { return }
                Self.reportHeight(textView: tv, scrollView: sv, into: context.coordinator)
                if textDidChange {
                    // Scroll the caret back into view in case the text was
                    // shortened and the document is no longer scrolled past
                    // the visible area.
                    tv.scrollRangeToVisible(NSRange(location: tv.string.count, length: 0))
                }
            }
        }
    }

    /// Compute the height the NSTextView wants given its current text and
    /// container width, then publish it through the binding (with a small
    /// tolerance so we don't churn SwiftUI on sub-pixel deltas).
    fileprivate static func reportHeight(
        textView: NSTextView,
        scrollView: NSScrollView,
        into coordinator: Coordinator
    ) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let containerWidth = max(scrollView.contentSize.width, 1)
        if abs(textContainer.size.width - containerWidth) > 0.5 {
            textContainer.size = NSSize(
                width: containerWidth,
                height: .greatestFiniteMagnitude
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = ceil(used.height + textView.textContainerInset.height * 2)
        if abs(coordinator.parent.measuredHeight - height) > 0.5 {
            coordinator.parent.measuredHeight = height
        }
        coordinator.lastMeasuredWidth = containerWidth
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        var lastFocusToken: Int = 0
        /// Cached scroll-view content width at the last time we ran the
        /// layout-manager pass. `updateNSView` consults this to skip
        /// `reportHeight` when neither text nor width changed — the
        /// common case during streaming when the parent body invalidates
        /// for unrelated reasons.
        var lastMeasuredWidth: CGFloat = -1

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            if let scrollView = textView.enclosingScrollView {
                ChatInputTextView.reportHeight(
                    textView: textView,
                    scrollView: scrollView,
                    into: self
                )
            }
        }
    }
}

final class ChatInputNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fires when this view takes first-responder. cmux uses it to mark
    /// the surrounding pane as the focused pane in bonsplit, preventing
    /// keystrokes from leaking to a sibling terminal that bonsplit still
    /// remembers as focused.
    var onBecomeFirstResponder: (() -> Void)?
    /// When set, the next `becomeFirstResponder` accepted by AppKit
    /// does NOT fire `onBecomeFirstResponder`. `updateNSView` flips
    /// this on right before a programmatic `makeFirstResponder(...)`
    /// triggered by a `focusToken` bump.
    ///
    /// Why: `Workspace.focusPanel(panel)` ends up calling
    /// `panel.focus()` which bumps `inputFocusRequestToken`. The view
    /// observes the bump and asks the window to make the input view
    /// first responder. AppKit calls `becomeFirstResponder()` here,
    /// which previously fed back into `onRequestPanelFocus()` →
    /// `Workspace.focusPanel(panel)` again, creating an infinite
    /// focus-fight when two Claude Chat panels share a pane (AppKit
    /// ping-pongs the responder between the two off-screen
    /// `ChatInputNSTextView` instances that bonsplit keeps mounted).
    /// User clicks/keystrokes are unaffected — they don't go through
    /// `makeFirstResponder(_:)`, so the flag stays false.
    var suppressNextBecomeFirstResponderNotification: Bool = false
    /// Optional intercepts for popup-driven UI (e.g. slash-command
    /// dropdown) and terminal-style affordances. Each handler returns
    /// `true` to swallow the key, `false` to fall through to the normal
    /// NSTextView behavior. Arrow handlers receive the caret context so
    /// the host can scope history navigation to the document edges.
    var onArrowUp: ((ChatInputArrowContext) -> Bool)?
    var onArrowDown: ((ChatInputArrowContext) -> Bool)?
    var onTabKey: (() -> Bool)?
    /// Shift+Tab cycles the permission mode. Separate from `onTabKey`
    /// because Tab alone is used for slash-command completion.
    var onShiftTab: (() -> Bool)?
    var placeholderString: String = "" {
        didSet {
            needsDisplay = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            if suppressNextBecomeFirstResponderNotification {
                suppressNextBecomeFirstResponderNotification = false
            } else {
                onBecomeFirstResponder?()
            }
        }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        // Escape: cancel.
        if event.keyCode == 53 {  // 53 = escape
            onCancel?()
            return
        }
        // Ctrl+U: terminal-style "kill to beginning of input" — delete
        // everything from the start of the document up to the caret.
        // Self-contained (no host callback) since it never modifies model
        // state beyond the editing buffer; undo is wired via
        // shouldChangeText/didChangeText so ⌘Z restores it.
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "u" {
            killToBeginningOfDocument()
            return
        }
        // Up/Down arrows: hosts get the caret context so they can choose
        // to intercept only at the document edges (history navigation)
        // and otherwise let the NSTextView default caret movement apply.
        // Use keyCode rather than chars so non-US layouts behave.
        let arrowContext = currentArrowContext()
        if event.keyCode == 126, let onArrowUp, onArrowUp(arrowContext) { return }    // up
        if event.keyCode == 125, let onArrowDown, onArrowDown(arrowContext) { return } // down
        // Tab handling: Shift+Tab cycles the permission mode (a chat-
        // wide action); Tab alone is reserved for slash-command prefix
        // completion when the popup is up, otherwise default behavior.
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                if let onShiftTab, onShiftTab() { return }
            } else if let onTabKey, onTabKey() {
                return
            }
        }
        // Return: submit (unless Shift+Return, which inserts a newline).
        let isReturn = event.charactersIgnoringModifiers == "\r" || event.keyCode == 36
        if isReturn {
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Snapshot of where the caret sits relative to line breaks. Used by
    /// the chat host to decide whether ↑/↓ should step through history
    /// (only at the matching edge) or fall through to caret movement.
    private func currentArrowContext() -> ChatInputArrowContext {
        let ns = self.string as NSString
        let loc = max(0, min(self.selectedRange().location, ns.length))
        let before = ns.substring(to: loc)
        let after = ns.substring(from: loc)
        return ChatInputArrowContext(
            isEmpty: ns.length == 0,
            isAtFirstLine: !before.contains("\n"),
            isAtLastLine: !after.contains("\n")
        )
    }

    /// Remove characters [0, caret) using the standard editing pipeline
    /// so undo registration, change notifications, and the delegate's
    /// `textDidChange` all fire normally.
    private func killToBeginningOfDocument() {
        let loc = self.selectedRange().location
        guard loc > 0 else { return }
        let range = NSRange(location: 0, length: loc)
        guard shouldChangeText(in: range, replacementString: "") else { return }
        replaceCharacters(in: range, with: "")
        didChangeText()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + 5, y: inset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }
}

// MARK: - Chat row model

/// One renderable row in the chat transcript. Adjacent assistant
/// `tool_use` blocks are grouped into a `ToolBatch` so we can collapse
/// long bursts of tool calls into a single header.
enum ChatRow {
    case text(TextPayload)
    case toolBatch(ToolBatch)

    var id: String {
        switch self {
        case .text(let payload): return payload.id
        case .toolBatch(let batch): return batch.id
        }
    }

    struct TextPayload {
        let id: String
        let role: ChatMessageRole
        let text: String
        let attachmentURLs: [URL]
        /// Original `ChatMessage.id` — used by the inline rewind button
        /// to look up the matching checkpoint on the panel.
        let messageId: UUID
        /// Render the bubble collapsed (with a disclosure to expand).
        /// True for slash-command expansions and any other stream-
        /// injected user messages.
        var isCollapsedByDefault: Bool = false
        /// When this row was produced by invoking a slash command, the
        /// `/`-less name of that command — surfaced in the collapsed
        /// header so the user can tell which command produced it.
        var slashCommandName: String? = nil
    }

    struct ToolBatch {
        let id: String
        let entries: [Entry]

        struct Entry: Identifiable, Equatable {
            var id: String { toolUse.id }
            let messageId: UUID
            let toolUse: ChatMessageBlock.ToolUse
        }
    }
}

/// Per-panel cache for `ChatRowBuilder.buildRows`.
///
/// `messageList` rebuilds its rows on every `body` evaluation. With a
/// 120-message visible window, walking all messages + their blocks adds
/// up to milliseconds of work that fires every time the parent body
/// invalidates (e.g. `panel.draft` mutating on every keystroke,
/// `panel.permissionMode` changing, `panel.pendingAttachments` ticking,
/// etc.) — all those cases produce identical input to `buildRows` and
/// the result is wasted.
///
/// Signature is intentionally cheap: count of messages + identity of the
/// first and last message + the last message's `plainText.count` and
/// `blocks.count`. During streaming only the last assistant message
/// mutates, so this signature flips on every new token; on every other
/// re-render the signature is stable and the cached rows are reused.
final class ChatRowBuilderCache {
    static let shared = ChatRowBuilderCache()

    private struct Entry {
        let key: Int
        let rows: [ChatRow]
    }

    private var cache: [UUID: Entry] = [:]
    private let lock = NSLock()

    func rows(for panelId: UUID, messages: [ChatMessage]) -> [ChatRow] {
        let key = Self.signature(of: messages)
        lock.lock()
        if let entry = cache[panelId], entry.key == key {
            let cached = entry.rows
            lock.unlock()
            return cached
        }
        lock.unlock()
        let rows = ChatRowBuilder.buildRows(from: messages)
        lock.lock()
        cache[panelId] = Entry(key: key, rows: rows)
        lock.unlock()
        return rows
    }

    func clear(panelId: UUID) {
        lock.lock()
        cache.removeValue(forKey: panelId)
        lock.unlock()
    }

    private static func signature(of messages: [ChatMessage]) -> Int {
        var hasher = Hasher()
        hasher.combine(messages.count)
        if let first = messages.first {
            hasher.combine(first.id)
            hasher.combine(first.blocks.count)
        }
        if let last = messages.last {
            hasher.combine(last.id)
            hasher.combine(last.blocks.count)
            hasher.combine(last.plainText.count)
            hasher.combine(last.attachmentURLs.count)
        }
        return hasher.finalize()
    }
}

enum ChatRowBuilder {
    static func buildRows(from messages: [ChatMessage]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var batchEntries: [ChatRow.ToolBatch.Entry] = []
        var batchAnchorId: String?

        func flushBatch() {
            guard !batchEntries.isEmpty else { return }
            let id = batchAnchorId ?? UUID().uuidString
            rows.append(.toolBatch(.init(id: id, entries: batchEntries)))
            batchEntries.removeAll()
            batchAnchorId = nil
        }

        for message in messages {
            // For user messages with attachments but no text bubble we
            // still need a row so thumbnails render.
            if message.role == .user, message.blocks.isEmpty, !message.attachmentURLs.isEmpty {
                flushBatch()
                rows.append(.text(.init(
                    id: "\(message.id.uuidString)-attachOnly",
                    role: message.role,
                    text: "",
                    attachmentURLs: message.attachmentURLs,
                    messageId: message.id,
                    isCollapsedByDefault: message.isCollapsedByDefault,
                    slashCommandName: message.slashCommandName
                )))
                continue
            }
            var emittedAttachmentsForMessage = false
            for (idx, block) in message.blocks.enumerated() {
                switch block {
                case .text(let value):
                    flushBatch()
                    let attachments = (message.role == .user && !emittedAttachmentsForMessage)
                        ? message.attachmentURLs
                        : []
                    emittedAttachmentsForMessage = true
                    rows.append(.text(.init(
                        id: "\(message.id.uuidString)-\(idx)",
                        role: message.role,
                        text: value,
                        attachmentURLs: attachments,
                        messageId: message.id,
                        isCollapsedByDefault: message.isCollapsedByDefault,
                        slashCommandName: message.slashCommandName
                    )))
                case .toolUse(let toolUse):
                    // ExitPlanMode is the user's gating moment — they need
                    // to read the plan and pick an option. Force it into a
                    // batch of one so the surrounding read tools can't drag
                    // it under a "N tools used" collapse after the turn
                    // settles. Solo batches stay inline (inlineThreshold=1).
                    if toolUse.name == "ExitPlanMode" {
                        flushBatch()
                        batchAnchorId = "batch-\(toolUse.id)"
                        batchEntries.append(.init(messageId: message.id, toolUse: toolUse))
                        flushBatch()
                    } else {
                        if batchAnchorId == nil {
                            batchAnchorId = "batch-\(toolUse.id)"
                        }
                        batchEntries.append(.init(messageId: message.id, toolUse: toolUse))
                    }
                case .toolResult:
                    // Filtered into `toolResultsByToolUseId` at the panel
                    // level; if one slips through here we just ignore it.
                    break
                }
            }
        }
        flushBatch()
        return rows
    }
}

// MARK: - Text block row

private struct TextBlockRow: View, Equatable {
    let role: ChatMessageRole
    let text: String
    var attachmentURLs: [URL] = []
    var messageId: UUID? = nil
    let isDark: Bool
    var canRewindToHere: Bool = false
    var onRewindToHere: ((UUID) -> Void)? = nil
    /// True for stream-injected user messages (e.g. claude's expansion
    /// of a slash command). Renders with a disclosure header so the
    /// transcript stays compact.
    var isCollapsedByDefault: Bool = false
    /// When this row is a slash-command expansion, the original `/`-less
    /// command name. Used as the header label so the user sees
    /// `/start-task` instead of a generic "Slash command prompt".
    var slashCommandName: String? = nil
    /// User message that was queued while a previous turn was still
    /// running. Renders dimmed with a small ⏳ glyph so the user can tell
    /// it has not been dispatched to claude yet.
    var isPending: Bool = false
    /// Called when the user clicks the cancel (✕) button on a queued
    /// bubble. Wired only for pending rows; absent on already-sent
    /// messages, so the button only appears when the panel actually
    /// supports cancellation.
    var onCancelPending: ((UUID) -> Void)? = nil

    @Environment(\.chatPalette) private var palette
    @Environment(\.chatFontSize) private var fontSize
    @State private var isExpanded: Bool = false
    @State private var didCopy: Bool = false
#if DEBUG
    // Plain-value environment probe (closure struct, not an object reference):
    // set only by ChatLazyLayoutScaleTests, default no-op, and excluded from
    // `==` like every other closure on this row. See ChatLazyContractProbe.
    @Environment(\.chatLazyContractProbe) private var chatLazyContractProbe
#endif

    /// Compare only data inputs so SwiftUI can skip `body` re-evaluation
    /// when nothing visible changed. Closures (`onRewindToHere`) and the
    /// environment-injected `palette` are intentionally ignored: closure
    /// identity changes every parent render but the new closure is still
    /// installed for future taps, and `palette` only mutates when the
    /// terminal theme changes — which forces a re-render through the
    /// environment regardless.
    static func == (lhs: TextBlockRow, rhs: TextBlockRow) -> Bool {
        lhs.role == rhs.role
            && lhs.text == rhs.text
            && lhs.attachmentURLs == rhs.attachmentURLs
            && lhs.messageId == rhs.messageId
            && lhs.isDark == rhs.isDark
            && lhs.canRewindToHere == rhs.canRewindToHere
            && lhs.isCollapsedByDefault == rhs.isCollapsedByDefault
            && lhs.slashCommandName == rhs.slashCommandName
            && lhs.isPending == rhs.isPending
    }

    var body: some View {
#if DEBUG
        let _ = { chatLazyContractProbe.chatRowBody?() }()
#endif
        Group {
            switch role {
            case .user:
                if isCollapsedByDefault {
                    // Stream-injected user message (slash-command
                    // expansion). Render full-width as a tool-card-style
                    // collapsible block so it visually matches claude's
                    // own tool cards instead of pretending to be a chat
                    // bubble.
                    streamUserPromptCard
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        // Don't expose rewind on a still-queued bubble: it
                        // points at a turn that never happened.
                        //
                        // Rewind + copy used to fade in on hover via a
                        // sibling `.onHover` on this HStack. That installed
                        // an `NSTrackingArea` inside the LazyVStack hosting
                        // subtree which broke the AppKit dragging
                        // destination scan owned by the chat panel root
                        // (`ChatDropZoneNSView`). Keep both controls
                        // mounted permanently so file-drop keeps working.
                        if !isPending, canRewindToHere, let id = messageId {
                            Button {
                                onRewindToHere?(id)
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 6)
                            }
                            .buttonStyle(.plain)
                            .help(String(
                                localized: "claudeChat.rewindToHere.tooltip",
                                defaultValue: "Rewind the conversation and the files claude edited back to just after this message"
                            ))
                        }
                        if isPending, let id = messageId, let onCancelPending {
                            Button {
                                onCancelPending(id)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 6)
                            }
                            .buttonStyle(.plain)
                            .help(String(
                                localized: "claudeChat.cancelQueued.tooltip",
                                defaultValue: "Remove this queued message before it is sent to claude"
                            ))
                        }
                        if !isPending, !text.isEmpty {
                            copyButton
                        }
                        VStack(alignment: .trailing, spacing: 6) {
                            if !attachmentURLs.isEmpty {
                                SentAttachmentsRow(urls: attachmentURLs, isDark: isDark)
                                    .opacity(isPending ? 0.55 : 1.0)
                            }
                            if !text.isEmpty {
                                HStack(alignment: .center, spacing: 6) {
                                    if isPending {
                                        Image(systemName: "hourglass")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .help(String(
                                                localized: "claudeChat.queuedMessage.tooltip",
                                                defaultValue: "Queued — will be sent when the current turn finishes"
                                            ))
                                    }
                                    Text(text)
                                        .font(.system(size: fontSize))
                                        .foregroundColor(palette.fg(isDark))
                                        .lineSpacing(2)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(palette.accent(isDark).opacity(isDark ? 0.30 : 0.18))
                                )
                                .opacity(isPending ? 0.55 : 1.0)
                                // `.textSelection(.enabled)` removed —
                                // see the assistant-bubble branch
                                // below for the SelectionOverlay
                                // runaway-loop diagnosis. Every bubble
                                // in the LazyVStack mounted its own
                                // overlay; keeping it here would
                                // reintroduce the same multiplier and
                                // the same oscillation path.
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            case .assistant, .system:
                // Hybrid render path: si el bubble no tiene tabla ni
                // fenced code (la mayoría de respuestas son prosa con
                // bold/italic/links/inline-code/listas/headers),
                // renderizamos vía `Text(AttributedString(markdown:))`
                // — nativo, CoreText puro, sin árbol de subviews ni
                // preferences-machinery. Solo cuando hay tabla o code
                // block caemos al path completo de MarkdownUI.
                //
                // `.textSelection(.enabled)` was intentionally dropped
                // from these two paths: a Release build of the panel
                // pegged the main thread at 100% CPU with a memory leak
                // climbing past 19 GB after ~10 h, in a
                // `SelectionOverlay.updateNSView` →
                // `NSTextField.invalidateIntrinsicContentSize` →
                // `_NSPresentationIntentDirtying` loop. The bubbles
                // multiplied across the LazyVStack so every visible row
                // mounted its own SelectionOverlay; once one entered
                // the oscillation it perpetuated through layout
                // invalidation. For copying we expose the dedicated
                // "copy chat" button in the panel header plus a
                // per-bubble copy button (see `copyButton` below) that
                // writes the raw text to NSPasteboard without involving
                // SelectionOverlay.
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        switch ChatMarkdownComplexityProbe.shared.classify(text) {
                        case .simple:
                            Text(ChatSimpleMarkdownCache.shared.attributed(for: text))
                                .foregroundStyle(palette.fg(isDark))
                                .font(.system(size: fontSize))
                                .lineSpacing(2)
                                .tint(isDark ? ChatPalette.cyan : Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .heavy:
                            Markdown(ChatMarkdownContentCache.shared.content(for: text))
                                .markdownTheme(cmuxChatMarkdownTheme(isDark: isDark, palette: palette, fontSize: fontSize))
                                .lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !text.isEmpty {
                        // Persistent bottom rail with the copy button.
                        //
                        // The earlier implementation hid the button behind
                        // `.onHover` so it faded in only over the bubble.
                        // That installed an `NSTrackingArea` inside the
                        // LazyVStack's hosting view subtree which, on macOS
                        // Sonoma+, interferes with the AppKit dragging
                        // destination scan that lives at the chat panel root
                        // (`ChatDropZoneNSView`). Symptom: dragging a file
                        // from Finder no longer shows the blue drop ring and
                        // `draggingEntered` never fires.
                        //
                        // Keep the button mounted and always hittable. The
                        // visual cost is minimal — a single tiny clipboard
                        // glyph in the trailing corner — and drag-and-drop
                        // of attachments works again.
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            copyButton
                        }
                        .frame(height: 16)
                    }
                }
            }
        }
    }

    /// Per-bubble copy affordance. Mounted next to the rewind button on
    /// user bubbles and on a reserved bottom rail under assistant/system
    /// bubbles. Replaces the per-bubble `.textSelection(.enabled)` path
    /// that triggered the SelectionOverlay runaway loop (see the long
    /// comment in `body` above).
    private var copyButton: some View {
        Button(action: performCopy) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.clipboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(didCopy ? .green : .secondary)
                .frame(width: 14, height: 14, alignment: .center)
                .padding(.top, 6)
        }
        .buttonStyle(.plain)
        .help(String(
            localized: "claudeChat.copyMessage.tooltip",
            defaultValue: "Copy this message to the clipboard"
        ))
    }

    private func performCopy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut(duration: 0.2)) { didCopy = false }
        }
    }

    /// Tool-card-style block for stream-injected user prompts (a slash
    /// command's expansion lands here). Visual chrome matches claude's
    /// own ToolUseCard so the user spots it as "the same kind of thing":
    /// header row with an icon + label + truncated summary + chevron,
    /// rounded card with a subtle border, body that appears below the
    /// header when expanded.
    private var streamUserPromptCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 5) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Text(headerLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    if !collapsedSummary.isEmpty {
                        Text(collapsedSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.fg(isDark))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.codeBg(isDark))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Header label shown on the collapsed card: the slash command
    /// name when known, otherwise a generic "Slash command prompt".
    private var headerLabel: String {
        if let name = slashCommandName, !name.isEmpty {
            return "/\(name)"
        }
        return String(
            localized: "claudeChat.slashPrompt.label",
            defaultValue: "Slash command prompt"
        )
    }

    /// One-line summary for the collapsed header: the first non-empty
    /// line, capped at 80 chars; or "(N lines)" when the first line is
    /// empty (rare).
    private var collapsedSummary: String {
        let lineCount = text.components(separatedBy: "\n").count
        let first = text
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if first.isEmpty {
            return String(format: String(
                localized: "claudeChat.collapsed.linesOnly",
                defaultValue: "(%d lines)"
            ), lineCount)
        }
        let cap = 80
        let truncated = first.count > cap ? String(first.prefix(cap)) + "…" : first
        if lineCount > 1 {
            return "\(truncated)  ·  \(lineCount) lines"
        }
        return truncated
    }
}

// MARK: - Tool batch view

/// Renders a contiguous run of tool_use cards. When the batch is small
/// (≤ inlineThreshold) all cards are shown. When large, older cards
/// collapse behind a "N tools used" header; if the batch is the current
/// (turn still streaming) the most recent tool stays visible below the
/// header so the user can see what's running.
private struct ToolBatchView: View, Equatable {
    let entries: [ChatRow.ToolBatch.Entry]
    let pendingApprovals: [ChatApprovalRequest]
    let toolResults: [String: ChatMessageBlock.ToolResult]
    let isCurrentBatch: Bool
    let isDark: Bool
    let onApprove: (String) -> Void
    let onDeny: (String, String?) -> Void
    let onStopTurn: () -> Void
    /// Forwarded to each child `ToolUseCard`; see `ToolUseCard.onExitPlanApprove`.
    let onExitPlanApprove: (Bool) -> Void

    @Environment(\.chatPalette) private var palette
    @State private var expanded: Bool = false

    /// Skip body re-evaluation when none of the data this batch actually
    /// renders has changed. The caller already filters `pendingApprovals`
    /// and `toolResults` down to this batch's tool ids, so unrelated
    /// turns don't invalidate already-rendered batches. Closures are
    /// excluded from the comparison; the latest closures stay installed
    /// for future taps regardless of `body` skipping.
    static func == (lhs: ToolBatchView, rhs: ToolBatchView) -> Bool {
        lhs.entries == rhs.entries
            && lhs.pendingApprovals == rhs.pendingApprovals
            && lhs.toolResults == rhs.toolResults
            && lhs.isCurrentBatch == rhs.isCurrentBatch
            && lhs.isDark == rhs.isDark
    }

    /// Tool batches with 2+ entries always render with a collapsible
    /// header (a single tool stays inline as a regular card). Any
    /// stream of consecutive `tool_use` blocks ends up under one
    /// "N tools used" header so the transcript stays compact even on
    /// short bursts.
    private static let inlineThreshold = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entries.count <= Self.inlineThreshold {
                ForEach(entries) { entry in
                    cardFor(entry)
                }
            } else if isCurrentBatch {
                let collapsedCount = entries.count - 1
                if collapsedCount > 0 {
                    collapsedHeader(count: collapsedCount, finished: false)
                    if expanded {
                        ForEach(entries.dropLast()) { entry in
                            cardFor(entry)
                        }
                    }
                }
                if let last = entries.last {
                    cardFor(last)
                }
            } else {
                collapsedHeader(count: entries.count, finished: true)
                if expanded {
                    ForEach(entries) { entry in
                        cardFor(entry)
                    }
                }
            }
        }
    }

    private func cardFor(_ entry: ChatRow.ToolBatch.Entry) -> some View {
        ToolUseCard(
            toolUse: entry.toolUse,
            pending: pendingApprovals.first(where: { $0.id == entry.toolUse.id }),
            result: toolResults[entry.toolUse.id],
            isDark: isDark,
            onApprove: { onApprove(entry.toolUse.id) },
            onDeny: { reason in onDeny(entry.toolUse.id, reason) },
            onStopTurn: onStopTurn,
            onExitPlanApprove: onExitPlanApprove
        )
    }

    private func collapsedHeader(count: Int, finished: Bool) -> some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(headerLabel(count: count, finished: finished))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if !expanded {
                    Text(toolNameSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.cardSubtleBg(isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(palette.borderSubtle(isDark), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func headerLabel(count: Int, finished: Bool) -> String {
        if finished {
            return String(
                localized: "claudeChat.toolBatch.finished",
                defaultValue: "\(count) tools used"
            )
        }
        return String(
            localized: "claudeChat.toolBatch.previous",
            defaultValue: "\(count) earlier tools"
        )
    }

    private var toolNameSummary: String {
        // Show up to 4 distinct tool names so the user can glance at what
        // ran without expanding.
        var seen: [String] = []
        for entry in entries {
            if !seen.contains(entry.toolUse.name) {
                seen.append(entry.toolUse.name)
                if seen.count >= 4 { break }
            }
        }
        return seen.joined(separator: ", ")
    }
}

// MARK: - Slash command popup

/// Floating list of slash commands shown above the chat input while the
/// user types a `/`-prefixed name. Visual style matches the rest of the
/// chat: panel-derived card background, thin border, two-line rows with
/// the command name in mono and a description below.
private struct SlashCommandPopup: View {
    let commands: [SlashCommand]
    let selectedIndex: Int
    let palette: ChatPalette
    let isDark: Bool
    let onPick: (Int) -> Void

    /// Cap so a project with dozens of custom commands does not push the
    /// chat history off-screen — the user can scroll inside the popup.
    private static let maxListHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    // Plain VStack (not Lazy): we cap the list at a few
                    // dozen commands so the lazy upside is negligible,
                    // and LazyVStack inside an NSHostingView (the
                    // ChatDropContainer wrapping the panel) recycles
                    // rows aggressively when the data shrinks — which
                    // produced ghost rows after filtering. Render
                    // every row up-front instead.
                    VStack(spacing: 0) {
                        ForEach(commands) { cmd in
                            let idx = commands.firstIndex(where: { $0.id == cmd.id }) ?? 0
                            SlashCommandRow(
                                command: cmd,
                                isSelected: idx == selectedIndex,
                                palette: palette,
                                isDark: isDark
                            )
                            .id(cmd.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(idx) }
                            if idx < commands.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
                .frame(maxHeight: Self.maxListHeight)
                .onChange(of: selectedIndex) { newValue in
                    // Keep the highlighted row visible while the user
                    // arrows through a long list. We scroll to the
                    // command's stable id rather than the index so the
                    // anchor stays valid across filter transitions.
                    guard newValue >= 0, newValue < commands.count else { return }
                    let target = commands[newValue].id
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            HStack(spacing: 10) {
                hint(symbol: "↑↓", label: String(
                    localized: "claudeChat.slash.hint.move",
                    defaultValue: "navigate"
                ))
                hint(symbol: "↩", label: String(
                    localized: "claudeChat.slash.hint.run",
                    defaultValue: "run"
                ))
                hint(symbol: "⇥", label: String(
                    localized: "claudeChat.slash.hint.complete",
                    defaultValue: "complete"
                ))
                hint(symbol: "esc", label: String(
                    localized: "claudeChat.slash.hint.dismiss",
                    defaultValue: "dismiss"
                ))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(palette.cardSubtleBg(isDark))
        }
        .background(palette.cardBg(isDark))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: Color.black.opacity(isDark ? 0.5 : 0.18), radius: 12, y: 4)
    }

    private func hint(symbol: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(symbol).font(.system(size: 10, design: .monospaced))
            Text(label)
        }
    }
}

private struct SlashCommandRow: View {
    let command: SlashCommand
    let isSelected: Bool
    let palette: ChatPalette
    let isDark: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(command.displayTitle)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(palette.fg(isDark))
                    sourceTag
                }
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? palette.accent(isDark).opacity(isDark ? 0.22 : 0.14) : Color.clear
        )
    }

    @ViewBuilder
    private var sourceTag: some View {
        switch command.source {
        case .builtin:
            EmptyView()
        case .userCustom:
            Text(String(localized: "claudeChat.slash.source.user", defaultValue: "user"))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
        case .projectCustom:
            Text(String(localized: "claudeChat.slash.source.project", defaultValue: "project"))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
        case .cliReported:
            // Skills, plugin commands and the CLI's own built-ins: reported by
            // the init event, backed by no file we can point at.
            Text(String(localized: "claudeChat.slash.source.claude", defaultValue: "claude"))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
        }
    }
}

// MARK: - ANSI / SGR renderer

/// Minimal ANSI escape-sequence parser that turns the output of a
/// status-line script into a SwiftUI `AttributedString`. Honours the
/// 30-bit-color SGR subset most shell scripts use:
///   - reset (0)
///   - bold (1), dim (2), italic (3), underline (4), strikethrough (9)
///   - 16 base foreground/background colors (30-37, 40-47)
///   - 16 bright foreground/background colors (90-97, 100-107)
///   - 256-color (38;5;N / 48;5;N), 24-bit color (38;2;R;G;B / 48;2;…)
///   - default fg/bg (39, 49)
/// CSI sequences other than `m` (cursor moves, etc.) and OSC blocks
/// are silently dropped.
/// Per-process cache for the status line's `AttributedString`. Without
/// this, `statusLineRow` re-runs `ANSIRenderer.attributedString` on
/// every body evaluation; the produced struct compares unequal between
/// runs even when the input is identical (style identities — `Font`,
/// `Color` — diverge across `setAttributes` calls), so SwiftUI treats
/// every render as a content change and re-applies the AttributedString
/// to the underlying NSTextField. Combined with `.textSelection(.enabled)`
/// that triggers `SelectionOverlay.updateNSView`'s `replacingLineBreakModes`
/// pass and `_NSPresentationIntentDirtying` intent re-resolution — the
/// observed runaway loop on the Release fork.
///
/// Key is the literal status line text; the baseFont/defaultColor
/// arguments are practically constant (`.secondary` + `system(size:11)`)
/// but baked into the key as well for safety in case future callers
/// share the cache.
final class ChatStatusLineAttributedCache {
    static let shared = ChatStatusLineAttributedCache()

    private final class Box { let attr: AttributedString; init(_ a: AttributedString) { self.attr = a } }
    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 64
    }

    func attributed(
        for text: String,
        baseFont: Font,
        defaultColor: Color
    ) -> AttributedString {
        // The base font / default color are fixed at the call site for
        // the status line, so encoding them in the key by description
        // is enough. If a future caller varies them, the key still
        // disambiguates.
        let key = "\(text)|\(baseFont)|\(defaultColor)" as NSString
        if let box = cache.object(forKey: key) {
            return box.attr
        }
        lock.lock()
        defer { lock.unlock() }
        if let box = cache.object(forKey: key) {
            return box.attr
        }
        let attr = ANSIRenderer.attributedString(
            from: text,
            baseFont: baseFont,
            defaultColor: defaultColor
        )
        cache.setObject(Box(attr), forKey: key)
        return attr
    }
}

enum ANSIRenderer {
    static func attributedString(
        from text: String,
        baseFont: Font,
        defaultColor: Color
    ) -> AttributedString {
        var result = AttributedString()
        var fg: Color? = nil
        var bg: Color? = nil
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var dim = false

        var buffer = ""
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var part = AttributedString(buffer)
            var attrs = AttributeContainer()
            // Foreground: explicit > dim default > base default.
            let resolvedFg = fg ?? (dim ? defaultColor.opacity(0.6) : defaultColor)
            attrs.foregroundColor = resolvedFg
            if let bg { attrs.backgroundColor = bg }
            var f = baseFont
            if bold { f = f.bold() }
            if italic { f = f.italic() }
            attrs.font = f
            if underline { attrs.underlineStyle = .single }
            if strikethrough { attrs.strikethroughStyle = .single }
            part.setAttributes(attrs)
            result.append(part)
            buffer = ""
        }

        // NOTE: there used to be a `resetAll` closure captured by reference
        // and forwarded into `applySGR` as `reset: () -> Void`. That tripped
        // Swift's exclusivity checker — `applySGR` already holds inout
        // access to `fg`, `bg`, `bold`, … and the closure tried to mutate
        // the same variables through its capture list. Same memory,
        // overlapping accesses → `Fatal access conflict detected`. The
        // reset (SGR param 0) is now handled inline inside `applySGR`.

        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x1B {  // ESC
                let next = i + 1 < scalars.count ? scalars[i + 1].value : 0
                if next == 0x5B {  // CSI: ESC [ <params> <final>
                    flush()
                    i += 2
                    var params = ""
                    var finalByte: UInt32 = 0
                    while i < scalars.count {
                        let cv = scalars[i].value
                        i += 1
                        if cv >= 0x30 && cv <= 0x3F {
                            params.unicodeScalars.append(scalars[i - 1])
                            continue
                        }
                        if cv >= 0x40 && cv <= 0x7E {
                            finalByte = cv
                            break
                        }
                        // intermediates 0x20-0x2F or stray bytes — ignore.
                    }
                    if finalByte == 0x6D {  // 'm' = SGR
                        applySGR(
                            params: parseParams(params),
                            fg: &fg, bg: &bg,
                            bold: &bold, italic: &italic,
                            underline: &underline,
                            strikethrough: &strikethrough,
                            dim: &dim
                        )
                    }
                    continue
                }
                if next == 0x5D {  // OSC: ESC ] ... (BEL | ESC \)
                    flush()
                    i += 2
                    while i < scalars.count {
                        let cv = scalars[i].value
                        if cv == 0x07 { i += 1; break }
                        if cv == 0x1B,
                           i + 1 < scalars.count,
                           scalars[i + 1].value == 0x5C {
                            i += 2
                            break
                        }
                        i += 1
                    }
                    continue
                }
                // Two-byte ESC <final>
                i += 2
                continue
            }
            buffer.unicodeScalars.append(scalars[i])
            i += 1
        }
        flush()
        return result
    }

    private static func parseParams(_ s: String) -> [Int] {
        if s.isEmpty { return [0] }  // bare `ESC[m` is reset
        return s.split(separator: ";", omittingEmptySubsequences: false).map { piece in
            Int(piece) ?? 0
        }
    }

    private static func applySGR(
        params: [Int],
        fg: inout Color?,
        bg: inout Color?,
        bold: inout Bool,
        italic: inout Bool,
        underline: inout Bool,
        strikethrough: inout Bool,
        dim: inout Bool
    ) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                // Reset every attribute. Inlined intentionally — passing
                // this as a closure that captured the same vars by
                // reference triggered Swift's exclusive-access checker
                // because the inout parameters already hold exclusive
                // access to the same memory.
                fg = nil
                bg = nil
                bold = false
                italic = false
                underline = false
                strikethrough = false
                dim = false
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 9: strikethrough = true
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false
            case 29: strikethrough = false
            case 30...37: fg = ansiBaseColor(p - 30, bright: false)
            case 39: fg = nil
            case 40...47: bg = ansiBaseColor(p - 40, bright: false)
            case 49: bg = nil
            case 90...97: fg = ansiBaseColor(p - 90, bright: true)
            case 100...107: bg = ansiBaseColor(p - 100, bright: true)
            case 38, 48:
                // Extended color: 38;5;N (256-color) or 38;2;R;G;B.
                let isFg = p == 38
                guard i + 1 < params.count else { i += 1; continue }
                let mode = params[i + 1]
                if mode == 5, i + 2 < params.count {
                    let n = params[i + 2]
                    let c = xterm256(n)
                    if isFg { fg = c } else { bg = c }
                    i += 3
                    continue
                }
                if mode == 2, i + 4 < params.count {
                    let r = max(0, min(255, params[i + 2]))
                    let g = max(0, min(255, params[i + 3]))
                    let b = max(0, min(255, params[i + 4]))
                    let c = Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
                    if isFg { fg = c } else { bg = c }
                    i += 5
                    continue
                }
                i += 2
                continue
            default:
                break
            }
            i += 1
        }
    }

    /// Standard 16-color ANSI palette (matches macOS Terminal defaults
    /// closely). Index 0-7; `bright` selects the 8-15 bank.
    private static func ansiBaseColor(_ idx: Int, bright: Bool) -> Color {
        let basic: [(Double, Double, Double)] = [
            (0.00, 0.00, 0.00),  // black
            (0.80, 0.00, 0.00),  // red
            (0.31, 0.61, 0.02),  // green
            (0.77, 0.63, 0.00),  // yellow
            (0.20, 0.40, 0.64),  // blue
            (0.46, 0.31, 0.48),  // magenta
            (0.02, 0.60, 0.60),  // cyan
            (0.83, 0.84, 0.81),  // white
        ]
        let brightTable: [(Double, Double, Double)] = [
            (0.33, 0.34, 0.32),  // bright black
            (0.94, 0.16, 0.16),  // bright red
            (0.54, 0.89, 0.20),  // bright green
            (0.99, 0.91, 0.31),  // bright yellow
            (0.45, 0.62, 0.81),  // bright blue
            (0.68, 0.50, 0.66),  // bright magenta
            (0.20, 0.89, 0.89),  // bright cyan
            (0.93, 0.93, 0.93),  // bright white
        ]
        let table = bright ? brightTable : basic
        let i = max(0, min(7, idx))
        let (r, g, b) = table[i]
        return Color(red: r, green: g, blue: b)
    }

    /// Resolve an xterm-256 index. 0-15 reuse the 16-color palette;
    /// 16-231 form a 6×6×6 cube; 232-255 are a grayscale ramp.
    private static func xterm256(_ n: Int) -> Color {
        if n < 16 {
            return ansiBaseColor(n & 7, bright: n >= 8)
        }
        if n >= 232 {
            let level = Double(n - 232) * 10.0 / 255.0 + 8.0 / 255.0
            return Color(red: level, green: level, blue: level)
        }
        let idx = n - 16
        let r = idx / 36
        let g = (idx / 6) % 6
        let b = idx % 6
        let toLinear = { (v: Int) -> Double in
            // xterm cube: 0 → 0, then 95, 135, 175, 215, 255.
            v == 0 ? 0 : Double(95 + (v - 1) * 40) / 255.0
        }
        return Color(red: toLinear(r), green: toLinear(g), blue: toLinear(b))
    }
}

/// Render a fenced code block from Claude with a header showing the
/// language (when present) and a copy button. Replaces the bare scrollview
/// previously used in the markdown theme so users can grab the snippet
/// without selecting char-by-char inside the bubble.
private struct ChatCopyableCodeBlock: View {
    let configuration: CodeBlockConfiguration
    let isDark: Bool
    let palette: ChatPalette
    let fontSize: CGFloat

    @State private var didCopy = false
    @State private var copyResetWorkItem: DispatchWorkItem?
    /// For mermaid blocks: whether to show the rendered diagram (true) or the
    /// raw fence source (false). Defaults to the diagram; the user can flip it
    /// from the header to copy/inspect the source.
    @State private var showMermaidSource = false

    /// Trimmed fence language, lowercased. `nil`/empty when the fence had none.
    private var languageTag: String? {
        configuration.language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var isMermaid: Bool { languageTag == "mermaid" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isMermaid && !showMermaidSource {
                // Kept mounted across streaming updates so mermaid.js loads once
                // and each new token is a cheap, debounced re-render rather than
                // a fresh 2.5 MB web view.
                ChatMermaidDiagramView(source: configuration.content, isDark: isDark)
                    .padding(10)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(max(9, fontSize - 1))
                        }
                        .padding(10)
                }
            }
        }
        .background(palette.codeBg(isDark))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .markdownMargin(top: 6, bottom: 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let language = configuration.language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if isMermaid {
                Button {
                    showMermaidSource.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showMermaidSource ? "chart.xyaxis.line" : "curlybraces")
                            .font(.system(size: 10, weight: .medium))
                        Text(showMermaidSource
                            ? String(
                                localized: "claudeChat.codeBlock.mermaid.showDiagram",
                                defaultValue: "Diagram"
                            )
                            : String(
                                localized: "claudeChat.codeBlock.mermaid.showSource",
                                defaultValue: "Source"
                            )
                        )
                        .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(
                    localized: "claudeChat.codeBlock.mermaid.toggle.tooltip",
                    defaultValue: "Toggle between the rendered diagram and its source"
                ))
                Button {
                    MermaidDiagramWindowController.present(
                        source: configuration.content,
                        isDark: isDark
                    )
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(
                    localized: "claudeChat.codeBlock.mermaid.openWindow.tooltip",
                    defaultValue: "Open the diagram in a larger window"
                ))
            }
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                    Text(didCopy
                        ? String(localized: "claudeChat.codeBlock.copy.copied", defaultValue: "Copied")
                        : String(localized: "claudeChat.codeBlock.copy.action", defaultValue: "Copy")
                    )
                    .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(didCopy ? ChatPalette.green : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(
                localized: "claudeChat.codeBlock.copy.tooltip",
                defaultValue: "Copy this code block to the clipboard"
            ))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(palette.codeBg(isDark).opacity(isDark ? 0.6 : 0.5))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(configuration.content, forType: .string)
        didCopy = true
        copyResetWorkItem?.cancel()
        let item = DispatchWorkItem { didCopy = false }
        copyResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
}

// MARK: - Mermaid diagram rendering in chat

/// A WKWebView that reports its rendered content height back to AppKit so the
/// SwiftUI layout can size the diagram exactly. `intrinsicContentSize` is driven
/// by `reportedHeight`, which the coordinator updates from a JS `postMessage`.
private final class MermaidWebView: WKWebView {
    /// In the chat transcript the view sizes itself to the diagram via
    /// `reportedHeight`. In the pop-out window the container drives the size, so
    /// the intrinsic height is disabled and the view stretches to fill.
    var usesIntrinsicHeight = true
    var reportedHeight: CGFloat = 1 {
        didSet {
            if abs(oldValue - reportedHeight) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        guard usesIntrinsicHeight else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: reportedHeight)
    }

    /// Keep the enclosing chat scroll view usable: a plain wheel scroll is
    /// forwarded to the next responder (the message list keeps scrolling), while
    /// ⌘-wheel zooms the diagram in place. Panning is handled by drag in JS.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let dy = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.deltaY
            evaluateJavaScript("window.__cmuxWheelZoom && window.__cmuxWheelZoom(\(dy))")
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// Renders a ```mermaid fence as a live diagram using the bundled `mermaid.min.js`
/// (the same asset the markdown file viewer loads on demand). Each diagram is an
/// isolated, transparent WKWebView sized to its rendered SVG. The view is kept
/// mounted across streaming updates: mermaid.js loads once and each new token is
/// a cheap, debounced re-render. Intermediate parse failures (the fence is still
/// streaming and syntactically incomplete) keep the last valid diagram on screen.
private struct ChatMermaidDiagramView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    /// When true the diagram fills its container (used by the pop-out window)
    /// instead of capping to a fixed height inside the chat transcript.
    var fillHeight: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MermaidWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "cmuxMermaid")
        let webView = MermaidWebView(frame: .zero, configuration: config)
        // Transparent background so the surrounding code-block card shows
        // through (matches how the markdown viewer keeps its web content clear).
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.usesIntrinsicHeight = !fillHeight
        // Only hug vertically in the transcript; the pop-out window must be free
        // to stretch the web view to fill the window.
        if !fillHeight {
            webView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }
        context.coordinator.fillHeight = fillHeight
        context.coordinator.attach(webView)
        context.coordinator.load(source: source, isDark: isDark)
        return webView
    }

    func updateNSView(_ webView: MermaidWebView, context: Context) {
        context.coordinator.update(source: source, isDark: isDark)
    }

    static func dismantleNSView(_ webView: MermaidWebView, coordinator: Coordinator) {
        coordinator.cancelPending()
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "cmuxMermaid")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var fillHeight = false

        private weak var webView: MermaidWebView?
        private var isLoaded = false
        private var loadedIsDark: Bool?
        private var lastRenderedSource: String?
        private var pendingSource: String?
        private var debounceWorkItem: DispatchWorkItem?

        func attach(_ webView: MermaidWebView) {
            self.webView = webView
        }

        func cancelPending() {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
        }

        func load(source: String, isDark: Bool) {
            loadedIsDark = isDark
            lastRenderedSource = source
            pendingSource = source
            isLoaded = false
            webView?.loadHTMLString(
                Self.shellHTML(isDark: isDark, fillHeight: fillHeight),
                baseURL: nil
            )
        }

        func update(source: String, isDark: Bool) {
            // A theme flip needs a fresh `mermaid.initialize`, so reload the shell.
            if loadedIsDark != isDark {
                load(source: source, isDark: isDark)
                return
            }
            guard source != lastRenderedSource else { return }
            lastRenderedSource = source
            guard isLoaded else {
                pendingSource = source
                return
            }
            // Debounce so a fast token stream coalesces into one render.
            cancelPending()
            let item = DispatchWorkItem { [weak self] in
                self?.render(source)
            }
            debounceWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }

        private func render(_ source: String) {
            // Pass the source as base64 to avoid any string-escaping pitfalls.
            let encoded = Data(source.utf8).base64EncodedString()
            webView?.evaluateJavaScript("window.__cmuxRenderMermaid('\(encoded)')")
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pending = pendingSource {
                pendingSource = nil
                render(pending)
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            if let height = body["height"] as? Double {
                webView?.reportedHeight = max(1, CGFloat(height))
            }
            // A parse/render error (e.g. an incomplete fence mid-stream) is
            // ignored: the previously rendered diagram, if any, stays on screen.
        }

        // MARK: HTML shell

        private static func shellHTML(isDark: Bool, fillHeight: Bool) -> String {
            let mermaidJS = MarkdownViewerAssets.shared.lazyAsset(name: "mermaid.min", ext: "js")
            let theme = isDark ? "dark" : "default"
            let fg = isDark ? "#dddddd" : "#333333"
            let fillFlag = fillHeight ? "true" : "false"
            let zoomInLabel = String(
                localized: "claudeChat.mermaid.zoomIn", defaultValue: "Zoom in"
            )
            let zoomOutLabel = String(
                localized: "claudeChat.mermaid.zoomOut", defaultValue: "Zoom out"
            )
            let fitLabel = String(
                localized: "claudeChat.mermaid.fit", defaultValue: "Fit"
            )
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              html, body { margin: 0; padding: 0; background: transparent; height: 100%; }
              #viewport {
                position: relative; overflow: hidden; width: 100%;
                color: \(fg);
              }
              #stage {
                transform-origin: 0 0; display: inline-block; width: 100%;
                cursor: grab; will-change: transform;
              }
              #stage.dragging { cursor: grabbing; }
              #stage svg { display: block; width: 100%; height: auto; }
              .zbar {
                position: absolute; top: 6px; right: 6px; display: flex; gap: 2px;
                align-items: center; padding: 2px; border-radius: 6px;
                background: rgba(128, 128, 128, 0.16);
                opacity: 0; transition: opacity 0.15s;
                font: 12px ui-sans-serif, -apple-system, system-ui, sans-serif;
                user-select: none;
              }
              #viewport:hover .zbar { opacity: 1; }
              .zbar button {
                all: unset; cursor: pointer; width: 20px; height: 20px;
                text-align: center; line-height: 20px; border-radius: 4px; color: \(fg);
              }
              .zbar button:hover { background: rgba(128, 128, 128, 0.28); }
              .zbar .pct { min-width: 40px; text-align: center; opacity: 0.85; }
            </style>
            </head>
            <body>
            <div id="viewport">
              <div id="stage"></div>
              <div class="zbar">
                <button id="z-out" aria-label="\(zoomOutLabel)" title="\(zoomOutLabel)">&#8722;</button>
                <span class="pct" id="z-pct">100%</span>
                <button id="z-in" aria-label="\(zoomInLabel)" title="\(zoomInLabel)">&#43;</button>
                <button id="z-fit" aria-label="\(fitLabel)" title="\(fitLabel)">&#10530;</button>
              </div>
            </div>
            <script>\(mermaidJS)</script>
            <script>
              mermaid.initialize({
                startOnLoad: false,
                theme: '\(theme)',
                securityLevel: 'strict',
                fontFamily: 'ui-sans-serif, -apple-system, system-ui, sans-serif'
              });

              var FILL = \(fillFlag);
              var CAP = 520, MIN_S = 0.2, MAX_S = 8;
              var scale = 1, tx = 0, ty = 0, H0 = 0;
              var viewport = document.getElementById('viewport');
              var stage = document.getElementById('stage');
              var pct = document.getElementById('z-pct');
              if (FILL) { viewport.style.height = '100%'; }

              function apply() {
                stage.style.transform =
                  'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
                pct.textContent = Math.round(scale * 100) + '%';
              }
              function fit() { scale = 1; tx = 0; ty = 0; apply(); }
              function setScale(ns, cx, cy) {
                ns = Math.min(MAX_S, Math.max(MIN_S, ns));
                var rect = viewport.getBoundingClientRect();
                var vx = (cx == null) ? rect.width / 2 : cx;
                var vy = (cy == null) ? rect.height / 2 : cy;
                var sx = (vx - tx) / scale, sy = (vy - ty) / scale;
                scale = ns;
                tx = vx - sx * scale; ty = vy - sy * scale;
                apply();
              }

              document.getElementById('z-in').onclick = function () { setScale(scale * 1.25); };
              document.getElementById('z-out').onclick = function () { setScale(scale / 1.25); };
              document.getElementById('z-fit').onclick = function () { fit(); };
              window.__cmuxWheelZoom = function (dy) {
                setScale(scale * Math.exp(dy * 0.0016));
              };

              var dragging = false, lastX = 0, lastY = 0;
              viewport.addEventListener('mousedown', function (e) {
                if (e.button !== 0 || e.target.closest('.zbar')) return;
                dragging = true; lastX = e.clientX; lastY = e.clientY;
                stage.classList.add('dragging'); e.preventDefault();
              });
              window.addEventListener('mousemove', function (e) {
                if (!dragging) return;
                tx += e.clientX - lastX; ty += e.clientY - lastY;
                lastX = e.clientX; lastY = e.clientY; apply();
              });
              window.addEventListener('mouseup', function () {
                if (!dragging) return;
                dragging = false; stage.classList.remove('dragging');
              });

              function __report(h) {
                window.webkit.messageHandlers.cmuxMermaid.postMessage({ height: h });
              }
              var __seq = 0;
              window.__cmuxRenderMermaid = async function (b64) {
                var src = new TextDecoder().decode(
                  Uint8Array.from(atob(b64), function (c) { return c.charCodeAt(0); })
                );
                try {
                  await mermaid.parse(src);
                  var res = await mermaid.render('cmux-mmd-' + (++__seq), src);
                  stage.innerHTML = res.svg;
                  fit();
                  requestAnimationFrame(function () {
                    if (FILL) {
                      // The pop-out window sizes the web view; fill it and let
                      // zoom/pan explore anything larger than the viewport.
                      __report(window.innerHeight);
                      return;
                    }
                    // Measure the natural (fit-to-width) height, then cap the
                    // viewport so a huge diagram scrolls/zooms in place instead
                    // of pushing the whole chat down.
                    H0 = Math.ceil(stage.getBoundingClientRect().height);
                    var vh = Math.min(H0, CAP);
                    viewport.style.height = vh + 'px';
                    __report(vh);
                  });
                } catch (e) {
                  window.webkit.messageHandlers.cmuxMermaid.postMessage({
                    error: String((e && e.message) || e)
                  });
                }
              };
            </script>
            </body>
            </html>
            """
        }
    }
}

/// Presents a mermaid diagram in a standalone, resizable floating window so the
/// user can inspect large diagrams with full zoom/pan. Instances retain
/// themselves in `live` until their window closes, avoiding an owner reference
/// from the transient code-block view.
@MainActor
private final class MermaidDiagramWindowController: NSObject, NSWindowDelegate {
    private static var live: [MermaidDiagramWindowController] = []
    private var window: NSWindow?

    static func present(source: String, isDark: Bool) {
        let controller = MermaidDiagramWindowController()
        controller.show(source: source, isDark: isDark)
        live.append(controller)
    }

    private func show(source: String, isDark: Bool) {
        let content = ChatMermaidDiagramView(source: source, isDark: isDark, fillHeight: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = String(
            localized: "claudeChat.mermaid.window.title", defaultValue: "Diagram"
        )
        window.setContentSize(NSSize(width: 960, height: 720))
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
