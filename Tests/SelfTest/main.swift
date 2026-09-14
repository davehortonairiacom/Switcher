import Foundation
import SwitcherKit

// Mirrors the real settings.json on this machine: gateway env plus a spread of
// unrelated top-level keys that must survive every write.
let realShape = """
{
  "agentPushNotifEnabled": true,
  "effortLevel": "high",
  "env": {
    "ANTHROPIC_BASE_URL": "https://tenant.gateway.airia.ai/anthropic",
    "ANTHROPIC_CUSTOM_HEADERS": "x-airia-key: agk-TESTKEY"
  },
  "fastMode": true,
  "permissions": { "allow": ["Bash(ls:*)"] },
  "tui": { "theme": "dark" }
}
"""

/// Stands in for launchctl so agent handling can be tested without touching launchd.
final class FakeLaunchctl: @unchecked Sendable {
    var calls: [[String]] = []
    var running = true
    var verbs: [String] { calls.compactMap(\.first) }

    lazy var runner: AgentController.Runner = { [self] args in
        calls.append(args)
        switch args.first {
        case "print":     return running ? 0 : 1
        case "bootout":   running = false; return 0
        case "bootstrap": running = true;  return 0
        case "kickstart": return 0
        default:          return 1
        }
    }
}

/// AgentController checks the plist exists on disk, so give the fake a real file.
func fakeAgent(in paths: Paths, _ fake: FakeLaunchctl) throws -> AgentController {
    let plist = paths.claudeDir.appendingPathComponent("fake-airiad.plist")
    try Data().write(to: plist)
    return AgentController(label: "com.test.agent", plistPath: plist.path, runner: fake.runner)
}

func env(_ paths: Paths) throws -> [String: Any] {
    try SettingsStore(paths: paths).loadRaw()["env"] as? [String: Any] ?? [:]
}

print("switcher-selftest")
print(String(repeating: "─", count: 52))

// ─────────────────────────────────────────────── SettingsStore

T.suite("strip reports what it removed") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let store = SettingsStore(paths: paths)
        guard let removed = try store.stripGateway() else {
            return T.expect(false, "expected a removed config")
        }
        T.equal(removed.baseURL, "https://tenant.gateway.airia.ai/anthropic", "stripped URL")
        T.equal(removed.airiaHeader, "x-airia-key: agk-TESTKEY", "stripped header")
        T.equal(store.currentMode(), .direct, "mode after strip")
    }
}

T.suite("strip drops env once it empties") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        try SettingsStore(paths: paths).stripGateway()
        T.isNil(try SettingsStore(paths: paths).loadRaw()["env"], "env should be gone entirely")
    }
}

T.suite("strip preserves unrelated top-level keys") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        try SettingsStore(paths: paths).stripGateway()
        let after = try SettingsStore(paths: paths).loadRaw()
        T.equal(after["effortLevel"] as? String, "high", "effortLevel survives")
        T.equal(after["fastMode"] as? Bool, true, "fastMode survives")
        T.equal(after["agentPushNotifEnabled"] as? Bool, true, "agentPushNotifEnabled survives")
        T.notNil(after["permissions"], "permissions survives")
        T.notNil(after["tui"], "tui survives")
    }
}

T.suite("strip keeps non-airia header lines") {
    try withTempClaudeDir { paths in
        try paths.seed(#"""
        { "env": { "ANTHROPIC_BASE_URL": "https://gw.example/anthropic",
                   "ANTHROPIC_CUSTOM_HEADERS": "x-trace-id: abc\nx-airia-key: agk-K\nx-team: se" } }
        """#)
        try SettingsStore(paths: paths).stripGateway()
        let headers = try env(paths)["ANTHROPIC_CUSTOM_HEADERS"] as? String
        T.equal(headers, "x-trace-id: abc\nx-team: se", "only the airia line is removed")
    }
}

T.suite("strip removes every duplicate airia line") {
    try withTempClaudeDir { paths in
        try paths.seed(#"""
        { "env": { "ANTHROPIC_BASE_URL": "https://gw.example/anthropic",
                   "ANTHROPIC_CUSTOM_HEADERS": "x-airia-key: dup\nx-airia-key: dup" } }
        """#)
        try SettingsStore(paths: paths).stripGateway()
        T.isNil(try SettingsStore(paths: paths).loadRaw()["env"], "duplicates all removed")
    }
}

T.suite("strip is a no-op when already direct") {
    try withTempClaudeDir { paths in
        try paths.seed(#"{ "effortLevel": "high" }"#)
        T.isNil(try SettingsStore(paths: paths).stripGateway(), "nothing removed")
    }
}

T.suite("apply then strip round-trips exactly") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let store = SettingsStore(paths: paths)
        let original = try env(paths)
        let removed = try store.stripGateway()!
        try store.applyGateway(removed)
        let restored = try env(paths)
        T.equal(restored["ANTHROPIC_BASE_URL"] as? String,
                original["ANTHROPIC_BASE_URL"] as? String, "URL round-trips")
        T.equal(restored["ANTHROPIC_CUSTOM_HEADERS"] as? String,
                original["ANTHROPIC_CUSTOM_HEADERS"] as? String, "header round-trips")
    }
}

T.suite("apply replaces a stale key rather than appending") {
    try withTempClaudeDir { paths in
        try paths.seed(#"{ "env": { "ANTHROPIC_CUSTOM_HEADERS": "x-airia-key: OLD\nx-keep: yes" } }"#)
        try SettingsStore(paths: paths).applyGateway(
            GatewayConfig(baseURL: "https://gw.example/anthropic", airiaHeader: "x-airia-key: NEW"))
        let headers = try env(paths)["ANTHROPIC_CUSTOM_HEADERS"] as? String
        T.equal(headers, "x-keep: yes\nx-airia-key: NEW", "stale key replaced, others kept")
    }
}

T.suite("writes stay owner-only (0600)") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        try SettingsStore(paths: paths).stripGateway()
        let mode = try FileManager.default
            .attributesOfItem(atPath: paths.settings.path)[.posixPermissions] as? NSNumber
        T.equal(mode?.intValue, 0o600, "settings.json holds a key — must stay 0600")
    }
}

T.suite("each write leaves a backup, pruned to 10") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let store = SettingsStore(paths: paths)
        for _ in 0..<14 {
            try store.applyGateway(GatewayConfig(baseURL: "https://gw.example/anthropic",
                                                 airiaHeader: "x-airia-key: k"))
            try store.stripGateway()
        }
        let backups = (try FileManager.default.contentsOfDirectory(atPath: paths.backups.path))
            .filter { $0.hasPrefix("settings.") }
        T.expect(backups.count <= 10, "backups pruned to 10, found \(backups.count)")
        T.expect(backups.count > 0, "at least one backup kept")
    }
}

T.suite("missing and empty files read as direct") {
    withTempClaudeDir { paths in
        T.equal(SettingsStore(paths: paths).currentMode(), .direct, "missing file")
    }
    try withTempClaudeDir { paths in
        try paths.seed("")
        T.equal(SettingsStore(paths: paths).currentMode(), .direct, "empty file")
    }
}

T.suite("a corrupt file is surfaced and never overwritten") {
    try withTempClaudeDir { paths in
        let garbage = "{ this is not json"
        try paths.seed(garbage)
        let store = SettingsStore(paths: paths)
        if case .unreadable = store.currentMode() {} else {
            T.expect(false, "corrupt settings.json must report .unreadable")
        }
        T.throwsError("strip must refuse a corrupt file") { try store.stripGateway() }
        T.equal(paths.rawText(), garbage, "corrupt file left byte-identical")
    }
}

// ─────────────────────────────────────────────── Stash

T.suite("stash round-trips and stays 0600") {
    try withTempClaudeDir { paths in
        let stash = Stash(paths: paths)
        let config = GatewayConfig(baseURL: "https://gw.example/anthropic",
                                   airiaHeader: "x-airia-key: agk-SECRET")
        try stash.write(config)
        T.equal(stash.read(), config, "stash round-trips")
        let mode = try FileManager.default
            .attributesOfItem(atPath: paths.stash.path)[.posixPermissions] as? NSNumber
        T.equal(mode?.intValue, 0o600, "stash holds the key — must stay 0600")
    }
}

T.suite("stash with no URL reads back as nothing usable") {
    try withTempClaudeDir { paths in
        let stash = Stash(paths: paths)
        try stash.write(GatewayConfig(baseURL: "", airiaHeader: "x-airia-key: orphan"))
        T.isNil(stash.read(), "header without a URL can't turn the gateway on")
    }
}

// ─────────────────────────────────────────────── GatewayController

T.suite("switching to direct pauses the agent and strips the gateway") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))

        let outcome = try controller.switchToDirect()
        T.equal(outcome.mode, .direct, "ends up direct")
        T.expect(fake.verbs.contains("bootout"), "agent was paused; saw \(fake.verbs)")
        T.equal(fake.running, false, "agent left stopped")
        T.notNil(Stash(paths: paths).read(), "values stashed for the way back")
    }
}

T.suite("switching to gateway restores from stash and resumes the agent") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))

        try controller.switchToDirect()
        let outcome = try controller.switchToGateway()

        T.equal(outcome.mode, .gateway(url: "https://tenant.gateway.airia.ai/anthropic"),
                "gateway restored with the original URL")
        T.equal(try env(paths)["ANTHROPIC_CUSTOM_HEADERS"] as? String,
                "x-airia-key: agk-TESTKEY", "key restored byte-identical")
        T.expect(fake.verbs.contains("bootstrap"), "agent resumed; saw \(fake.verbs)")
        T.equal(fake.running, true, "agent left running")
    }
}

T.suite("--no-agent leaves launchctl completely alone") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths,
                                           agent: try fakeAgent(in: paths, fake),
                                           manageAgent: false)
        try controller.switchToDirect()
        T.expect(!fake.verbs.contains("bootout"), "no bootout; saw \(fake.verbs)")
        T.equal(SettingsStore(paths: paths).currentMode(), .direct, "still switched")
    }
}

T.suite("turning the gateway on with nothing to restore fails loudly") {
    try withTempClaudeDir { paths in
        try paths.seed(#"{ "effortLevel": "high" }"#)
        // No stash, and no agent plist on disk.
        let controller = GatewayController(
            paths: paths,
            agent: AgentController(label: "com.test.absent",
                                   plistPath: paths.claudeDir.appendingPathComponent("nope").path,
                                   runner: { _ in 1 }))
        T.throwsError("no stash and no agent must throw, not silently no-op") {
            try controller.switchToGateway()
        }
    }
}

// ─────────────────────────────────────────────── Enforcer

func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "switcher-selftest-\(UUID().uuidString)")!
}

T.suite("enforcement is idempotent — correcting once leaves it in sync") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))
        let profiles = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let enforcer = Enforcer(controller: controller, profiles: profiles, defaults: freshDefaults())

        T.equal(enforcer.select(.direct), .corrected(to: .direct), "first select corrects")
        // This is the anti-loop property: re-evaluating after our own write must
        // do nothing, or the watcher would drive an endless write cycle.
        T.equal(enforcer.evaluate(), .inSync, "re-evaluating after our own write is a no-op")
        T.equal(enforcer.evaluate(), .inSync, "and stays a no-op")
    }
}

T.suite("enforcement restores the chosen mode after external drift") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))
        let profiles = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let enforcer = Enforcer(controller: controller, profiles: profiles, defaults: freshDefaults())
        enforcer.select(.direct)

        // Simulate airiad re-applying the enforce policy at login.
        try paths.seed(realShape)
        T.expect(SettingsStore(paths: paths).currentMode().isGateway, "drift applied")

        T.equal(enforcer.evaluate(), .corrected(to: .direct), "drift is corrected")
        T.equal(SettingsStore(paths: paths).currentMode(), .direct, "back to the chosen mode")
    }
}

T.suite("unmanaged never corrects") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))
        let profiles = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let enforcer = Enforcer(controller: controller, profiles: profiles, defaults: freshDefaults())
        enforcer.desired = .unmanaged

        T.equal(enforcer.evaluate(), .unmanaged, "observes only")
        T.expect(SettingsStore(paths: paths).currentMode().isGateway, "file untouched")
    }
}

T.suite("the breaker trips when something keeps fighting back") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))
        let profiles = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let enforcer = Enforcer(controller: controller, profiles: profiles,
                                defaults: freshDefaults(), maxCorrections: 3, window: 60)
        enforcer.select(.direct)

        var sawRateLimit = false
        for _ in 0..<6 {
            try paths.seed(realShape)              // airiad rewrites it, every time
            if case .rateLimited = enforcer.evaluate() { sawRateLimit = true; break }
        }
        T.expect(sawRateLimit, "breaker must trip rather than fight forever")
        T.notNil(enforcer.snapshot().trippedReason, "and say why")
    }
}

// ──────────────────────────────── Integration: watcher drives the enforcer

T.suite("watcher + enforcer correct an external rewrite, then go quiet") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))
        let profiles = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let enforcer = Enforcer(controller: controller, profiles: profiles, defaults: freshDefaults())
        enforcer.select(.direct)

        let corrections = Counter()
        let firstCorrection = DispatchSemaphore(value: 0)
        let watcher = SettingsWatcher(url: paths.settings, debounce: 0.1) {
            if case .corrected = enforcer.evaluate() {
                corrections.increment()
                firstCorrection.signal()
            }
        }
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.4)   // let the watch arm

        // Simulate airiad re-applying the enforce policy. `seed` writes
        // atomically, so this also exercises re-arming onto a new inode.
        try paths.seed(realShape)

        T.equal(firstCorrection.wait(timeout: .now() + 5), .success,
                "the watcher should drive a correction within 5s")
        T.equal(SettingsStore(paths: paths).currentMode(), .direct, "chosen mode restored")

        // The anti-loop property, end to end: our own corrective write must not
        // trigger further corrections.
        Thread.sleep(forTimeInterval: 2.0)
        T.equal(corrections.value, 1, "exactly one correction — no write loop")
    }
}

// ─────────────────────────────────────────────── Profiles

T.suite("profiles round-trip, with the key kept out of the file") {
    try withTempClaudeDir { paths in
        let keys = InMemoryKeyStore()
        let store = ProfileStore(paths: paths, keyStore: keys)
        let profile = GatewayProfile(name: "Demo", baseURL: "https://demo.gateway.airia.ai/anthropic")
        try store.save(profile, key: "agk-SECRET")

        T.equal(store.all().count, 1, "one profile saved")
        T.equal(store.profile(id: profile.id)?.name, "Demo", "name round-trips")
        T.equal(store.key(for: profile), "agk-SECRET", "key retrievable")

        let onDisk = (try? String(contentsOf: paths.stateDir.appendingPathComponent("profiles.json"),
                                  encoding: .utf8)) ?? ""
        T.expect(!onDisk.contains("agk-SECRET"), "the key must never be written to profiles.json")

        let mode = try FileManager.default.attributesOfItem(
            atPath: paths.stateDir.appendingPathComponent("profiles.json").path)[.posixPermissions] as? NSNumber
        T.equal(mode?.intValue, 0o600, "profiles.json stays owner-only")
    }
}

T.suite("a profile needs a name and a real URL") {
    try withTempClaudeDir { paths in
        let store = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        T.throwsError("blank name rejected") {
            try store.save(GatewayProfile(name: "  ", baseURL: "https://x.example"), key: nil)
        }
        T.throwsError("bare word rejected as a URL") {
            try store.save(GatewayProfile(name: "X", baseURL: "not a url"), key: nil)
        }
        T.throwsError("scheme-less URL rejected") {
            try store.save(GatewayProfile(name: "X", baseURL: "gateway.airia.ai"), key: nil)
        }
        T.equal(store.all().count, 0, "nothing invalid was stored")
    }
}

T.suite("deleting a profile removes its key too") {
    try withTempClaudeDir { paths in
        let keys = InMemoryKeyStore()
        let store = ProfileStore(paths: paths, keyStore: keys)
        let profile = GatewayProfile(name: "Demo", baseURL: "https://demo.example/anthropic")
        try store.save(profile, key: "agk-K")
        try store.delete(id: profile.id)

        T.equal(store.all().count, 0, "profile gone")
        T.isNil(keys.key(for: profile.id), "key gone from the key store")
    }
}

T.suite("an existing setup is imported as a profile on first run") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let store = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let imported = store.migrateFromStashIfNeeded()

        T.notNil(imported, "should import from the live settings")
        T.equal(imported?.baseURL, "https://tenant.gateway.airia.ai/anthropic", "URL imported")
        T.equal(imported?.headerName, "x-airia-key", "header name preserved")
        T.equal(store.key(for: imported!), "agk-TESTKEY", "key imported")
        T.equal(imported?.name, "Tenant", "name derived from the host")

        T.isNil(store.migrateFromStashIfNeeded(), "migration only runs once")
    }
}

T.suite("switching between two gateways swaps URL and key together") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))
        let profiles = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let enforcer = Enforcer(controller: controller, profiles: profiles, defaults: freshDefaults())

        let staging = GatewayProfile(name: "Staging", baseURL: "https://staging.example/anthropic")
        let prod    = GatewayProfile(name: "Prod",    baseURL: "https://prod.example/anthropic")
        try profiles.save(staging, key: "agk-STAGING")
        try profiles.save(prod,    key: "agk-PROD")

        enforcer.select(.gateway(profileID: staging.id))
        T.equal(SettingsStore(paths: paths).currentMode(), .gateway(url: staging.baseURL), "on staging")
        T.equal(try env(paths)["ANTHROPIC_CUSTOM_HEADERS"] as? String,
                "x-airia-key: agk-STAGING", "staging key applied")

        enforcer.select(.gateway(profileID: prod.id))
        T.equal(SettingsStore(paths: paths).currentMode(), .gateway(url: prod.baseURL), "on prod")
        T.equal(try env(paths)["ANTHROPIC_CUSTOM_HEADERS"] as? String,
                "x-airia-key: agk-PROD", "prod key replaced staging's, not appended")

        T.equal(enforcer.evaluate(), .inSync, "still idempotent with profiles")
    }
}

T.suite("enforcement holds a specific gateway against drift") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))
        let profiles = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let enforcer = Enforcer(controller: controller, profiles: profiles, defaults: freshDefaults())

        let prod = GatewayProfile(name: "Prod", baseURL: "https://prod.example/anthropic")
        try profiles.save(prod, key: "agk-PROD")
        enforcer.select(.gateway(profileID: prod.id))

        // airiad rewrites settings to the tenant's own gateway.
        try paths.seed(realShape)
        T.equal(enforcer.evaluate(), .corrected(to: .gateway(profileID: prod.id)),
                "a different gateway counts as drift, not just direct-vs-gateway")
        T.equal(SettingsStore(paths: paths).currentMode(), .gateway(url: prod.baseURL), "back on prod")
    }
}

T.suite("selecting a deleted gateway fails instead of doing something surprising") {
    try withTempClaudeDir { paths in
        try paths.seed(realShape)
        let fake = FakeLaunchctl()
        let controller = GatewayController(paths: paths, agent: try fakeAgent(in: paths, fake))
        let profiles = ProfileStore(paths: paths, keyStore: InMemoryKeyStore())
        let enforcer = Enforcer(controller: controller, profiles: profiles, defaults: freshDefaults())

        let gone = GatewayProfile(name: "Gone", baseURL: "https://gone.example/anthropic")
        try profiles.save(gone, key: "k")
        enforcer.select(.gateway(profileID: gone.id))
        try profiles.delete(id: gone.id)

        if case .failed = enforcer.evaluate() {} else {
            T.expect(false, "a dangling profile selection must surface as a failure")
        }
    }
}

T.report()
