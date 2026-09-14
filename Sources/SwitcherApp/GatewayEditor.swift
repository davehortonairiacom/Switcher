import SwiftUI
import SwitcherKit

/// New / Edit sheet for a gateway. Opens as its own window because the menu bar
/// panel dismisses as soon as focus moves elsewhere.
struct GatewayEditor: View {
    @ObservedObject var model: AppModel
    let request: GatewayEditorRequest
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = ""
    @State private var headerName = GatewayProfile.defaultHeaderName
    @State private var apiKey = ""
    @State private var validationError: String?
    @State private var confirmingDelete = false
    @State private var loaded = false

    private var editingID: UUID? {
        if case let .edit(id) = request { return id }
        return nil
    }
    private var isEditing: Bool { editingID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Edit Gateway" : "New Gateway")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 12) {
                Field(label: "Name", help: "Shown in the menu, e.g. “Staging”.") {
                    TextField("Staging", text: $name)
                }
                Field(label: "URL", help: "Becomes ANTHROPIC_BASE_URL.") {
                    TextField("https://tenant.gateway.airia.ai/anthropic", text: $baseURL)
                }
                Field(label: "API key", help: "Stored in your Keychain, not on disk.") {
                    SecureField(isEditing ? "unchanged" : "agk-…", text: $apiKey)
                }
                Field(label: "Header", help: "Header the key is sent under.") {
                    TextField(GatewayProfile.defaultHeaderName, text: $headerName)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 20)

            if let validationError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(validationError).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            Spacer(minLength: 18)

            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .confirmationDialog("Delete this gateway?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let editingID { model.delete(id: editingID) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its API key is removed from your Keychain too. This can't be undone.")
        }
    }

    private func load() {
        guard !loaded else { return }   // onAppear can fire more than once
        loaded = true
        guard let editingID, let profile = model.profile(id: editingID) else { return }
        name = profile.name
        baseURL = profile.baseURL
        headerName = profile.headerName
        apiKey = model.key(for: profile)
    }

    private func save() {
        let candidate = GatewayProfile(id: editingID ?? UUID(),
                                       name: name,
                                       baseURL: baseURL,
                                       headerName: headerName)
        guard candidate.validated() != nil else {
            validationError = "Give it a name and a full URL including https://."
            return
        }
        validationError = nil
        if model.save(candidate, key: apiKey) {
            dismiss()
        } else {
            validationError = model.lastError ?? "Couldn't save."
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    let help: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                content
                Text(help).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}
