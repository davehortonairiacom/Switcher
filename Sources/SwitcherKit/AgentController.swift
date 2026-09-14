import Foundation

public enum AgentStatus: Equatable, Sendable {
    case notInstalled
    case running
    case stopped

    public var label: String {
        switch self {
        case .notInstalled: return "not installed"
        case .running:      return "running"
        case .stopped:      return "stopped"
        }
    }
}

/// Thin wrapper over `launchctl` for the Airia discovery agent.
///
/// The agent lives in the user's GUI domain, so `bootout` / `bootstrap` work
/// without sudo. Pausing it matters because an active enforce policy will
/// otherwise re-apply the gateway on the agent's next check-in.
///
/// Note `bootout` does **not** survive a reboot — the agent returns at login.
/// That is the drift the Enforcer exists to catch.
public struct AgentController: Sendable {
    /// Runs launchctl with the given arguments, returning its exit status.
    /// Injectable so the enforcement logic can be tested without touching launchd.
    public typealias Runner = @Sendable (_ arguments: [String]) -> Int32

    public static let defaultLabel = "com.airia.airiad"
    public static let defaultPlistPath = "/Library/LaunchAgents/com.airia.airiad.plist"

    public let label: String
    public let plistPath: String
    private let runner: Runner

    public init(label: String = AgentController.defaultLabel,
                plistPath: String = AgentController.defaultPlistPath,
                runner: @escaping Runner = AgentController.launchctl) {
        self.label = label
        self.plistPath = plistPath
        self.runner = runner
    }

    private var guiDomain: String { "gui/\(getuid())" }
    private var serviceTarget: String { "\(guiDomain)/\(label)" }

    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    public func isRunning() -> Bool {
        runner(["print", serviceTarget]) == 0
    }

    public func status() -> AgentStatus {
        guard isInstalled() else { return .notInstalled }
        return isRunning() ? .running : .stopped
    }

    /// Stops the agent so an enforce policy can't immediately undo a switch.
    @discardableResult
    public func pause() -> Bool {
        runner(["bootout", serviceTarget]) == 0
    }

    @discardableResult
    public func resume() -> Bool {
        guard isInstalled() else { return false }
        return runner(["bootstrap", guiDomain, plistPath]) == 0
    }

    /// Forces a check-in, so an enforce policy writes the gateway config.
    @discardableResult
    public func kickstart() -> Bool {
        runner(["kickstart", "-k", serviceTarget]) == 0
    }

    /// Real launchctl. Output is discarded — only the exit status is meaningful,
    /// and `launchctl print` is extremely verbose.
    public static let launchctl: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
