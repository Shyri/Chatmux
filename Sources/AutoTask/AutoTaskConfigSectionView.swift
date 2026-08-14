import SwiftUI

/// One `[section]` of `auto-task.conf` — a sub-project of a monorepo.
///
/// Takes a `Binding` to a value type and a plain array of findings, never the
/// editor model: a view under a `ForEach` that holds an `ObservableObject` is
/// the exact shape that has hung this app before.
struct AutoTaskConfigSectionView: View {
    @Binding var section: AutoTaskConfigEditorModel.SectionDraft
    let findings: [AutoTaskConfigDiagnostics.Finding]
    /// From `detect-projects`, empty when unknown.
    let projectType: String
    let globalTimeout: String
    let onRemove: () -> Void

    @State private var expanded = true
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                fields
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.darculaCardBackground.opacity(0.5)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: hasErrors ? 1 : 0.5)
        )
    }

    private var hasErrors: Bool { findings.contains { $0.severity == .error } }

    private var borderColor: Color {
        hasErrors ? Color.red.opacity(0.6) : Color.darculaBorder
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)

            Text("[\(section.name)]")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))

            if !projectType.isEmpty, projectType != "unknown" {
                Text(projectType)
                    .font(.system(size: 10))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.darculaAccent.opacity(0.18)))
                    .foregroundStyle(Color.darculaAccent)
            }

            if !expanded {
                // Collapsed, the command is the one thing worth seeing: it is
                // what actually runs.
                Text(section.verifyCommand.isEmpty ? "—" : section.verifyCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if hasErrors {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            Button {
                confirmingRemoval = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(
                localized: "autoTask.config.section.remove",
                defaultValue: "Remove this sub-project from the configuration"
            ))
        }
        .padding(12)
        .contentShape(Rectangle())
        .confirmationDialog(
            String(
                localized: "autoTask.config.section.removeTitle",
                defaultValue: "Remove [\(section.name)]?"
            ),
            isPresented: $confirmingRemoval
        ) {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Text(String(
                    localized: "autoTask.config.section.removeConfirm",
                    defaultValue: "Remove"
                ))
            }
        } message: {
            Text(String(
                localized: "autoTask.config.section.removeMessage",
                defaultValue: "Changes under this path will no longer be verified by any command, and its forbidden paths stop being enforced."
            ))
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("PATH", help: String(
                localized: "autoTask.config.section.pathHelp",
                defaultValue: "Relative to the repository root. A change resolves to the section with the longest matching path, and VERIFY_CMD runs inside it."
            )) {
                TextField("", text: $section.path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.darculaBorder, lineWidth: 0.5))
            }

            labelled("VERIFY_CMD", help: String(
                localized: "autoTask.config.section.verifyHelp",
                defaultValue: "Runs with this section's PATH as the working directory, only when a change touches it."
            )) {
                TextField("", text: $section.verifyCommand, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...4)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.darculaBorder, lineWidth: 0.5))
            }

            labelled("FORBIDDEN_PATHS", help: String(
                localized: "autoTask.config.section.forbiddenHelp",
                defaultValue: "Relative to PATH, not to the repository root: write pubspec.lock, not lore/pubspec.lock. They are enforced on every run, not only the ones that touch this sub-project."
            )) {
                TextField("", text: $section.forbiddenPaths, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...4)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.darculaBorder, lineWidth: 0.5))
            }

            labelled("VERIFY_TIMEOUT", help: String(
                localized: "autoTask.config.section.timeoutHelp",
                defaultValue: "Seconds, for this sub-project only. Leave it empty to inherit the global value."
            )) {
                HStack(spacing: 8) {
                    TextField(globalTimeout, text: $section.verifyTimeout)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 90)
                    if section.verifyTimeout.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(String(
                            localized: "autoTask.config.section.timeoutInherited",
                            defaultValue: "inherits \(globalTimeout)s"
                        ))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(findings) { finding in
                AutoTaskConfigFindingRow(finding: finding)
            }
        }
    }

    private func labelled<Content: View>(
        _ key: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.darculaForeground.opacity(0.75))
            content()
            Text(help)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One error or warning. Shared by the global block and by every section.
struct AutoTaskConfigFindingRow: View {
    let finding: AutoTaskConfigDiagnostics.Finding

    var body: some View {
        let color: Color = finding.severity == .error ? .red : .orange
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: finding.severity == .error
                ? "xmark.octagon.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(finding.message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.1)))
    }
}
