import SwiftUI
import OpenDuckCore
import AppKit

/// Form view for configuring new remote server connections with clean native layout.
public struct AddEditConnectionSheet: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var name: String = ""
    @State private var protocolType: RemoteProtocol = .sftp
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var authType: AuthenticationType = .password
    @State private var passwordSecret: String = ""
    @State private var privateKeyPath: String = ""
    @State private var remoteRootPath: String = "/"
    @State private var autoConnect: Bool = false
    @State private var isReadOnly: Bool = false

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

                Text("New Connection")
                    .font(.headline)

                Spacer()

                // Invisible balancer to center title
                Text("Back").opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Protocol Dropdown
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROTOCOL").font(.caption).bold().foregroundColor(.secondary)
                        Picker("", selection: $protocolType) {
                            ForEach(RemoteProtocol.allCases, id: \.self) { proto in
                                Text(proto.rawValue).tag(proto)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)

                    // Connection Parameters
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SERVER SETTINGS").font(.caption).bold().foregroundColor(.secondary)

                        // Name
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connection Name")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. My SFTP Server", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        if protocolType != .mock {
                            // Host & Port
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Server Host")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("hostname or IP", text: $host)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Port")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("22", text: $port)
                                        .frame(width: 60)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            // Username
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Username")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("username", text: $username)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        // Remote Path
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remote Root Directory")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("/", text: $remoteRootPath)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)

                    // Authentication (if not mock)
                    if protocolType == .sftp {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("AUTHENTICATION").font(.caption).bold().foregroundColor(.secondary)

                            Picker("", selection: $authType) {
                                Text("Password").tag(AuthenticationType.password)
                                Text("SSH Key").tag(AuthenticationType.sshKey)
                            }
                            .pickerStyle(.segmented)

                            if authType == .password {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Password (stored in Keychain)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    SecureField("Password", text: $passwordSecret)
                                        .textFieldStyle(.roundedBorder)
                                }
                            } else if authType == .sshKey {
                                VStack(alignment: .leading, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Private Key File")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        HStack {
                                            TextField("~/.ssh/id_ed25519", text: $privateKeyPath)
                                                .textFieldStyle(.roundedBorder)
                                            Button("Browse...") {
                                                browseKeyFile()
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Passphrase (optional)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        SecureField("Key Passphrase", text: $passwordSecret)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(8)
                    }

                    Toggle("Connect automatically on app launch", isOn: $autoConnect)
                        .font(.subheadline)
                        .padding(.horizontal, 4)

                    Toggle("Read-Only / Safe Preview Mode (Protects Remote Data)", isOn: $isReadOnly)
                        .font(.subheadline)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }

            Divider()

            // Footer Actions
            HStack {
                Button("Cancel") {
                    viewModel.currentScreen = .main
                }
                .buttonStyle(.plain)
                .font(.body)

                Spacer()

                Button("Save & Connect") {
                    saveProfile()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 400, height: 500)
    }

    private func browseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key"
        panel.showsHiddenFiles = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }

    private func saveProfile() {
        let portInt = Int(port) ?? (protocolType == .sftp ? 22 : 80)
        let profile = ServerProfile(
            name: name.isEmpty ? "Server (\(host))" : name,
            protocolType: protocolType,
            host: host.isEmpty ? "localhost" : host,
            port: portInt,
            username: username,
            authType: authType,
            privateKeyPath: privateKeyPath.isEmpty ? nil : privateKeyPath,
            remoteRootPath: remoteRootPath.isEmpty ? "/" : remoteRootPath,
            autoConnect: autoConnect,
            isReadOnly: isReadOnly
        )
        viewModel.addProfile(profile, secret: passwordSecret)
    }
}
