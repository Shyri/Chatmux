import AppKit
import SwiftUI

/// Accessory shown inside the native open panel when starting a new chat:
/// the agent sessions that already exist in whatever directory the panel is
/// currently pointing at.
///
/// Browsing is `NSOpenPanel`'s job — favourites sidebar, search, path bar,
/// ⌘⇧G, tags, network volumes. Reimplementing that in SwiftUI would be a worse
/// copy of something every Mac user already knows. This view is only the part
/// AppKit does not provide.
struct NewChatLauncherAccessory: View {
    @ObservedObject var sessionStore: SessionIndexStore
    /// Directory the panel is currently showing/selecting, kept in sync by
    /// `panelSelectionDidChange`.
    let directory: String?
    /// Resume an existing session instead of starting a fresh chat.
    let onResume: (SessionEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(String(
                    localized: "newChat.launcher.sessionsHeader",
                    defaultValue: "Sessions in this folder"
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            SessionIndexView(store: sessionStore, onResume: onResume)
                .frame(height: 180)
        }
        .frame(width: 520)
    }
}
