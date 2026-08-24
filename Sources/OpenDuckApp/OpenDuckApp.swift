import SwiftUI
import AppKit

@main
struct OpenDuckApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra("OpenDuck", systemImage: "externaldrive.badge.icloud") {
            MenuBarView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
