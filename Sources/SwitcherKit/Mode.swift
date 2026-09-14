import Foundation

/// How Claude Code is currently routing inference.
///
/// This is always *derived* by reading `settings.json` — never remembered in a
/// marker file. Marker-based state is precisely what drifted in the shell scripts.
public enum Mode: Equatable, Sendable {
    case gateway(url: String)
    case direct
    /// `settings.json` exists but could not be parsed. Surfaced rather than
    /// guessed, so a corrupt file can never be silently overwritten.
    case unreadable(reason: String)

    public var isGateway: Bool { if case .gateway = self { return true }; return false }
    public var isDirect: Bool { self == .direct }

    public var gatewayURL: String? {
        if case let .gateway(url) = self { return url }
        return nil
    }

    public var shortLabel: String {
        switch self {
        case .gateway:      return "Gateway"
        case .direct:       return "Direct"
        case .unreadable:   return "Unknown"
        }
    }
}

/// The two values that together route Claude Code through the gateway.
public struct GatewayConfig: Equatable, Sendable {
    /// Becomes `env.ANTHROPIC_BASE_URL`.
    public var baseURL: String
    /// Full header line(s), e.g. `x-airia-key: agk-…`. Nil when the gateway is
    /// reachable without a key.
    public var airiaHeader: String?

    public init(baseURL: String, airiaHeader: String? = nil) {
        self.baseURL = baseURL
        self.airiaHeader = airiaHeader
    }
}

public enum SwitcherError: LocalizedError {
    case unparseableSettings(path: String, underlying: String)
    case writeFailed(path: String, underlying: String)
    case noGatewayConfigAvailable
    case agentDidNotApplyPolicy(seconds: Int)
    case invalidProfile

    public var errorDescription: String? {
        switch self {
        case let .unparseableSettings(path, underlying):
            return "Could not parse \(path) as JSON — left untouched. (\(underlying))"
        case let .writeFailed(path, underlying):
            return "Could not write \(path): \(underlying)"
        case .noGatewayConfigAvailable:
            return """
            No gateway configuration available. Either no stash has been captured yet \
            (switch to Direct once while the gateway is active), or the airiad agent \
            needs to apply the tenant policy.
            """
        case .invalidProfile:
            return "A gateway needs a name and a valid URL (including https://)."
        case let .agentDidNotApplyPolicy(seconds):
            return """
            The airiad agent did not write a gateway config within \(seconds)s.             Likely the tenant policy is 'observe' rather than 'enforce', or this             device is not enrolled (check ~/.airiad/enrollment.json).
            """
        }
    }
}
