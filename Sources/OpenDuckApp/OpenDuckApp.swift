import SwiftUI
import AppKit

@main
struct OpenDuckApp: App {
    @StateObject private var viewModel = AppViewModel()

    init() {
        // Configure as a background Menu Bar accessory (hides from the Dock and Cmd+Tab)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("OpenDuck", systemImage: "externaldrive.badge.icloud") {
            MenuBarView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
