import SwiftUI
import OpenDuckCore

/// Main popover view rendered in the macOS Menu Bar.
public struct MenuBarView: View {
    @ObservedObject var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch viewModel.currentScreen {
            case .main:
                mainContentView
            case .addConnection:
                AddEditConnectionSheet(viewModel: viewModel)
            case .preferences:
                PreferencesView(viewModel: viewModel)
            }
        }
        .frame(width: 400)
    }

    private var mainContentView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🦆 OpenDuck")
                    .font(.headline)

                Spacer()

                Button(action: {
                    viewModel.currentScreen = .addConnection
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Add New Connection")

                Button(action: {
                    viewModel.currentScreen = .preferences
                }) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Preferences")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Status message toast if present
            if let status = viewModel.statusMessage {
                HStack {
                    if viewModel.isMounting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
            }

            // Connection Profile List
            if viewModel.profiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No remote connections configured.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Add Connection") {
                        viewModel.currentScreen = .addConnection
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                List {
                    ForEach(viewModel.profiles) { profile in
                        connectionCard(for: profile)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 200, maxHeight: 300)
            }

            Divider()

            // Cache Footprint & Stats Footer
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cache: \(ByteCountFormatter.string(fromByteCount: viewModel.cacheStats.totalSizeBytes, countStyle: .file))")
                        .font(.caption).bold()
                    Text("\(viewModel.cacheStats.materializedItems) files local • \(viewModel.cacheStats.dirtyItems) pending sync")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func connectionCard(for profile: ServerProfile) -> some View {
        let isMounted = viewModel.mountedDomainIDs.contains(profile.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Protocol Icon
                Image(systemName: isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                    .font(.title3)
                    .foregroundColor(isMounted ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.subheadline).bold()
                    Text("\(profile.protocolType.rawValue) • \(profile.username)@\(profile.host):\(profile.port)\(profile.remoteRootPath)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Mount / Unmount Toggle Button
                Button(action: {
                    viewModel.toggleMount(for: profile)
                }) {
                    Text(isMounted ? "Unmount" : "Mount")
                        .font(.caption).bold()
                }
                .buttonStyle(.bordered)
                .tint(isMounted ? .red : .accentColor)
                .disabled(viewModel.isMounting)
            }

            if isMounted {
                HStack(spacing: 12) {
                    Button(action: {
                        viewModel.openInFinder(for: profile)
                    }) {
                        Label("Open in Finder", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Button(action: {
                        Task { await viewModel.mount(profile: profile) }
                    }) {
                        Label("Sync", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(action: {
                        viewModel.deleteProfile(profile.id)
                    }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }
}
