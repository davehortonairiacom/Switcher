import SwiftUI
import SwitcherKit

@main
struct SwitcherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RootPanel(model: model)
        } label: {
            Image(systemName: model.symbolName)
        }
        // .window rather than .menu: a plain NSMenu can't show brand marks,
        // subtitles or an inline edit button.
        .menuBarExtraStyle(.window)

        // Value-presented, so no window exists until one is explicitly opened.
        WindowGroup(id: "gateway-editor", for: GatewayEditorRequest.self) { $request in
            GatewayEditor(model: model, request: request ?? .new)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
