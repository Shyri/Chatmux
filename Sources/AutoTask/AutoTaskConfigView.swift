import SwiftUI

/// Editor for `.octo-dev/auto-task.conf`, opened as a workspace tab.
///
/// Not a text editor: each parameter is shown with what it means and what
/// getting it wrong costs, because this file is committed and a mistake in it
/// affects every autonomous run by every member of the team.
///
/// The file has two shapes and so does this screen. A single-project repository
/// is a flat form. A monorepo is a tree — the global block, then one block per
/// `[section]` — because that is what the file is, and flattening it would show
/// a `VERIFY_CMD` that does not exist and hide the four that do.
struct AutoTaskConfigView: View {
    @StateObject private var model: AutoTaskConfigEditorModel
    @StateObject private var setup: AutoTaskSetupModel
    @State private var showingDiff = false
    /// Step 0 of the assistant's flow: with a config already present, do not
    /// launch the wizard — show the configuration and offer to edit it.
    @State private var showingSetup = false
    @State private var addingSection = false
    @State private var newSectionName = ""
    @State private var newSectionPath = ""

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
                    loadedBody
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.darculaSidebarBackground)
        .task {
            // Off the main thread: `detect-project` shells out, and the editor
            // must not freeze while it runs.
            await model.refreshProjectType()
        }
        .sheet(isPresented: $showingDiff) { diffSheet }
        .sheet(isPresented: $addingSection) { addSectionSheet }
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

            // Same check the assistant makes, surfaced one screen earlier: a
            // project can be any folder, and offering setup for one that has no
            // repository sends the user into a dead end.
            if AutoTaskSetupPolicy.isInsideGitRepository(model.repositoryPath) {
                Button {
                    showingSetup = true
                } label: {
                    Text(String(
                        localized: "autoTask.config.missing.runSetup",
                        defaultValue: "Set up this repository"
                    ))
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Text(String(
                    localized: "autoTask.config.missing.notARepo",
                    defaultValue: "This project is not in a git repository, and /auto-task needs one — it resolves GitLab issues. Nothing to configure here."
                ))
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

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

    // MARK: - Loaded

    /// Validation runs **once** here and is handed down.
    ///
    /// Every access to it re-parses and re-validates the whole file; asking
    /// once per section would make that quadratic in the number of
    /// sub-projects, on every keystroke.
    private var loadedBody: some View {
        let findings = model.findingsByScope
        let types = model.sectionProjectTypes
        return VStack(alignment: .leading, spacing: 16) {
            sharedFileNotice
            if model.isMonorepo {
                monorepoBody(findings: findings, types: types)
            } else {
                singleProjectBody(findings: findings[nil] ?? [])
            }
            pathTester
            saveBar
        }
    }

    private func singleProjectBody(
        findings: [AutoTaskConfigDiagnostics.Finding]
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            verifyCommandSection
            forbiddenPathsSection(
                text: $model.forbiddenPathsRaw,
                help: String(
                    localized: "autoTask.config.forbidden.help",
                    defaultValue: "Comma-separated bash case globs. Touching one aborts the run. Note: * crosses directory separators, so */build.gradle does not cover a root-level build.gradle; and a trailing slash is anchored at the repository root, so fastlane/ does not cover android/fastlane/."
                )
            )
            limitsSection
            findingRows(findings)
        }
    }

    // MARK: - Monorepo

    private func monorepoBody(
        findings: [String?: [AutoTaskConfigDiagnostics.Finding]],
        types: [String: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            monorepoNotice
            globalBlock(findings: findings[nil] ?? [])
            ForEach($model.sections) { $section in
                AutoTaskConfigSectionView(
                    section: $section,
                    findings: findings[section.name] ?? [],
                    projectType: types[section.path.trimmingCharacters(in: .whitespaces)] ?? "",
                    globalTimeout: model.verifyTimeout,
                    onRemove: { model.removeSection(id: section.id) }
                )
            }
            undeclaredProjectsNotice
            addSectionButton
        }
    }

    private var monorepoNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "square.stack.3d.up")
            Text(String(
                localized: "autoTask.config.monorepo.notice",
                defaultValue: "This repository is configured as \(model.sections.count) sub-projects. A run verifies only the ones its change touches; a change that touches none reports no_project_affected and is not verified at all."
            ))
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.darculaCardBackground))
    }

    private func globalBlock(findings: [AutoTaskConfigDiagnostics.Finding]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "autoTask.config.global.title",
                defaultValue: "Repository-wide"
            ))
            .font(.system(size: 12, weight: .semibold))

            forbiddenPathsSection(
                text: $model.forbiddenPathsRaw,
                help: String(
                    localized: "autoTask.config.global.forbiddenHelp",
                    defaultValue: "Relative to the repository root. Only these can protect files that live at the root — CI configuration, .octo-dev — because a section's globs are rewritten under its PATH and can never reach them."
                )
            )
            limitsSection
            findingRows(findings)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.darculaCardBackground.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.darculaBorder, lineWidth: 0.5))
    }

    /// Sub-projects that exist on disk but are not in the file.
    ///
    /// Worth its own block because the failure is silent: `init-config --auto`
    /// skips whatever it cannot derive a command for, and a change landing
    /// there is reported as verified when nothing ran.
    @ViewBuilder
    private var undeclaredProjectsNotice: some View {
        let undeclared = model.undeclaredProjects
        if !undeclared.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "questionmark.folder").foregroundStyle(.orange)
                    Text(String(
                        localized: "autoTask.config.undeclared.title",
                        defaultValue: "Found in the repository but not in this file. A change touching one of these is never verified."
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))

                ForEach(undeclared) { project in
                    HStack(spacing: 8) {
                        Text(project.path)
                            .font(.system(size: 11, design: .monospaced))
                        Text(project.projectType)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.addSection(from: project)
                        } label: {
                            Text(String(
                                localized: "autoTask.config.undeclared.add",
                                defaultValue: "Add"
                            ))
                            .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.darculaAccent)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
        }
    }

    private var addSectionButton: some View {
        Button {
            newSectionName = model.availableSectionName()
            newSectionPath = ""
            addingSection = true
        } label: {
            Label {
                Text(String(
                    localized: "autoTask.config.addSection",
                    defaultValue: "Add sub-project"
                ))
            } icon: {
                Image(systemName: "plus")
            }
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.darculaAccent)
    }

    private var addSectionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "autoTask.config.addSection.title",
                defaultValue: "New sub-project"
            ))
            .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "autoTask.config.addSection.name", defaultValue: "Name"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                TextField("", text: $newSectionName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("PATH")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                TextField("", text: $newSectionPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text(String(
                    localized: "autoTask.config.addSection.pathHelp",
                    defaultValue: "Relative to the repository root, with no leading ./"
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    addingSection = false
                } label: {
                    Text(String(localized: "autoTask.config.addSection.cancel", defaultValue: "Cancel"))
                }
                Button {
                    model.addSection(named: newSectionName, path: newSectionPath)
                    addingSection = false
                } label: {
                    Text(String(localized: "autoTask.config.addSection.confirm", defaultValue: "Add"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    newSectionName.trimmingCharacters(in: .whitespaces).isEmpty
                        || newSectionPath.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    // MARK: - Shared blocks

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

    private func forbiddenPathsSection(text: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("FORBIDDEN_PATHS")
            TextField("", text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.darculaBorder, lineWidth: 0.5))

            helpText(help)
        }
    }

    /// The most useful part of this screen: the glob semantics have traps that
    /// reading the list does not reveal, so show what the list actually blocks.
    ///
    /// In a monorepo it tests against the **effective** list — global plus every
    /// section's rewritten under its `PATH` — which is what the guard enforces
    /// and is not something anyone can assemble by reading the file.
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

            if model.isMonorepo {
                helpText(String(
                    localized: "autoTask.config.tester.effectiveHelp",
                    defaultValue: "Tested against what the guard really enforces: the repository-wide globs plus every sub-project's, rewritten under its PATH."
                ))
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
                    ForEach(results) { result in
                        probeRow(result)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground.opacity(0.6)))
            }
        }
    }

    private func probeRow(_ result: AutoTaskConfigEditorModel.ProbeResult) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: result.blockedBy.isEmpty ? "checkmark.circle" : "lock.fill")
                .foregroundStyle(result.blockedBy.isEmpty ? Color.green : Color.orange)
            Text(result.path)
                .font(.system(size: 11, design: .monospaced))
            Spacer()
            if let hit = result.blockedBy.first {
                HStack(spacing: 4) {
                    Text(hit.pattern)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let section = hit.section {
                        Text("[\(section)]")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.darculaAccent)
                    }
                }
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

    private func findingRows(_ findings: [AutoTaskConfigDiagnostics.Finding]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(findings) { finding in
                AutoTaskConfigFindingRow(finding: finding)
            }
        }
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
