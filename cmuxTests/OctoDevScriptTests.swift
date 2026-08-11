import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: the octo-dev script contract — `KEY=VALUE` on stdout,
/// `ERROR=<code>` on stderr, meaningful exit code.
///
/// These scripts are maintained outside this repository, so the parser has to
/// tolerate keys it has never seen while still refusing to read arbitrary lines
/// that happen to contain `=`.
@Suite struct OctoDevScriptOutputTests {
    @Test func parsesKeyValueLines() {
        let out = OctoDevScriptOutput(
            stdout: "PROJECT_TYPE=node-js\nVERIFY_CONFIDENCE=high\n",
            stderr: "",
            exitCode: 0
        )
        #expect(out["PROJECT_TYPE"] == "node-js")
        #expect(out["VERIFY_CONFIDENCE"] == "high")
        #expect(out.failed == false)
    }

    /// The value itself may contain `=` — a verify command routinely does.
    @Test func valueMayContainEqualsSigns() {
        let out = OctoDevScriptOutput(
            stdout: "VERIFY_CMD=make ARGS=--all && npm test\n",
            stderr: "",
            exitCode: 0
        )
        #expect(out["VERIFY_CMD"] == "make ARGS=--all && npm test")
    }

    /// A script that echoes a path or a diff line must not have it read as a
    /// value.
    @Test func nonKeyLinesAreIgnored() {
        let out = OctoDevScriptOutput(
            stdout: "some/path=weird\nrunning checks...\nPROJECT_TYPE=rust\n",
            stderr: "",
            exitCode: 0
        )
        #expect(out.values.count == 1)
        #expect(out["PROJECT_TYPE"] == "rust")
    }

    @Test func errorCodeComesFromStandardError() {
        let out = OctoDevScriptOutput(
            stdout: "PROJECT_TYPE=android-native\nVERIFY_CONFIDENCE=low\n",
            stderr: "ERROR=cannot_autodetect_verify_cmd\n",
            exitCode: 1
        )
        #expect(out.errorCode == "cannot_autodetect_verify_cmd")
        #expect(out.failed)
        // The diagnosis on stdout still has to survive the failure — it is what
        // the assistant explains to the user.
        #expect(out["PROJECT_TYPE"] == "android-native")
        #expect(out["VERIFY_CONFIDENCE"] == "low")
    }

    @Test func capturesTheOutputTailBlock() {
        let out = OctoDevScriptOutput(
            stdout: """
            VERIFY_RESULT=fail
            VERIFY_EXIT=1
            ---OUTPUT_TAIL---
            FAIL src/app.test.js
              expected 1 to equal 2
            ---END---
            """,
            stderr: "",
            exitCode: 0
        )
        #expect(out["VERIFY_RESULT"] == "fail")
        #expect(out.outputTail?.contains("expected 1 to equal 2") == true)
        // Lines inside the tail must not be mistaken for keys.
        #expect(out.values.count == 2)
    }

    /// `verify` always exits 0; the verdict is in `VERIFY_RESULT`. Exit code
    /// alone is not the signal.
    @Test func verifyFailureIsNotAnExitCodeFailure() {
        let out = OctoDevScriptOutput(
            stdout: "VERIFY_RESULT=fail\nTIMEOUT_SUPPORT=yes\n",
            stderr: "",
            exitCode: 0
        )
        #expect(out.failed == false)
        #expect(out["VERIFY_RESULT"] == "fail")
    }

    @Test func lastValueWinsForARepeatedKey() {
        let out = OctoDevScriptOutput(stdout: "MAX_FILES=10\nMAX_FILES=25\n", stderr: "", exitCode: 0)
        #expect(out["MAX_FILES"] == "25")
    }
}

/// Chatmux-only: launching the scripts.
///
/// Every octo-dev script resolves the repository with `git rev-parse`, so the
/// working directory is what selects the repository — passing the wrong one
/// would configure the wrong project.
@Suite struct OctoDevScriptRunnerTests {
    private func withFakeScripts(
        _ body: (OctoDevScriptRunner, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctoDevRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var runner = OctoDevScriptRunner()
        runner.directory = scripts
        try body(runner, root)
    }

    private func install(
        _ name: String,
        body: String,
        in root: URL
    ) throws {
        let url = root.appendingPathComponent("scripts/\(name)")
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// With no fallback by design, a missing script is reported, not worked
    /// around — there is no second source of truth.
    @Test func missingScriptIsReportedNotWorkedAround() throws {
        try withFakeScripts { runner, root in
            #expect(runner.isInstalled(.autoTask) == false)
            #expect(throws: OctoDevScriptRunner.Failure.notInstalled(.autoTask)) {
                try runner.run(
                    .autoTask,
                    arguments: ["init-config", "--auto"],
                    repositoryPath: root.appendingPathComponent("repo").path
                )
            }
        }
    }

    @Test func parsesASuccessfulRun() throws {
        try withFakeScripts { runner, root in
            try install("auto-task.sh", body: "echo PROJECT_TYPE=node-js; echo VERIFY_CONFIDENCE=high", in: root)
            let out = try runner.run(
                .autoTask,
                arguments: ["init-config", "--auto"],
                repositoryPath: root.appendingPathComponent("repo").path
            )
            #expect(out["PROJECT_TYPE"] == "node-js")
            #expect(out.failed == false)
        }
    }

    @Test func parsesAFailedRunWithItsDiagnosis() throws {
        try withFakeScripts { runner, root in
            try install(
                "auto-task.sh",
                body: """
                echo PROJECT_TYPE=android-native
                echo VERIFY_CONFIDENCE=low
                echo ERROR=cannot_autodetect_verify_cmd >&2
                exit 1
                """,
                in: root
            )
            let out = try runner.run(
                .autoTask,
                arguments: ["init-config", "--auto"],
                repositoryPath: root.appendingPathComponent("repo").path
            )
            #expect(out.errorCode == "cannot_autodetect_verify_cmd")
            #expect(out.exitCode == 1)
            #expect(out["PROJECT_TYPE"] == "android-native")
        }
    }

    /// The scripts have no path argument: the working directory is what picks
    /// the repository.
    @Test func runsWithTheRepositoryAsWorkingDirectory() throws {
        try withFakeScripts { runner, root in
            try install("auto-task.sh", body: "echo CWD_NAME=$(basename \"$PWD\")", in: root)
            let out = try runner.run(
                .autoTask,
                arguments: [],
                repositoryPath: root.appendingPathComponent("repo").path
            )
            #expect(out["CWD_NAME"] == "repo")
        }
    }

    /// A script that writes more than a pipe buffer must not deadlock the
    /// caller waiting on exit.
    @Test func largeOutputDoesNotDeadlock() throws {
        try withFakeScripts { runner, root in
            try install(
                "auto-task.sh",
                body: "for i in $(seq 1 5000); do echo \"line $i padding padding padding padding\"; done; echo DONE=yes",
                in: root
            )
            let out = try runner.run(
                .autoTask,
                arguments: [],
                repositoryPath: root.appendingPathComponent("repo").path
            )
            #expect(out["DONE"] == "yes")
        }
    }
}

/// Chatmux-only: the assistant's decisions, kept out of the UI so they can be
/// tested without a window or a subprocess.
@Suite struct AutoTaskSetupPolicyTests {
    // MARK: - preconditions
    //
    // A project is a saved workspace, and a workspace is any directory — it can
    // be a folder where nothing has been started. `/auto-task` resolves GitLab
    // issues, so it needs a repository; the assistant has to say that at the
    // door rather than at step 2, where the script answers
    // `ERROR=not_in_git_repo` after the user has already made choices.

    private func withDirectory(_ files: [String], _ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDetectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
        try body(root.path)
    }

    @Test func aPlainFolderIsNotARepository() throws {
        try withDirectory(["README.md"]) {
            #expect(AutoTaskSetupPolicy.isInsideGitRepository($0) == false)
        }
    }

    @Test func aCloneIsARepository() throws {
        try withDirectory([".git/HEAD"]) {
            #expect(AutoTaskSetupPolicy.isInsideGitRepository($0))
        }
    }

    /// In a worktree `.git` is a *file*, not a directory. Checking for a
    /// directory would call every worktree "not a repository" — and worktrees
    /// are the normal case here, since /start-task creates one per issue.
    @Test func aWorktreeIsARepository() throws {
        try withDirectory([".git"]) {
            #expect(AutoTaskSetupPolicy.isInsideGitRepository($0))
        }
    }

    /// A subdirectory of a repository counts: the panel may be pointed at one.
    @Test func aSubdirectoryOfARepositoryCounts() throws {
        try withDirectory([".git/HEAD", "src/app/main.swift"]) { root in
            #expect(AutoTaskSetupPolicy.isInsideGitRepository(root + "/src/app"))
        }
    }

    /// Must terminate at `/` rather than looping on its own parent.
    @Test func walkingUpTerminates() {
        _ = AutoTaskSetupPolicy.isInsideGitRepository("/")
        #expect(Bool(true), "returned instead of looping forever")
    }

    // MARK: - verification level

    /// `./gradlew test` does not assemble the APK, so a broken layout passes
    /// the tests and then fails to compile.
    @Test func mobileDefaultsToBuildingTheBinary() {
        #expect(AutoTaskSetupPolicy.recommendedLevel(projectType: "android-native", hasSnapshotTests: false) == .testsAndBuild)
        #expect(AutoTaskSetupPolicy.recommendedLevel(projectType: "ios-native", hasSnapshotTests: false) == .testsAndBuild)
        #expect(AutoTaskSetupPolicy.recommendedLevel(projectType: "flutter", hasSnapshotTests: false) == .testsAndBuild)
    }

    @Test func nonMobileDefaultsToUnitTests() {
        #expect(AutoTaskSetupPolicy.recommendedLevel(projectType: "rust", hasSnapshotTests: false) == .unitTests)
        #expect(AutoTaskSetupPolicy.recommendedLevel(projectType: "node-js", hasSnapshotTests: false) == .unitTests)
    }

    @Test func snapshotTestsWinWhenThereAreAny() {
        #expect(AutoTaskSetupPolicy.recommendedLevel(projectType: "android-native", hasSnapshotTests: true) == .testsBuildAndSnapshots)
    }

    @Test func detectsSnapshotFrameworksInAManifest() {
        #expect(AutoTaskSetupPolicy.mentionsSnapshotTesting("testImplementation 'app.cash.paparazzi:paparazzi:1.3.1'"))
        #expect(AutoTaskSetupPolicy.mentionsSnapshotTesting("io.github.takahirom.roborazzi"))
        #expect(AutoTaskSetupPolicy.mentionsSnapshotTesting("golden_toolkit: ^0.15.0"))
        #expect(AutoTaskSetupPolicy.mentionsSnapshotTesting("implementation 'com.squareup.retrofit2'") == false)
    }

    // MARK: - timeout

    /// About 3× what was actually measured, never a guess.
    @Test func timeoutIsThreeTimesTheMeasuredRun() {
        #expect(AutoTaskSetupPolicy.suggestedTimeout(measuredSeconds: 200) == 600)
        #expect(AutoTaskSetupPolicy.suggestedTimeout(measuredSeconds: 900) == 2700)
    }

    /// A fast sample does not mean a fast worst case: cold caches and busy
    /// machines are not in the measurement.
    @Test func timeoutNeverGoesBelowTheFloor() {
        #expect(AutoTaskSetupPolicy.suggestedTimeout(measuredSeconds: 1) == 300)
        #expect(AutoTaskSetupPolicy.suggestedTimeout(measuredSeconds: 99) == 300)
        #expect(AutoTaskSetupPolicy.suggestedTimeout(measuredSeconds: 101) == 303)
    }

    // MARK: - findings

    /// The most valuable thing the assistant can find: verification already
    /// fails on the base branch, so every future run would abort after twenty
    /// minutes of wasted work.
    @Test func failureOnTheBaseBranchIsReported() {
        let found = AutoTaskSetupPolicy.findings(
            result: "fail", timeoutSupport: "yes", measuredSeconds: 30, projectType: "node-js"
        )
        #expect(found.contains(.failsOnBaseBranch))
    }

    @Test func suspiciouslyFastPassIsReportedOnCompiledProjects() {
        let fast = AutoTaskSetupPolicy.findings(
            result: "pass", timeoutSupport: "yes", measuredSeconds: 0.4, projectType: "android-native"
        )
        #expect(fast.contains(.suspiciouslyFast(0.4)))

        // A scripting project can legitimately verify in well under a second.
        let scripted = AutoTaskSetupPolicy.findings(
            result: "pass", timeoutSupport: "yes", measuredSeconds: 0.4, projectType: "python"
        )
        #expect(scripted.contains { if case .suspiciouslyFast = $0 { return true }; return false } == false)
    }

    @Test func missingTimeoutSupportIsReported() {
        let found = AutoTaskSetupPolicy.findings(
            result: "pass", timeoutSupport: "no", measuredSeconds: 40, projectType: "rust"
        )
        #expect(found.contains(.noTimeoutSupport))
    }

    @Test func aCleanRunHasNoFindings() {
        let found = AutoTaskSetupPolicy.findings(
            result: "pass", timeoutSupport: "yes", measuredSeconds: 40, projectType: "rust"
        )
        #expect(found.isEmpty)
    }

    @Test func timeoutResultIsReported() {
        let found = AutoTaskSetupPolicy.findings(
            result: "timeout", timeoutSupport: "yes", measuredSeconds: 1800, projectType: "ios-native"
        )
        #expect(found.contains(.timedOut))
    }

    // MARK: - explanations

    @Test func explanationIsSpecificToTheStack() {
        let android = AutoTaskSetupPolicy.explanation(
            forErrorCode: "cannot_autodetect_verify_cmd", projectType: "android-native"
        )
        #expect(android.contains("gradlew"))

        let node = AutoTaskSetupPolicy.explanation(
            forErrorCode: "cannot_autodetect_verify_cmd", projectType: "node-js"
        )
        #expect(node.contains("package.json"))
        #expect(android != node)
    }

    @Test func unknownErrorCodeStillSaysWhatHappened() {
        let text = AutoTaskSetupPolicy.explanation(forErrorCode: "some_new_code", projectType: "go")
        #expect(text.contains("some_new_code"))
    }
}
