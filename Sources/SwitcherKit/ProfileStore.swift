import Foundation

/// The set of gateways you can switch between.
///
/// Metadata lives in `~/.claude/gateway-toggle/profiles.json` (0600); keys live
/// in the Keychain. On first run the stash written by the shell scripts is
/// imported, so an existing setup appears as a ready-made profile rather than an
/// empty list.
public final class ProfileStore: @unchecked Sendable {
    public let paths: Paths
    private let keyStore: KeyStoring
    private let lock = NSLock()

    public init(paths: Paths, keyStore: KeyStoring = KeychainStore.shared) {
        self.paths = paths
        self.keyStore = keyStore
    }

    private var file: URL { paths.stateDir.appendingPathComponent("profiles.json") }

    // MARK: - Reading

    public func all() -> [GatewayProfile] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    public func profile(id: UUID) -> GatewayProfile? {
        all().first { $0.id == id }
    }

    /// Profile whose base URL matches what's currently in settings.json.
    public func profile(matchingURL url: String) -> GatewayProfile? {
        all().first { $0.baseURL == url }
    }

    public func key(for profile: GatewayProfile) -> String? {
        keyStore.key(for: profile.id)
    }

    /// Everything needed to apply this gateway to settings.json.
    public func config(for profile: GatewayProfile) -> GatewayConfig {
        GatewayConfig(baseURL: profile.baseURL,
                      airiaHeader: profile.headerLine(key: key(for: profile) ?? ""))
    }

    // MARK: - Writing

    public func save(_ profile: GatewayProfile, key: String?) throws {
        guard let valid = profile.validated() else {
            throw SwitcherError.invalidProfile
        }
        lock.lock()
        var profiles = loadLocked()
        if let index = profiles.firstIndex(where: { $0.id == valid.id }) {
            profiles[index] = valid
        } else {
            profiles.append(valid)
        }
        try writeLocked(profiles)
        lock.unlock()

        if let key { try keyStore.setKey(key, for: valid.id) }
    }

    public func delete(id: UUID) throws {
        lock.lock()
        var profiles = loadLocked()
        profiles.removeAll { $0.id == id }
        try writeLocked(profiles)
        lock.unlock()

        keyStore.deleteKey(for: id)
    }

    // MARK: - Migration

    /// Imports the shell scripts' stash the first time Switcher runs, so an
    /// existing setup isn't lost.
    @discardableResult
    public func migrateFromStashIfNeeded() -> GatewayProfile? {
        guard all().isEmpty else { return nil }

        // Prefer whatever is live in settings.json; fall back to the stash.
        let settings = SettingsStore(paths: paths)
        let source = (try? settings.currentGatewayConfig()) ?? nil ?? Stash(paths: paths).read()
        guard let source, !source.baseURL.isEmpty else { return nil }

        let headerName = source.airiaHeader?
            .split(separator: ":", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? GatewayProfile.defaultHeaderName
        let keyValue = source.airiaHeader?
            .split(separator: ":", maxSplits: 1).dropFirst().first
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let profile = GatewayProfile(name: Self.suggestedName(for: source.baseURL),
                                     baseURL: source.baseURL,
                                     headerName: headerName)
        try? save(profile, key: keyValue)
        return profile
    }

    /// "https://acme.gateway.example/anthropic" -> "Acme"
    public static func suggestedName(for baseURL: String) -> String {
        guard let host = URL(string: baseURL)?.host else { return "Gateway" }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    // MARK: - Persistence

    private func loadLocked() -> [GatewayProfile] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([GatewayProfile].self, from: data)) ?? []
    }

    private func writeLocked(_ profiles: [GatewayProfile]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.stateDir.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
