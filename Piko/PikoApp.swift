import AppKit
import SwiftUI

/// When run as a bare SPM executable (Xcode "Run" or `swift run`) there is
/// no app bundle, so macOS does not treat the process as a regular app:
/// no Dock icon, and the window opens unfocused behind other apps.
/// Forcing the activation policy fixes both; a bundled launch is unaffected.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct PikoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
    }
}
