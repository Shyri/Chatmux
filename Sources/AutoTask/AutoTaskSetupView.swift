import SwiftUI

/// The one-time setup assistant for `/auto-task`.
///
/// It is the reverse of the command it configures: `/auto-task` asks nothing,
/// so this asks a lot. The user is deciding what "verified" will mean for this
/// repository for months, so every step explains the consequence, not just the
/// field.
struct AutoTaskSetupView: View {
    @ObservedObject var model: AutoTaskSetupModel
    let onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.isInsideGitRepository {
                        notARepository
                    } else if model.canRun {
                        stepContent
                    } else {
                        missingToolkit
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.darculaSidebarBackground)
        .task {
            model.refreshInstalledScripts()
            // `.task` rather than `.onAppear`: detection shells out, and every
            // one of these scripts can take seconds. None of it may block the
            // main thread.
            if model.canRun, model.projectType.isEmpty { await model.detectProject() }
        }
    }

    // MARK: - Chrome

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(AutoTaskSetupModel.Step.allCases, id: \.rawValue) { step in
                let isCurrent = step == model.step
                let isPast = step < model.step
                Text(step.title)
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(
                        isCurrent ? Color.darculaAccent
                            : (isPast ? Color.darculaForeground.opacity(0.6) : Color.darculaForeground.opacity(0.3))
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCurrent ? Color.darculaAccent.opacity(0.15) : Color.clear)
                    )
                if step != .done {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7))
                        .foregroundStyle(Color.darculaForeground.opacity(0.25))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A project can be any directory — including one where nothing has been
    /// started. Say so at the door instead of letting the user through five
    /// steps to a script that answers `ERROR=not_in_git_repo`.
    private var notARepository: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                String(
                    localized: "autoTask.setup.notARepo.title",
                    defaultValue: "This project is not in a git repository"
                ),
                systemImage: "info.circle.fill"
            )
            .font(.system(size: 13, weight: .semibold))

            Text(String(
                localized: "autoTask.setup.notARepo.body",
                defaultValue: "/auto-task resolves GitLab issues end to end, so it needs a repository to work in. A project does not — it can be any folder, including one where nothing has been started yet. This particular feature just has nothing to do here."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(model.repositoryPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                model.refreshInstalledScripts()
            } label: {
                Text(String(
                    localized: "autoTask.setup.notARepo.recheck",
                    defaultValue: "Check again"
                ))
            }
        }
    }

    /// With no fallback by design, a missing script is a wall, not a detour.
    private var missingToolkit: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                String(
                    localized: "autoTask.setup.missing.title",
                    defaultValue: "The octo-dev toolkit is not fully installed"
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.orange)

            Text(String(
                localized: "autoTask.setup.missing.body",
                defaultValue: "These scripts write and validate the configuration. cmux does not reimplement them on purpose: they are the same logic /auto-task itself uses, and a second copy here would drift from it without anyone noticing."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(model.missingScripts, id: \.rawValue) { script in
                Text("~/.claude/scripts/\(script.rawValue)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
            }

            Button {
                model.refreshInstalledScripts()
            } label: {
                Text(String(localized: "autoTask.setup.missing.recheck", defaultValue: "Check again"))
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .detect: detectStep
        case .propose: proposeStep
        case .level: levelStep
        case .write: writeStep
        case .validate: validateStep
        case .reviewer: reviewerStep
        case .done: doneStep
        }
    }

    // MARK: - 1 · Detect

    private var detectStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "autoTask.setup.detect.title", defaultValue: "What kind of project is this?"))

            if model.projectType.isEmpty {
                ProgressView().controlSize(.small)
            } else if model.projectType == "unknown" {
                Text(String(
                    localized: "autoTask.setup.detect.unknown",
                    defaultValue: "The stack could not be recognized. Detection only looks at the repository root, so a monorepo or an unusual layout lands here. Tell it what this project is:"
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $model.manualProjectType) {
                    Text(String(localized: "autoTask.setup.detect.pick", defaultValue: "Choose…")).tag("")
                    ForEach(Self.projectTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(model.projectType).font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                if !model.platforms.isEmpty {
                    Text(String(
                        localized: "autoTask.setup.detect.platforms",
                        defaultValue: "Platforms: \(model.platforms.joined(separator: ", "))"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }

            phaseFooter
            navigation(canContinue: !model.effectiveProjectType.isEmpty) {
                model.advance()
                Task { await model.runAutoProposal() }
            }
        }
    }

    private static let projectTypes = [
        "android-native", "ios-native", "flutter", "swift-package",
        "node-js", "rust", "go", "python",
    ]

    // MARK: - 2 · Proposal

    private var proposeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "autoTask.setup.propose.title", defaultValue: "Can the toolkit configure this on its own?"))

            if model.autoProposalSucceeded {
                Label(
                    String(
                        localized: "autoTask.setup.propose.ok",
                        defaultValue: "Yes. Here is what it wrote, as a starting point you can edit."
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 12))
                .foregroundStyle(.green)

                proposedValues
            } else if let explanation = model.autoFailureExplanation {
                Label(
                    String(
                        localized: "autoTask.setup.propose.refused",
                        defaultValue: "No — and it refused to guess."
                    ),
                    systemImage: "info.circle.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)

                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(
                    localized: "autoTask.setup.propose.refusedWhy",
                    defaultValue: "This is the normal case, not a failure. A verify command that passes without testing anything produces merge requests that look verified and are not — the worst thing this system can do. You supply the command in the next step."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.darculaCardBackground))
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(
                        localized: "autoTask.setup.propose.working",
                        defaultValue: "Asking the toolkit… on an Xcode project this resolves the scheme and can take half a minute."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            phaseFooter
            navigation(canContinue: model.phase != .running) { model.advance() }
        }
    }

    private var proposedValues: some View {
        VStack(alignment: .leading, spacing: 4) {
            keyValue("VERIFY_CMD", model.verifyCommand)
            keyValue("FORBIDDEN_PATHS", model.forbiddenPaths)
            keyValue("MAX_FILES", model.maxFiles)
            keyValue("VERIFY_TIMEOUT", model.verifyTimeout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.darculaCardBackground))
    }

    // MARK: - 3 · Level

    private var levelStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "autoTask.setup.level.title", defaultValue: "What should \"verified\" mean here?"))

            Text(String(
                localized: "autoTask.setup.level.intro",
                defaultValue: "This is the decision that governs every autonomous run from now on. /auto-task will never ask again."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(AutoTaskSetupPolicy.VerificationLevel.allCases, id: \.rawValue) { candidate in
                if candidate != .testsBuildAndSnapshots || model.detectedSnapshotFramework != nil {
                    levelRow(candidate)
                }
            }

            if model.detectedSnapshotFramework == nil {
                Text(String(
                    localized: "autoTask.setup.level.noSnapshots",
                    defaultValue: "No snapshot-testing framework was found in this repository, so that level is not offered."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            navigation(canContinue: true) {
                model.applyLevel()
                model.advance()
            }
        }
    }

    private func levelRow(_ candidate: AutoTaskSetupPolicy.VerificationLevel) -> some View {
        let isSelected = model.level == candidate
        return Button {
            model.level = candidate
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.darculaAccent : Color.darculaForeground.opacity(0.4))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.title).font(.system(size: 12, weight: .semibold))
                        if candidate == AutoTaskSetupPolicy.recommendedLevel(
                            projectType: model.effectiveProjectType,
                            hasSnapshotTests: model.detectedSnapshotFramework != nil
                        ) {
                            Text(String(localized: "autoTask.setup.level.recommended", defaultValue: "recommended"))
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.darculaAccent.opacity(0.2)))
                                .foregroundStyle(Color.darculaAccent)
                        }
                    }
                    Text(candidate.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if candidate == .testsBuildAndSnapshots, let framework = model.detectedSnapshotFramework {
                        Text(String(
                            localized: "autoTask.setup.level.detectedFramework",
                            defaultValue: "Detected: \(framework). Add its task to the command yourself — the task name depends on your module layout, and a wrong one would silently verify nothing."
                        ))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.darculaAccent.opacity(0.08) : Color.darculaCardBackground)
        )
    }

    // MARK: - 4 · Write

    private var writeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "autoTask.setup.write.title", defaultValue: "Review before writing"))

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

            field("VERIFY_CMD", text: $model.verifyCommand, monospaced: true, lines: 1...4)
            field("FORBIDDEN_PATHS", text: $model.forbiddenPaths, monospaced: true, lines: 2...5)
            HStack(spacing: 16) {
                shortField("MAX_FILES", text: $model.maxFiles)
                shortField("VERIFY_TIMEOUT", text: $model.verifyTimeout)
            }

            phaseFooter
            navigation(
                canContinue: !model.verifyCommand.trimmingCharacters(in: .whitespaces).isEmpty
            ) {
                Task { if await model.writeConfiguration() { model.advance() } }
            }
        }
    }

    // MARK: - 5 · Validate

    private var validateStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "autoTask.setup.validate.title", defaultValue: "Run it once, for real"))

            Text(String(
                localized: "autoTask.setup.validate.intro",
                defaultValue: "This runs the verification on the clean base branch. If it fails here, /auto-task would abort on every single issue after twenty minutes of work — which is exactly what this step exists to find out before that happens."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if model.isVerifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.elapsed(model.verifyElapsed))
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button {
                        model.cancelValidation()
                    } label: {
                        Text(String(localized: "autoTask.setup.validate.cancel", defaultValue: "Cancel"))
                    }
                }
            }

            if !model.verifyLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.verifyLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.darculaCardBackground))
            }

            if let result = model.verifyResult {
                verdict(result)
            }

            ForEach(Array(model.verifyFindings.enumerated()), id: \.offset) { _, finding in
                findingRow(finding)
            }

            phaseFooter
            HStack {
                if !model.isVerifying && model.verifyResult == nil {
                    Button {
                        model.startValidation()
                    } label: {
                        Text(String(localized: "autoTask.setup.validate.run", defaultValue: "Run verification"))
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Spacer()
                Button { model.goBack() } label: {
                    Text(String(localized: "autoTask.setup.back", defaultValue: "Back"))
                }
                Button {
                    model.advance()
                } label: {
                    Text(String(localized: "autoTask.setup.next", defaultValue: "Continue"))
                }
                .disabled(model.isVerifying)
            }
        }
    }

    private func verdict(_ result: String) -> some View {
        let passed = result == "pass"
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                passed
                    ? String(
                        localized: "autoTask.setup.validate.passed",
                        defaultValue: "Passed in \(Self.elapsed(model.verifyElapsed))"
                    )
                    : String(
                        localized: "autoTask.setup.validate.failedVerdict",
                        defaultValue: "Verification failed on the base branch"
                    ),
                systemImage: passed ? "checkmark.circle.fill" : "xmark.octagon.fill"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(passed ? Color.green : Color.red)

            if let suggested = model.suggestedTimeout, passed {
                HStack(spacing: 8) {
                    Text(String(
                        localized: "autoTask.setup.validate.suggestTimeout",
                        defaultValue: "Suggested VERIFY_TIMEOUT: \(suggested)s — three times what was just measured, never a guess."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        Task { await model.applySuggestedTimeout() }
                    } label: {
                        Text(String(localized: "autoTask.setup.validate.applyTimeout", defaultValue: "Apply"))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((passed ? Color.green : Color.red).opacity(0.1))
        )
    }

    private func findingRow(_ finding: AutoTaskSetupPolicy.VerifyFinding) -> some View {
        let text: String
        switch finding {
        case .failsOnBaseBranch:
            text = String(
                localized: "autoTask.setup.finding.baseFails",
                defaultValue: "The command fails on a clean base branch. Until that is fixed, every /auto-task run aborts. Fix the repository, or choose a different command."
            )
        case .suspiciouslyFast:
            text = String(
                localized: "autoTask.setup.finding.tooFast",
                defaultValue: "It passed in under two seconds on a compiled project. That usually means it did not actually run any tests."
            )
        case .noTimeoutSupport:
            text = String(
                localized: "autoTask.setup.finding.noTimeout",
                defaultValue: "This system has no timeout/gtimeout, so a hung verification blocks the run indefinitely. Installing coreutils fixes it."
            )
        case .timedOut:
            text = String(
                localized: "autoTask.setup.finding.timedOut",
                defaultValue: "The command hit VERIFY_TIMEOUT. Either it hangs, or the timeout is too low for this project."
            )
        }
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.1)))
    }

    // MARK: - 6 · Reviewer

    private var reviewerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "autoTask.setup.reviewer.title", defaultValue: "Who reviews the merge requests?"))

            Text(String(
                localized: "autoTask.setup.reviewer.intro",
                defaultValue: "Without .octo-dev/mr-create.yaml, /auto-task aborts in its first second. It lives with another command but it is part of this setup."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if model.hasReviewerFile {
                Label(
                    String(localized: "autoTask.setup.reviewer.present", defaultValue: "mr-create.yaml is already in place."),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 12))
                .foregroundStyle(.green)
            }

            HStack(spacing: 8) {
                TextField(
                    String(localized: "autoTask.setup.reviewer.placeholder", defaultValue: "GitLab username"),
                    text: $model.reviewerUsername
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                Button {
                    Task { await model.setReviewer() }
                } label: {
                    Text(String(localized: "autoTask.setup.reviewer.set", defaultValue: "Set reviewer"))
                }
                .disabled(model.reviewerUsername.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            phaseFooter
            navigation(canContinue: model.hasReviewerFile) { model.advance() }
        }
    }

    // MARK: - 7 · Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(String(localized: "autoTask.setup.done.title", defaultValue: "Ready"))

            Label(
                String(
                    localized: "autoTask.setup.done.shared",
                    defaultValue: "Everything in .octo-dev/ is committed and shared with the team. Commit it, and remember that changing it later changes everyone's autonomous runs."
                ),
                systemImage: "person.2.fill"
            )
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)

            Text(String(
                localized: "autoTask.setup.done.review",
                defaultValue: "One last thing worth doing: check what FORBIDDEN_PATHS actually blocks. The globs have two traps that make a wrong pattern silently protect nothing."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button {
                    onFinished()
                } label: {
                    Text(String(
                        localized: "autoTask.setup.done.openEditor",
                        defaultValue: "Open the configuration editor"
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Bits

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold))
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        monospaced: Bool,
        lines: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
            TextField("", text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .lineLimit(lines)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.darculaCardBackground))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.darculaBorder, lineWidth: 0.5))
        }
    }

    private func shortField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 110)
        }
    }

    @ViewBuilder
    private var phaseFooter: some View {
        if case .failed(let message) = model.phase {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.red.opacity(0.1)))
        }
    }

    private func navigation(canContinue: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            if model.step != .detect {
                Button { model.goBack() } label: {
                    Text(String(localized: "autoTask.setup.back", defaultValue: "Back"))
                }
            }
            Button(action: action) {
                Text(String(localized: "autoTask.setup.next", defaultValue: "Continue"))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }

    private static func elapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
