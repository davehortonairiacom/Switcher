import AppKit
import SwiftUI

/// Brand marks for the route rows, loaded from the bundle.
///
/// Rendered as template images so they take the menu's foreground colour and
/// work in both light and dark appearance.
enum RouteIcons {
    static let airia = load("airia-mark")
    static let anthropic = load("anthropic-mark")

    private static func load(_ name: String) -> NSImage? {
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        return image
    }
}

/// Falls back to an SF Symbol when the bundled asset is missing, so the UI still
/// renders when run outside a bundle (e.g. `swift run`).
struct RouteIcon: View {
    let image: NSImage?
    let fallbackSymbol: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: fallbackSymbol).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}
