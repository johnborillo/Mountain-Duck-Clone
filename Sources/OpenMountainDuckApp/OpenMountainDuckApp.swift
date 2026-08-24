import SwiftUI
import AppKit

@main
struct OpenMountainDuckApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra("OpenMountainDuck", systemImage: "externaldrive.badge.icloud") {
            MenuBarView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
