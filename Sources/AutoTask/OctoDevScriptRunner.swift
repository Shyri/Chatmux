import Foundation

/// Runs the octo-dev scripts installed under `~/.claude/scripts/`.
///
/// Every one of them resolves the repository with `git rev-parse`, so the
/// working directory is what selects the repository — there is no path
/// argument. Getting that wrong would configure the wrong project, so the cwd
/// is always set explicitly and never inherited.
///
/// cmux does not reimplement what these scripts do. They are the authority: the
/// same logic decides what `/auto-task` and `/mr-review` see, and a second
/// implementation here would drift from them silently.
struct OctoDevScriptRunner {
    enum Script: String {
        case autoTask = "auto-task.sh"
        case mrReview = "mr-review.sh"
        case mrCreate = "mr-create.sh"
    }

    enum Failure: Error, Equatable {
        /// The script is not installed. Reported rather than worked around:
        /// there is no second source of truth to fall back to.
        case notInstalled(Script)
        case couldNotLaunch(String)
    }

    /// Where the toolkit installs its scripts.
    var directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/scripts", isDirectory: true)

    func url(for script: Script) -> URL {
        directory.appendingPathComponent(script.rawValue, isDirectory: false)
    }

    func isInstalled(_ script: Script) -> Bool {
        FileManager.default.isExecutableFile(atPath: url(for: script).path)
    }

    /// Run a script to completion and parse its output.
    ///
    /// `repositoryPath` becomes the process's working directory — see the note
    /// above about `git rev-parse`.
    func run(
        _ script: Script,
        arguments: [String],
        repositoryPath: String
    ) throws -> OctoDevScriptOutput {
        guard isInstalled(script) else { throw Failure.notInstalled(script) }

        let process = Process()
        process.executableURL = url(for: script)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            throw Failure.couldNotLaunch(error.localizedDescription)
        }

        // Read both pipes before waiting: a script that fills one buffer while
        // cmux waits on exit would deadlock.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let lock = NSLock()
        for (handle, isStdout) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                lock.lock()
                if isStdout { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        process.waitUntilExit()

        return OctoDevScriptOutput(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Run a long script, streaming its combined output as it arrives.
    ///
    /// This is for `verify`, which runs the project's real build and can take
    /// fifteen minutes on a cold `xcodebuild`. Nobody should watch a spinner
    /// for that long with no output and no way out, so the caller gets lines as
    /// they appear and a handle to cancel.
    ///
    /// `onLine` and `onFinish` are delivered on the main queue.
    @discardableResult
    func stream(
        _ script: Script,
        arguments: [String],
        repositoryPath: String,
        onLine: @escaping (String) -> Void,
        onFinish: @escaping (Result<OctoDevScriptOutput, Failure>) -> Void
    ) -> OctoDevRunHandle? {
        guard isInstalled(script) else {
            DispatchQueue.main.async { onFinish(.failure(.notInstalled(script))) }
            return nil
        }

        let process = Process()
        process.executableURL = url(for: script)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collected = OctoDevStreamBuffer()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collected.appendStandardOutput(text)
            DispatchQueue.main.async {
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    onLine(line)
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collected.appendStandardError(text)
        }

        process.terminationHandler = { finished in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let output = OctoDevScriptOutput(
                stdout: collected.standardOutput,
                stderr: collected.standardError,
                exitCode: finished.terminationStatus
            )
            DispatchQueue.main.async { onFinish(.success(output)) }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { onFinish(.failure(.couldNotLaunch(error.localizedDescription))) }
            return nil
        }
        return OctoDevRunHandle(process: process)
    }
}

/// Cancels a streaming run.
final class OctoDevRunHandle {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    /// SIGTERM rather than SIGKILL: a verify command is usually a build tool
    /// with children of its own, and it should get the chance to tear them down.
    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

/// Thread-safe accumulator for a streaming run's output — the readability
/// handlers fire on an arbitrary queue.
private final class OctoDevStreamBuffer {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    var standardOutput: String {
        lock.lock(); defer { lock.unlock() }
        return out
    }

    var standardError: String {
        lock.lock(); defer { lock.unlock() }
        return err
    }

    func appendStandardOutput(_ text: String) {
        lock.lock(); out += text; lock.unlock()
    }

    func appendStandardError(_ text: String) {
        lock.lock(); err += text; lock.unlock()
    }
}
