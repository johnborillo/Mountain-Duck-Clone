import SwiftUI
import OpenDuckCore

/// Main popover view rendered in the macOS Menu Bar.
@MainActor
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

                if let speed = viewModel.totalTransferSpeedFormatted {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 11))
                        Text(speed)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(4)
                }

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

            // Active & Recent Transfers Section
            if !viewModel.activeTransfers.isEmpty || !viewModel.recentTransfers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("TRANSFERS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)

                        Spacer()

                        if !viewModel.activeTransfers.isEmpty {
                            Text("\(viewModel.activeTransfers.count) active")
                                .font(.system(size: 10))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ForEach(viewModel.activeTransfers) { transfer in
                        activeTransferCard(for: transfer)
                    }

                    ForEach(viewModel.recentTransfers.prefix(2)) { transfer in
                        recentTransferRow(for: transfer)
                    }
                }
                .padding(.bottom, 6)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))

                Divider()
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
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.subheadline).bold()
                        if profile.isReadOnly {
                            Text("READ-ONLY")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
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

            // Secondary Action Row (Available in both mounted & unmounted states)
            HStack(spacing: 12) {
                if isMounted {
                    Button(action: {
                        viewModel.openInFinder(for: profile)
                    }) {
                        Label("Open in Finder", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Button(action: {
                        Task { await viewModel.syncVolume(profile: profile) }
                    }) {
                        Label("Sync", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    if viewModel.isCircuitBreakerTripped(for: profile) {
                        Button(action: {
                            viewModel.resetCircuitBreaker(for: profile)
                        }) {
                            Label("Reset Shield", systemImage: "shield.slash")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Spacer()

                // Edit Connection Button
                Button(action: {
                    viewModel.startEditing(profile: profile)
                }) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit Connection")

                // Delete Connection Button
                Button(action: {
                    viewModel.deleteProfile(profile.id)
                }) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete Connection")
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func activeTransferCard(for transfer: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: transfer.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 13))

                Text(transfer.fileName)
                    .font(.caption).bold()
                    .lineLimit(1)

                Spacer()

                if !transfer.formattedSpeed.isEmpty {
                    Text(transfer.formattedSpeed)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.accentColor)
                }

                if !transfer.formattedETA.isEmpty {
                    Text(transfer.formattedETA)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // Cancel Transfer Action
                Button(action: {
                    viewModel.cancelTransfer(transfer, deleteItem: false)
                }) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel Transfer")

                // Cancel & Delete File Action
                Button(action: {
                    viewModel.cancelTransfer(transfer, deleteItem: true)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel & Delete Item")
            }

            ProgressView(value: transfer.progressFraction)
                .progressViewStyle(.linear)

            HStack {
                Text(transfer.formattedTransferred)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Spacer()

                Text(transfer.percentageString)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func recentTransferRow(for transfer: TransferProgress) -> some View {
        HStack(spacing: 6) {
            Image(systemName: transfer.state == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(transfer.state == .completed ? .green : .red)
                .font(.system(size: 11))

            Text(transfer.fileName)
                .font(.system(size: 10))
                .lineLimit(1)

            Spacer()

            Text(transfer.state.rawValue)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}
