import Foundation

/// The route the user asked for, which may differ from what's on disk.
public enum DesiredMode: Equatable, Sendable {
    /// Route through a specific saved gateway.
    case gateway(profileID: UUID)
    case direct
    /// Switcher observes but never corrects — the deliberate off-switch for
    /// enforcement, for when you want the tenant policy to win.
    case unmanaged

    /// Flattened for UserDefaults.
    public var storageValue: String {
        switch self {
        case .direct:               return "direct"
        case .unmanaged:            return "unmanaged"
        case let .gateway(id):      return "gateway:\(id.uuidString)"
        }
    }

    public init?(storageValue: String) {
        switch storageValue {
        case "direct":    self = .direct
        case "unmanaged": self = .unmanaged
        default:
            guard storageValue.hasPrefix("gateway:"),
                  let id = UUID(uuidString: String(storageValue.dropFirst("gateway:".count)))
            else { return nil }
            self = .gateway(profileID: id)
        }
    }

    public var isGateway: Bool { if case .gateway = self { return true }; return false }
}

public enum EnforcementResult: Equatable, Sendable {
    case unmanaged
    case inSync
    case corrected(to: DesiredMode)
    case rateLimited(String)
    case failed(String)
}

/// Holds the chosen mode against anything that changes it behind your back.
///
/// The airiad agent re-applies the tenant enforce policy at login and on each
/// check-in, which is how `gateway-off` silently stopped holding: `launchctl
/// bootout` doesn't survive a reboot.
///
/// **Why this can't loop:** enforcement only acts when actual ≠ desired. After
/// correcting, actual == desired, so the write our own watcher observes produces
/// no further action. The rate limiter below is a backstop for the genuinely
/// adversarial case — an agent actively rewriting the file — not the primary
/// defence against self-triggering.
public final class Enforcer: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var desired: DesiredMode
        public var actual: Mode
        public var agent: AgentStatus
        /// Non-nil once the breaker has tripped: enforcement has given up.
        public var trippedReason: String?
        public var lastResult: EnforcementResult
    }

    public static let defaultsKey = "ai.airia.switcher.desiredMode"

    private let controller: GatewayController
    public let profiles: ProfileStore
    private let defaults: UserDefaults
    private let lock = NSLock()

    private var recentCorrections: [Date] = []
    private var trippedReason: String?
    private var lastResult: EnforcementResult = .inSync

    /// Corrections allowed inside `window` before giving up.
    public let maxCorrections: Int
    public let window: TimeInterval

    /// Called after every evaluation so the UI can follow along.
    public var onChange: (@Sendable (Snapshot) -> Void)?

    public init(controller: GatewayController,
                profiles: ProfileStore,
                defaults: UserDefaults = .standard,
                maxCorrections: Int = 5,
                window: TimeInterval = 60) {
        self.controller = controller
        self.profiles = profiles
        self.defaults = defaults
        self.maxCorrections = maxCorrections
        self.window = window
    }

    // MARK: - Desired mode

    public var desired: DesiredMode {
        get {
            guard let raw = defaults.string(forKey: Self.defaultsKey),
                  let mode = DesiredMode(storageValue: raw) else { return .unmanaged }
            return mode
        }
        set {
            defaults.set(newValue.storageValue, forKey: Self.defaultsKey)
            resetBreaker()
        }
    }

    /// Switches now and remembers the choice so it survives reboots.
    @discardableResult
    public func select(_ mode: DesiredMode) -> EnforcementResult {
        desired = mode
        return evaluate(force: true)
    }

    public func resetBreaker() {
        lock.lock(); defer { lock.unlock() }
        recentCorrections.removeAll()
        trippedReason = nil
    }

    // MARK: - Evaluation

    public func snapshot() -> Snapshot {
        lock.lock()
        let tripped = trippedReason
        let last = lastResult
        lock.unlock()
        return Snapshot(desired: desired,
                        actual: controller.currentMode(),
                        agent: controller.agentStatus(),
                        trippedReason: tripped,
                        lastResult: last)
    }

    /// Compares reality against the chosen mode and corrects if they differ.
    /// Safe to call as often as you like — it is a no-op when already in sync.
    @discardableResult
    public func evaluate(force: Bool = false) -> EnforcementResult {
        let target = desired
        let actual = controller.currentMode()

        let result: EnforcementResult
        switch target {
        case .unmanaged:
            result = .unmanaged

        case .direct:
            if actual.isDirect && !force {
                result = .inSync
            } else {
                result = correct(to: target) { try self.controller.switchToDirect() }
            }

        case let .gateway(profileID):
            guard let profile = profiles.profile(id: profileID) else {
                // The profile was deleted out from under the selection.
                result = .failed("That gateway no longer exists — pick another.")
                break
            }
            if actual.gatewayURL == profile.baseURL && !force {
                result = .inSync
            } else {
                let config = profiles.config(for: profile)
                // If our choice has already been overwritten once, something is
                // enforcing a different URL. Writing again would just lose the
                // same race, so pause the agent doing the overwriting instead.
                let contested = isContested()
                result = correct(to: target) {
                    try self.controller.switchToGateway(using: config,
                                                        keepAgentPaused: contested)
                }
            }
        }

        lock.lock(); lastResult = result; lock.unlock()
        onChange?(snapshot())
        return result
    }

    private func correct(to target: DesiredMode,
                         _ action: () throws -> Void) -> EnforcementResult {
        if let reason = breakerReason() { return .rateLimited(reason) }
        noteCorrection()
        do {
            try action()
            return .corrected(to: target)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// True once we've had to correct more than once inside the window, which
    /// means something is actively rewriting settings.json underneath us.
    private func isContested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-window)
        recentCorrections.removeAll { $0 < cutoff }
        return !recentCorrections.isEmpty
    }

    // MARK: - Circuit breaker

    private func breakerReason() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let trippedReason { return trippedReason }

        let cutoff = Date().addingTimeInterval(-window)
        recentCorrections.removeAll { $0 < cutoff }
        if recentCorrections.count >= maxCorrections {
            trippedReason = """
            Stopped enforcing after \(maxCorrections) corrections in \(Int(window))s — \
            something keeps rewriting settings.json. Check the airiad agent.
            """
            return trippedReason
        }
        return nil
    }

    private func noteCorrection() {
        lock.lock(); defer { lock.unlock() }
        recentCorrections.append(Date())
    }
}
