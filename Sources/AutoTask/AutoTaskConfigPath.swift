import Foundation

/// Where `/auto-task`'s configuration lives inside a repository.
///
/// The file is committed and therefore **shared by the whole team**: a change
/// affects every autonomous run by every member. It is also read by a bash
/// script, not by cmux alone, so its format is not ours to reinterpret.
enum AutoTaskConfigPath {
    static let directoryName = ".octo-dev"
    static let fileName = "auto-task.conf"

    /// Sibling files `/auto-task` depends on. `mr-create.yaml` is required —
    /// without it a run aborts in its first second.
    static let mrCreateFileName = "mr-create.yaml"
    static let criteriaFileName = "mr-criteria.md"

    static func directory(inRepository repositoryPath: String) -> String {
        (repositoryPath as NSString).appendingPathComponent(directoryName)
    }

    static func path(inRepository repositoryPath: String) -> String {
        (directory(inRepository: repositoryPath) as NSString).appendingPathComponent(fileName)
    }

    static func exists(inRepository repositoryPath: String, fileManager: FileManager = .default) -> Bool {
        guard !repositoryPath.isEmpty else { return false }
        return fileManager.fileExists(atPath: path(inRepository: repositoryPath))
    }
}
