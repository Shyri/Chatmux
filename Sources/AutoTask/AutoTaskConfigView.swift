import SwiftUI

/// Editor for `.octo-dev/auto-task.conf`, opened as a workspace tab.
///
/// Not a text editor: each parameter is shown with what it means and what
/// getting it wrong costs, because this file is committed and a mistake in it
/// affects every autonomous run by every member of the team.
struct AutoTaskConfigView: View {
    @StateObject private var model: AutoTaskConfigEditorModel
    @StateObject private var setup: AutoTaskSetupModel
    @State private var showingDiff = false
    /// Step 0 of the assistant's flow: with a config already present, do not
    /// launch the wizard — show the configuration and offer to edit it.
    @State private var showingSetup = false

    init(repositoryPath: String) {
        _model = StateObject(wrappedValue: AutoTaskConfigEditorModel(repositoryPath: repositoryPath))
        _setup = StateObject(wrappedValue: AutoTaskSetupModel(repositoryPath: repositoryPath))
    }

    var body: some View {
        if showingSetup {
            AutoTaskSetupView(model: setup) {
                showingSetup = false
                model.reload()
            }
        } else {
            editor
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.loadState {
                case .missing:
                    missingState()
                case .unreadable(let path):
                    unreadableState(path: path)
                case .loaded:
                    sharedFileNotice
                    verifyCommandSection
                    forbiddenPathsSection
                    limitsSection
                    findingsSection
                    saveBar
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.darculaSidebarBackground)
        .sheet(isPresented: $showingDiff) { diffSheet }
    }

    // MARK: - No file yet

    /// No config yet, so this repository has never been set up. The assistant
    /// is the whole answer — it is where all the interaction `/auto-task`
    /// cannot have takes place.
    private func missingState() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                localized: "autoTask.config.missing.title",
                defaultValue: "No auto-task configuration in this repository"
            ))
            .font(.system(size: 14, weight: .semibold))

            Text(String(
                localized: "autoTask.config.missing.body",
                defaultValue: "/auto-task reads .octo-dev/auto-task.conf. Without it there is nothing to decide whether a run's work is valid, and no list of files it must not touch."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(String(
                localized: "autoTask.config.missing.setupIntro",
                defaultValue: "The setup runs once per repository. After it, every autonomous run depends on what is decided there — /auto-task never asks anything."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                showingSetup = true
            } label: {
                Text(String(
                    localized: "autoTask.config.missing.runSetup",
                    defaultValue: "Set up this repository"
                ))
            }
            .keyboardShortcut(.defaultAction)

            if let error = model.saveError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private func unreadableState(path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(
                localized: "autoTask.config.unreadable",
                defaultValue: "Could not read the configuration file."
            ))
            .font(.system(size: 13, weight: .semibold))
            Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Button {
                model.reload()
            } label: {
                Text(String(localized: "autoTask.config.retry", defaultValue: "Retry"))
            }
        }
    }

    // MARK: - Sections

    private var sharedFileNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "person.2")
            Text(String(
                localized: "autoTask.config.sharedNotice",
                defaultValue: "This file is committed to the repository. A change here affects every autonomous run by everyone on the team."
            ))
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.darculaCardBackground))
    }

    private var verifyCommandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("VERIFY_CMD")

            // Given its own warning band rather than being one field among
            // four: editing this value is executing code on other people's
            // machines.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(String(
                    localized: "autoTask.config.verify.danger",
                    defaultValue: "This command is executed on the machine of whoever runs /auto-task, with their permissions and without confirmation."
                ))
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))

            TextField("", text: $model.verifyCommand, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.darculaBorder, lineWidth: 0.5))

            helpText(String(
                localized: "autoTask.config.verify.help",
                defaultValue: "Exit 0 lets the MR open; anything else blocks it and the agent retries, up to three times. It can run up to six times in one execution, so slow commands cost wall-clock, not tokens."
            ))
        }
    }

    private var forbiddenPathsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("FORBIDDEN_PATHS")
            TextField("", text: $model.forbiddenPathsRaw, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.darculaBorder, lineWidth: 0.5))

            helpText(String(
                localized: "autoTask.config.forbidden.help",
                defaultValue: "Comma-separated bash case globs. Touching one aborts the run. Note: * crosses directory separators, so */build.gradle does not cover a root-level build.gradle; and a trailing slash is anchored at the repository root, so fastlane/ does not cover android/fastlane/."
            ))

            pathTester
        }
    }

    /// The most useful part of this screen: the glob semantics have traps that
    /// reading the list does not reveal, so show what the list actually blocks.
    private var pathTester: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(
                    localized: "autoTask.config.tester.title",
                    defaultValue: "Test paths against this list"
                ))
                .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    model.suggestProbePaths()
                } label: {
                    Text(String(
                        localized: "autoTask.config.tester.fill",
                        defaultValue: "Fill from repository"
                    ))
                    .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.darculaAccent)
            }

            TextField("", text: $model.pathProbe, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(3...10)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.darculaBorder, lineWidth: 0.5))

            let results = model.probeResults
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(results, id: \.path) { result in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: result.blockedBy.isEmpty ? "checkmark.circle" : "lock.fill")
                                .foregroundStyle(result.blockedBy.isEmpty ? Color.green : Color.orange)
                            Text(result.path)
                                .font(.system(size: 11, design: .monospaced))
                            Spacer()
                            if let pattern = result.blockedBy.first {
                                Text(pattern)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(String(
                                    localized: "autoTask.config.tester.allowed",
                                    defaultValue: "editable"
                                ))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground.opacity(0.6)))
            }
        }
    }

    private var limitsSection: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("MAX_FILES")
                TextField("", text: $model.maxFiles)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 90)
                helpText(String(
                    localized: "autoTask.config.maxFiles.help",
                    defaultValue: "A circuit breaker, not a quality metric. Above 50 the runs deliver changes too large to review; below 10 legitimate refactors abort."
                ))
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("VERIFY_TIMEOUT")
                TextField("", text: $model.verifyTimeout)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 90)
                helpText(String(
                    localized: "autoTask.config.timeout.help",
                    defaultValue: "Seconds. Should be about 3× the cold-run time you actually measured, never a guess. Requires timeout or gtimeout on the system."
                ))
            }
        }
    }

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.errors) { finding in
                findingRow(finding, color: .red, symbol: "xmark.octagon.fill")
            }
            ForEach(model.warnings) { finding in
                findingRow(finding, color: .orange, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func findingRow(
        _ finding: AutoTaskConfigDiagnostics.Finding,
        color: Color,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(finding.message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.1)))
    }

    private var saveBar: some View {
        HStack(spacing: 8) {
            if let error = model.saveError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            Spacer()
            Button {
                model.revert()
            } label: {
                Text(String(localized: "autoTask.config.revert", defaultValue: "Revert"))
            }
            .disabled(!model.hasChanges)

            Button {
                showingDiff = true
            } label: {
                Text(String(localized: "autoTask.config.reviewSave", defaultValue: "Review & Save"))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
        }
    }

    // MARK: - Diff before saving

    private var diffSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "autoTask.config.diff.title",
                defaultValue: "About to change a file the whole team shares"
            ))
            .font(.system(size: 13, weight: .semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.pendingDiff.enumerated()), id: \.offset) { _, line in
                        Text("\(String(line.marker)) \(line.text)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.marker == "+" ? Color.green : Color.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.darculaCardBackground))

            HStack {
                Spacer()
                Button {
                    showingDiff = false
                } label: {
                    Text(String(localized: "autoTask.config.diff.cancel", defaultValue: "Cancel"))
                }
                Button {
                    model.save()
                    showingDiff = false
                } label: {
                    Text(String(localized: "autoTask.config.diff.confirm", defaultValue: "Save"))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    // MARK: - Bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.darculaForeground.opacity(0.9))
    }

    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
