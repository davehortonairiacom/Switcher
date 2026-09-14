import SwiftUI
import SwitcherKit

/// The menu bar panel. Uses `.window` style rather than a plain menu so rows can
/// carry brand marks, a live badge and an inline edit affordance.
struct RootPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            routes
            Divider()
            status
            Divider()
            footer
        }
        .frame(width: 380)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Routing").font(.system(size: 13, weight: .semibold))
                Text(model.busy ? "Switching…" : "Claude Code → \(model.currentRouteName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var routes: some View {
        VStack(spacing: 2) {
            RouteRow(icon: RouteIcons.anthropic,
                     fallbackSymbol: "asterisk",
                     title: "Anthropic",
                     subtitle: "api.anthropic.com — direct",
                     isSelected: model.isDesired(.direct),
                     isLive: model.actual.isDirect,
                     onSelect: { model.select(.direct) })

            ForEach(model.profiles) { profile in
                RouteRow(icon: RouteIcons.airia,
                         fallbackSymbol: "arrow.triangle.branch",
                         title: profile.name,
                         subtitle: profile.baseURL,
                         isSelected: model.isDesired(.gateway(profileID: profile.id)),
                         isLive: model.activeProfileID == profile.id,
                         onSelect: { model.select(.gateway(profileID: profile.id)) },
                         onEdit: { open(.edit(profile.id)) })
            }

            Button { open(.new) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 15))
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text("Add Gateway…").font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 6)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledLine(label: "airiad agent", value: model.agent.label)

            if model.claudeCodeRunning {
                Note(icon: "exclamationmark.triangle.fill",
                     text: "Claude Code is running — restart it to pick up a change.",
                     tint: .orange)
            }
            if let tripped = model.trippedReason {
                Note(icon: "bolt.trianglebadge.exclamationmark.fill", text: tripped, tint: .red)
                Button("Resume enforcing") { model.clearBreaker() }
                    .font(.system(size: 11))
            }
            if let error = model.lastError {
                Note(icon: "xmark.octagon.fill", text: error, tint: .red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle("Enforce", isOn: Binding(
                get: { !model.isDesired(.unmanaged) },
                set: { on in if !on { model.select(.unmanaged) } }))
                .toggleStyle(.checkbox)
                .disabled(model.isDesired(.unmanaged))
                .help("When off, Switcher watches but never corrects drift.")

            Toggle("Start at login", isOn: Binding(
                get: { model.launchesAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func open(_ request: GatewayEditorRequest) {
        openWindow(id: "gateway-editor", value: request)
        // LSUIElement apps aren't active, so a new window opens behind
        // everything unless we explicitly come forward.
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Pieces

private struct RouteRow: View {
    let icon: NSImage?
    let fallbackSymbol: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    /// Matches what's actually in settings.json right now.
    let isLive: Bool
    let onSelect: () -> Void
    var onEdit: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RouteIcon(image: icon, fallbackSymbol: fallbackSymbol)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if isLive {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.22)))
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if let onEdit, hovering {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit this gateway")
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .padding(.horizontal, 6)
    }
}

private struct LabeledLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.system(size: 11))
    }
}

private struct Note: View {
    let icon: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
}
