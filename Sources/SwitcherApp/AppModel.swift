import AppKit
import ServiceManagement
import SwiftUI
import SwitcherKit

/// Which editor the window should open as.
enum GatewayEditorRequest: Hashable, Codable {
    case new
    case edit(UUID)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [GatewayProfile] = []
    @Published private(set) var actual: Mode = .direct
    @Published private(set) var desired: DesiredMode = .unmanaged
    @Published private(set) var agent: AgentStatus = .notInstalled
    @Published private(set) var trippedReason: String?
    @Published private(set) var claudeCodeRunning = false
    @Published private(set) var busy = false
    @Published var lastError: String?

    private let controller: GatewayController
    private let profileStore: ProfileStore
    private let enforcer: Enforcer
    private var watcher: SettingsWatcher?

    init() {
        let paths = Paths.live
        controller = GatewayController(paths: paths)
        profileStore = ProfileStore(paths: paths)
        enforcer = Enforcer(controller: controller, profiles: profileStore)

        // Turn an existing script-based setup into a profile so the list isn't
        // empty on first launch.
        profileStore.migrateFromStashIfNeeded()

        watcher = SettingsWatcher(url: paths.settings) { [weak self] in
            Task { @MainActor in self?.settingsChangedExternally() }
        }
        watcher?.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enforceNow() }
        }

        refresh()
        enforceNow()
    }

    // MARK: - State

    func refresh() {
        profiles = profileStore.all()
        actual = controller.currentMode()
        agent = controller.agentStatus()
        desired = enforcer.desired
        trippedReason = enforcer.snapshot().trippedReason
        claudeCodeRunning = ProcessProbe.isClaudeCodeRunning()
    }

    private func settingsChangedExternally() {
        refresh()
        enforceNow()
    }

    private func enforceNow() {
        guard !busy else { return }
        if case let .failed(message) = enforcer.evaluate() { lastError = message }
        refresh()
    }

    /// The profile whose URL is live in settings.json right now, if any.
    var activeProfileID: UUID? {
        guard let url = actual.gatewayURL else { return nil }
        return profiles.first { $0.baseURL == url }?.id
    }

    func isDesired(_ mode: DesiredMode) -> Bool { desired == mode }

    func key(for profile: GatewayProfile) -> String { profileStore.key(for: profile) ?? "" }

    func profile(id: UUID) -> GatewayProfile? { profiles.first { $0.id == id } }

    // MARK: - Switching

    func select(_ mode: DesiredMode) {
        guard !busy else { return }
        busy = true
        lastError = nil
        // switchToGateway can block for up to 25s waiting on the agent, so keep
        // it off the main actor or the panel freezes.
        Task.detached { [enforcer] in
            let result = enforcer.select(mode)
            await MainActor.run {
                self.busy = false
                if case let .failed(message) = result { self.lastError = message }
                self.refresh()
            }
        }
    }

    // MARK: - Profile editing

    func save(_ profile: GatewayProfile, key: String) -> Bool {
        do {
            try profileStore.save(profile, key: key)
            refresh()
            // Editing the gateway you're currently on should take effect now.
            if case let .gateway(id) = desired, id == profile.id {
                select(.gateway(profileID: profile.id))
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func delete(id: UUID) {
        do {
            try profileStore.delete(id: id)
            // Don't leave the selection pointing at something that's gone.
            if case let .gateway(selected) = desired, selected == id {
                enforcer.desired = .unmanaged
            }
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Login item

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Needs the app to live somewhere stable, e.g. ~/Applications —
            // running straight out of dist/ can legitimately fail here.
            lastError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func clearBreaker() {
        enforcer.resetBreaker()
        refresh()
        enforceNow()
    }

    // MARK: - Menu bar presentation

    var symbolName: String {
        if trippedReason != nil { return "exclamationmark.triangle.fill" }
        switch actual {
        case .gateway:    return "arrow.triangle.branch"
        case .direct:     return "arrow.up.right"
        case .unreadable: return "questionmark.diamond"
        }
    }

    var currentRouteName: String {
        switch actual {
        case .direct: return "Anthropic"
        case let .gateway(url):
            return profiles.first { $0.baseURL == url }?.name ?? "Gateway"
        case .unreadable: return "Unknown"
        }
    }
}
