import SwiftUI
import OpenMountainDuckCore

/// Preferences view rendered in-place within the menu bar popover.
public struct PreferencesView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var maxCacheSizeGB: Double = 5.0
    @State private var launchAtLogin: Bool = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header with Back Button
            HStack {
                Button(action: {
                    viewModel.currentScreen = .main
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Spacer()

                Text("Preferences")
                    .font(.headline)

                Spacer()

                Text("Back").opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Cache Settings
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LOCAL CACHE LIMIT").font(.caption).bold().foregroundColor(.secondary)

                        HStack {
                            Slider(value: $maxCacheSizeGB, in: 1.0...50.0, step: 1.0)
                            Text("\(Int(maxCacheSizeGB)) GB")
                                .frame(width: 50, alignment: .trailing)
                                .bold()
                        }

                        HStack {
                            Text("Current Usage:")
                                .font(.caption)
                            Spacer()
                            Text("\(ByteCountFormatter.string(fromByteCount: viewModel.cacheStats.totalSizeBytes, countStyle: .file)) / \(Int(maxCacheSizeGB)) GB")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Clear Unpinned Cache Now") {
                            viewModel.purgeCache()
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)

                    // System settings
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SYSTEM & STARTUP").font(.caption).bold().foregroundColor(.secondary)
                        Toggle("Launch at macOS login", isOn: $launchAtLogin)
                            .font(.subheadline)
                        Toggle("File transfer notifications", isOn: .constant(true))
                            .font(.subheadline)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)

                    // About
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenMountainDuck 1.0.0 (Open-Source)")
                            .font(.caption).bold()
                        Text("Native macOS Remote Cloud Filesystem Mounter")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 480)
    }
}
