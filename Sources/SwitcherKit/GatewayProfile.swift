import Foundation

/// A named gateway you can route through.
///
/// The API key is deliberately **not** stored here — it lives in the Keychain,
/// addressed by `id`. Only the non-secret metadata is written to disk.
public struct GatewayProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    /// Header name the key is sent under. Airia uses `x-airia-key`, but other
    /// gateways differ, so it travels with the profile.
    public var headerName: String

    public static let defaultHeaderName = "x-airia-key"

    public init(id: UUID = UUID(),
                name: String,
                baseURL: String,
                headerName: String = GatewayProfile.defaultHeaderName) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.headerName = headerName
    }

    /// Trimmed, validated form. Returns nil when the profile isn't usable.
    public func validated() -> GatewayProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHeader = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty,
              let url = URL(string: trimmedURL), url.scheme != nil, url.host != nil
        else { return nil }
        return GatewayProfile(id: id, name: trimmedName, baseURL: trimmedURL,
                              headerName: trimmedHeader.isEmpty ? Self.defaultHeaderName : trimmedHeader)
    }

    /// The full header line written into ANTHROPIC_CUSTOM_HEADERS.
    public func headerLine(key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "\(headerName): \(trimmed)"
    }
}
