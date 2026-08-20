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
        setDockIconForBareRuns()
    }

    /// Backend children don't die with the app on their own — take down any
    /// in-flight transcription/render on quit. (If the app is SIGKILLed,
    /// the backend's own parent-watchdog handles it instead.)
    func applicationWillTerminate(_ notification: Notification) {
        BackendProcessRegistry.shared.terminateAll()
    }

    /// A bundled launch gets the icon from Info.plist; a bare executable
    /// has no bundle, so load the icns from the repo (dev machines only).
    private func setDockIconForBareRuns() {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            dir.deleteLastPathComponent()
            let icns = dir.appendingPathComponent("assets/icon/Piko.icns")
            if let image = NSImage(contentsOf: icns) {
                NSApp.applicationIconImage = image
                return
            }
        }
    }
}

@main
struct PikoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}
