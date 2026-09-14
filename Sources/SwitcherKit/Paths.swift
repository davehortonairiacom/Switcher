import Foundation

/// Locations Switcher reads and writes.
///
/// Always construct via `Paths.live` in shipping code. `live` honours the
/// `SWITCHER_CLAUDE_DIR` environment variable, which is how tests and dry runs
/// operate on a throwaway directory instead of the real `~/.claude`.
public struct Paths: Sendable, Equatable {
    public let claudeDir: URL

    public init(claudeDir: URL) { self.claudeDir = claudeDir }

    public var settings: URL { claudeDir.appendingPathComponent("settings.json") }
    public var stateDir: URL { claudeDir.appendingPathComponent("gateway-toggle") }
    public var stash: URL    { stateDir.appendingPathComponent("stash.json") }
    public var backups: URL  { stateDir.appendingPathComponent("backups") }

    public static var live: Paths {
        let env = ProcessInfo.processInfo.environment["SWITCHER_CLAUDE_DIR"]
        if let env, !env.isEmpty {
            return Paths(claudeDir: URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        return Paths(claudeDir: FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude"))
    }

    /// True when pointed somewhere other than the user's real `~/.claude`.
    public var isRedirected: Bool {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").standardizedFileURL
        return claudeDir.standardizedFileURL != real
    }
}
