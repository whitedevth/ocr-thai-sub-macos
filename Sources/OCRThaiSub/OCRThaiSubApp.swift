import AppKit
import SwiftUI

@main
struct OCRThaiSubApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        // Needed when launched as a bare executable (swift run) so the window takes focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // One window: the video's Metal layer can only be shown in one place.
        Window("OCR Thai Sub", id: "main") {
            ContentView(capture: model.capture, apple: model.apple)
                .environmentObject(model)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1280, height: 760)
    }
}

/// Closing the window quits, so capture and paid translation don't keep running unseen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
