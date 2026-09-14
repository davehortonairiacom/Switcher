import Foundation

public enum ProcessProbe {
    /// True when a Claude Code CLI session is running.
    ///
    /// Claude Code's process is exactly `claude`; the desktop app is `Claude`
    /// (capitalised) and its helpers are `Claude Helper`, so an exact,
    /// case-sensitive match picks out only the CLI.
    public static func isClaudeCodeRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "claude"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
