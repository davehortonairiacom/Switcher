import Foundation

public struct SwitchOutcome: Sendable {
    public var mode: Mode
    public var agent: AgentStatus
    public var notes: [String]
}

/// Orchestrates a mode switch: settings.json, the stash, and the agent.
///
/// Mirrors `gateway-on.command` / `gateway-off.command`, with one deliberate
/// departure: **there is no `agent-was-running` marker.** The scripts used one
/// to decide whether to resume the agent, and it drifted — a marker from 26 Aug
/// was still on disk weeks later while the agent ran and the gateway was on.
/// Instead, the agent is resumed whenever gateway mode is selected (wanting the
/// gateway and wanting its enforcing agent are the same intent) and paused
/// whenever direct mode is selected. State is always read back from the world.
public struct GatewayController: Sendable {
    public let settings: SettingsStore
    public let stash: Stash
    public let agent: AgentController
    /// Mirrors `MANAGE_AGENT=1` at the top of the scripts.
    public let manageAgent: Bool

    public init(paths: Paths = .live,
                agent: AgentController = AgentController(),
                manageAgent: Bool = true) {
        self.settings = SettingsStore(paths: paths)
        self.stash = Stash(paths: paths)
        self.agent = agent
        self.manageAgent = manageAgent
    }

    public func currentMode() -> Mode { settings.currentMode() }
    public func agentStatus() -> AgentStatus { agent.status() }

    // MARK: - Direct

    @discardableResult
    public func switchToDirect() throws -> SwitchOutcome {
        var notes: [String] = []

        // Pause first: an enforce policy would otherwise re-apply the gateway on
        // the agent's next check-in, undoing the strip moments later.
        if manageAgent, agent.status() == .running {
            if agent.pause() {
                notes.append("Paused the airiad agent.")
            } else {
                notes.append("Could not stop the airiad agent — it may re-apply the gateway shortly.")
            }
        }

        if let removed = try settings.stripGateway() {
            do {
                try stash.write(removed)
            } catch {
                notes.append("Warning: could not write the stash — turning the gateway back on may need the agent.")
            }
            notes.append(removed.baseURL.isEmpty
                ? "Removed a stray x-airia-key header."
                : "Removed the gateway from settings.json (was: \(removed.baseURL)).")
        } else {
            notes.append("No gateway config in settings.json — nothing to remove.")
        }

        notes.append(contentsOf: Self.shellProfileWarnings())
        return SwitchOutcome(mode: settings.currentMode(), agent: agent.status(), notes: notes)
    }

    // MARK: - Gateway

    /// Resolves gateway values from, in order: an explicit override, the stash,
    /// then the agent itself (kickstart and wait for the enforce policy to write).
    @discardableResult
    public func switchToGateway(using override: GatewayConfig? = nil,
                                waitingForAgent timeout: TimeInterval = 25) throws -> SwitchOutcome {
        var notes: [String] = []

        // An explicit target always wins, and must be checked before the
        // "already on a gateway" short-circuit below — otherwise switching from
        // one gateway to another would silently do nothing.
        if let override {
            try settings.applyGateway(override)
            try? stash.write(override)
            notes.append("Applied \(override.baseURL).")
            resumeAgent(&notes)
            return SwitchOutcome(mode: settings.currentMode(), agent: agent.status(), notes: notes)
        }

        // No explicit target: if we're already routed somewhere, stay there and
        // refresh the stash so a later switch works without the agent.
        if case let .gateway(url) = settings.currentMode() {
            notes.append("settings.json already routes through: \(url)")
            if let current = try? settings.currentGatewayConfig() {
                try? stash.write(current)
            }
            resumeAgent(&notes)
            return SwitchOutcome(mode: settings.currentMode(), agent: agent.status(), notes: notes)
        }

        if let stashed = stash.read() {
            try settings.applyGateway(stashed)
            notes.append("Restored the gateway config from the stash.")
            resumeAgent(&notes)
            return SwitchOutcome(mode: settings.currentMode(), agent: agent.status(), notes: notes)
        }

        // No stash: let the agent apply the tenant's enforce policy.
        guard agent.isInstalled() else { throw SwitcherError.noGatewayConfigAvailable }

        if !agent.isRunning() { _ = agent.resume() }
        _ = agent.kickstart()
        notes.append("Kicked the airiad agent and waited for it to write the gateway config.")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            if case .gateway = settings.currentMode() {
                if let current = try? settings.currentGatewayConfig() {
                    try? stash.write(current)
                }
                notes.append("The agent applied the tenant's enforce policy.")
                return SwitchOutcome(mode: settings.currentMode(), agent: agent.status(), notes: notes)
            }
        }
        throw SwitcherError.agentDidNotApplyPolicy(seconds: Int(timeout))
    }

    private func resumeAgent(_ notes: inout [String]) {
        guard manageAgent, agent.isInstalled(), !agent.isRunning() else { return }
        notes.append(agent.resume() ? "Resumed the airiad agent."
                                    : "Could not resume the airiad agent.")
    }

    // MARK: - Shell profile check

    /// A profile that exports ANTHROPIC_BASE_URL overrides settings.json for
    /// shells started from it, so switching would appear to do nothing.
    static func shellProfileWarnings() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".zprofile", ".bashrc", ".bash_profile"].compactMap { name in
            let url = home.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let sets = text.components(separatedBy: .newlines).contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("#") && trimmed.contains("ANTHROPIC_BASE_URL")
            }
            return sets ? "Note: ~/\(name) also sets ANTHROPIC_BASE_URL — remove or comment it there too." : nil
        }
    }
}
