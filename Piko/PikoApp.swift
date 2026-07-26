import SwiftUI

@main
struct PikoApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
    }
}
