import Foundation

/// Reads and writes `~/.claude/settings.json`.
///
/// This is a direct port of the `python3` heredocs in `gateway-on.command` /
/// `gateway-off.command`, preserving their careful edge cases:
///
///   * only the `x-airia-key:` line is stripped — other custom headers survive
///   * `ANTHROPIC_CUSTOM_HEADERS` is removed entirely once it would be empty
///   * `env` is removed entirely once it would be empty
///   * every unrelated top-level key is preserved untouched
///
/// It improves on them in two ways: writes are atomic (temp file + `rename(2)`,
/// so a crash can't truncate the file), and each write leaves a timestamped
/// backup rather than clobbering a single `settings.before-off.json`.
public struct SettingsStore: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    private static let baseURLKey = "ANTHROPIC_BASE_URL"
    private static let headersKey = "ANTHROPIC_CUSTOM_HEADERS"
    private static let airiaPrefix = "x-airia-key:"

    // MARK: - Reading

    /// The whole settings document. Missing or empty file reads as `[:]`.
    public func loadRaw() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: paths.settings.path) else { return [:] }
        let data = try Data(contentsOf: paths.settings)
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw SwitcherError.unparseableSettings(
                    path: paths.settings.path, underlying: "top level is not a JSON object")
            }
            return obj
        } catch let error as SwitcherError {
            throw error
        } catch {
            throw SwitcherError.unparseableSettings(
                path: paths.settings.path, underlying: error.localizedDescription)
        }
    }

    /// Current routing, derived from the file itself — never from a marker.
    public func currentMode() -> Mode {
        do {
            let env = try loadRaw()["env"] as? [String: Any] ?? [:]
            if let url = env[Self.baseURLKey] as? String, !url.isEmpty {
                return .gateway(url: url)
            }
            return .direct
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
    }

    /// Gateway values presently in `settings.json`, if the gateway is on.
    public func currentGatewayConfig() throws -> GatewayConfig? {
        let env = try loadRaw()["env"] as? [String: Any] ?? [:]
        guard let url = env[Self.baseURLKey] as? String, !url.isEmpty else { return nil }
        let airia = Self.airiaLines(in: env[Self.headersKey] as? String)
        return GatewayConfig(baseURL: url,
                             airiaHeader: airia.isEmpty ? nil : airia.joined(separator: "\n"))
    }

    // MARK: - Mutating

    /// Removes the gateway, returning what was removed so it can be stashed.
    /// Returns nil when there was nothing to remove (already direct).
    ///
    /// A returned config with an empty `baseURL` means only a stray header line
    /// was found — matching the scripts' "(custom header only)" case.
    @discardableResult
    public func stripGateway() throws -> GatewayConfig? {
        var settings = try loadRaw()
        var env = settings["env"] as? [String: Any] ?? [:]

        var removedURL: String?
        var removedHeader: String?

        if let url = env[Self.baseURLKey] as? String {
            removedURL = url
            env.removeValue(forKey: Self.baseURLKey)
        }

        if let headers = env[Self.headersKey] as? String {
            let lines = Self.nonEmptyLines(headers)
            let airia = lines.filter(Self.isAiriaKeyLine)
            // `l not in airia` in the Python — identical duplicate lines all go.
            let keep = lines.filter { !airia.contains($0) }
            if !airia.isEmpty {
                removedHeader = airia.joined(separator: "\n")
                if keep.isEmpty {
                    env.removeValue(forKey: Self.headersKey)
                } else {
                    env[Self.headersKey] = keep.joined(separator: "\n")
                }
            }
        }

        guard removedURL != nil || removedHeader != nil else { return nil }

        if env.isEmpty {
            settings.removeValue(forKey: "env")
        } else {
            settings["env"] = env
        }
        try write(settings)

        return GatewayConfig(baseURL: removedURL ?? "", airiaHeader: removedHeader)
    }

    /// Routes Claude Code through the gateway, merging into whatever else is set.
    public func applyGateway(_ config: GatewayConfig) throws {
        guard !config.baseURL.isEmpty else { throw SwitcherError.noGatewayConfigAvailable }

        var settings = try loadRaw()
        var env = settings["env"] as? [String: Any] ?? [:]
        env[Self.baseURLKey] = config.baseURL

        // Keep the user's other custom headers, drop any stale airia key, then
        // append the one being applied.
        var lines = Self.nonEmptyLines(env[Self.headersKey] as? String ?? "")
            .filter { !Self.isAiriaKeyLine($0) }
        if let header = config.airiaHeader {
            lines.append(contentsOf: Self.nonEmptyLines(header))
        }
        if lines.isEmpty {
            env.removeValue(forKey: Self.headersKey)
        } else {
            env[Self.headersKey] = lines.joined(separator: "\n")
        }

        settings["env"] = env
        try write(settings)
    }

    // MARK: - Line helpers (exposed for tests)

    static func nonEmptyLines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func isAiriaKeyLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(airiaPrefix)
    }

    static func airiaLines(in headers: String?) -> [String] {
        guard let headers else { return [] }
        return nonEmptyLines(headers).filter(isAiriaKeyLine)
    }

    // MARK: - Atomic write

    private func write(_ settings: [String: Any]) throws {
        let dir = paths.settings.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backupCurrent()

        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw SwitcherError.writeFailed(path: paths.settings.path,
                                            underlying: error.localizedDescription)
        }
        data.append(0x0A)  // trailing newline, as the shell scripts wrote

        let tmp = dir.appendingPathComponent(".switcher-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: tmp.path)
            // rename(2) is atomic and replaces the destination, so an interrupted
            // write can never leave a truncated settings.json behind.
            guard rename(tmp.path, paths.settings.path) == 0 else {
                throw SwitcherError.writeFailed(path: paths.settings.path,
                                                underlying: String(cString: strerror(errno)))
            }
        } catch let error as SwitcherError {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw SwitcherError.writeFailed(path: paths.settings.path,
                                            underlying: error.localizedDescription)
        }
    }

    /// Snapshot before each write. Best-effort: never block a switch on it.
    private func backupCurrent(keeping limit: Int = 10) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.settings.path) else { return }
        try? fm.createDirectory(at: paths.backups, withIntermediateDirectories: true)

        let stamp = Self.backupFormatter.string(from: Date())
        try? fm.copyItem(at: paths.settings,
                         to: paths.backups.appendingPathComponent("settings.\(stamp).json"))

        let existing = ((try? fm.contentsOfDirectory(at: paths.backups,
                                                     includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("settings.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if existing.count > limit {
            for url in existing.prefix(existing.count - limit) { try? fm.removeItem(at: url) }
        }
    }

    private static let backupFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
