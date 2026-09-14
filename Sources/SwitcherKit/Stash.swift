import Foundation

/// Persists the gateway values that were removed, so the gateway can be turned
/// back on without the agent.
///
/// Deliberately keeps the same file and JSON shape as the shell scripts
/// (`~/.claude/gateway-toggle/stash.json`, keys `ANTHROPIC_BASE_URL` and
/// `ANTHROPIC_CUSTOM_HEADERS`) so the `.command` scripts remain a working
/// fallback alongside the app. Mode 0600 — it holds the gateway key.
public struct Stash: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    private static let baseURLKey = "ANTHROPIC_BASE_URL"
    private static let headersKey = "ANTHROPIC_CUSTOM_HEADERS"

    public func read() -> GatewayConfig? {
        guard let data = try? Data(contentsOf: paths.stash),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj[Self.baseURLKey] as? String, !url.isEmpty
        else { return nil }
        let header = obj[Self.headersKey] as? String
        return GatewayConfig(baseURL: url,
                             airiaHeader: (header?.isEmpty ?? true) ? nil : header)
    }

    /// Writes only the values present, mirroring the scripts.
    public func write(_ config: GatewayConfig) throws {
        var obj: [String: Any] = [:]
        if !config.baseURL.isEmpty { obj[Self.baseURLKey] = config.baseURL }
        if let header = config.airiaHeader, !header.isEmpty { obj[Self.headersKey] = header }
        guard !obj.isEmpty else { return }

        let fm = FileManager.default
        try fm.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.stateDir.path)

        var data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try data.write(to: paths.stash)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stash.path)
    }
}
