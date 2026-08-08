import Foundation

/// Detects a repository's stack and produces a starting `auto-task.conf`.
///
/// Values come from the octo-dev templates verbatim. They are not cmux's
/// opinion: `/auto-task` reads this file, and a `FORBIDDEN_PATHS` that diverges
/// from what the toolkit expects leaves real files unprotected.
enum AutoTaskConfigTemplate {
    enum Stack: String, CaseIterable, Equatable {
        case androidNative = "android-native"
        case iosNative = "ios-native"
        case flutter
        case nodeJS = "node-js"
        case swiftPackage = "swift-package"
        case rust
        case go
        case python
        case unknown

        var displayName: String {
            switch self {
            case .androidNative: return "Android"
            case .iosNative: return "iOS"
            case .flutter: return "Flutter"
            case .nodeJS: return "Node.js"
            case .swiftPackage: return "Swift package"
            case .rust: return "Rust"
            case .go: return "Go"
            case .python: return "Python"
            case .unknown: return String(
                localized: "autoTask.stack.unknown",
                defaultValue: "Unrecognized"
            )
            }
        }

        /// Whether a bare test command is not enough — a mobile project can pass
        /// its unit tests and still fail to assemble a binary.
        var isMobile: Bool {
            switch self {
            case .androidNative, .iosNative, .flutter: return true
            default: return false
            }
        }
    }

    /// Common base every template includes.
    static let baseForbiddenPaths = ".gitlab-ci.yml,.github/,.octo-dev/"

    static func detectStack(inRepository path: String, fileManager: FileManager = .default) -> Stack {
        func has(_ relative: String) -> Bool {
            fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(relative))
        }
        func hasSuffix(_ suffix: String) -> Bool {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return false }
            return entries.contains { $0.hasSuffix(suffix) }
        }

        // Flutter before Android/iOS: a Flutter repo contains both.
        if has("pubspec.yaml") { return .flutter }
        if has("gradlew") || has("settings.gradle") || has("settings.gradle.kts") { return .androidNative }
        if hasSuffix(".xcodeproj") || hasSuffix(".xcworkspace") {
            // A Swift package with an Xcode project is still package-shaped if
            // it has no app target; Package.swift is the stronger signal.
            return has("Package.swift") ? .swiftPackage : .iosNative
        }
        if has("Package.swift") { return .swiftPackage }
        if has("Cargo.toml") { return .rust }
        if has("go.mod") { return .go }
        if has("package.json") { return .nodeJS }
        if has("pyproject.toml") || has("Pipfile") || has("setup.py") { return .python }
        return .unknown
    }

    static func forbiddenPaths(for stack: Stack) -> String {
        let extra: String
        switch stack {
        case .androidNative:
            extra = "*/build.gradle,*/build.gradle.kts,build.gradle,build.gradle.kts,"
                + "settings.gradle,settings.gradle.kts,gradle.properties,gradle/,fastlane/,"
                + "*.keystore,*.jks,*/google-services.json"
        case .iosNative:
            extra = "*.xcodeproj/project.pbxproj,*.xcworkspace/,fastlane/,*.entitlements,"
                + "*/GoogleService-Info.plist,Podfile.lock"
        case .flutter:
            extra = "pubspec.lock,*/build.gradle,*/build.gradle.kts,"
                + "*.xcodeproj/project.pbxproj,fastlane/,*/google-services.json,"
                + "*/GoogleService-Info.plist"
        case .nodeJS:
            extra = "package-lock.json,yarn.lock,pnpm-lock.yaml"
        case .swiftPackage:
            extra = "Package.resolved"
        case .rust:
            extra = "Cargo.lock"
        case .go:
            extra = "go.sum"
        case .python:
            extra = "poetry.lock,Pipfile.lock"
        case .unknown:
            extra = ""
        }
        return extra.isEmpty ? baseForbiddenPaths : baseForbiddenPaths + "," + extra
    }

    /// Suggested `VERIFY_CMD`. Mobile stacks include assembling a binary, not
    /// only unit tests.
    static func verifyCommand(for stack: Stack) -> String {
        switch stack {
        case .androidNative: return "./gradlew test"
        case .iosNative:
            return "xcodebuild test -scheme '<SCHEME>' -destination 'platform=iOS Simulator,name=iPhone 16'"
        case .flutter: return "flutter analyze && flutter test"
        case .nodeJS: return "npm run lint && npm run build && npm test"
        case .swiftPackage: return "swift build && swift test"
        case .rust: return "cargo test"
        case .go: return "go build ./... && go test ./..."
        case .python: return "pytest"
        case .unknown: return ""
        }
    }

    /// A complete starter file, header comments included — they are the only
    /// documentation anyone reading the repo will see.
    static func starterFile(for stack: Stack) -> String {
        """
        # Config for /auto-task (octo-dev). KEY=VALUE, same format as release.conf.
        # VERIFY_CMD runs from the repo root; a non-zero exit blocks the MR.
        VERIFY_CMD="\(verifyCommand(for: stack))"
        # Paths the autonomous run must never modify (comma-separated globs).
        FORBIDDEN_PATHS="\(forbiddenPaths(for: stack))"
        # Abort if the run touches more files than this.
        MAX_FILES=25
        # Seconds before VERIFY_CMD is considered hung.
        VERIFY_TIMEOUT=1800

        """
    }
}
