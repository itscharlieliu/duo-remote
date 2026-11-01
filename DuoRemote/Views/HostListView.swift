import SwiftUI

/// Hosts tab: pick a Mac, connect/disconnect, add or edit one, and see
/// Bonjour-discovered Macs on this network. Passwords are entered here and
/// go straight to the Keychain — they are never shown back.
struct HostListView: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var discovery = DiscoveryService()
    @State private var editingHost: HostProfile?
    @State private var showingEditor = false
    @State private var sshPassword = ""
    @State private var vncPassword = ""
    @State private var connectError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Macs") {
                    ForEach(store.hosts) { host in
                        Button {
                            store.selectedHostID = host.id
                            sshPassword = KeychainStore.read(kind: .ssh, hostID: host.id) ?? ""
                            vncPassword = KeychainStore.read(kind: .vnc, hostID: host.id) ?? ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(host.name).font(.headline)
                                    Text("\(host.host):\(host.sshPort) · VNC :\(host.vncPort)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.selectedHostID == host.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .swipeActions {
                            Button("Edit") { editingHost = host; showingEditor = true }
                            Button("Delete", role: .destructive) { store.removeHost(host) }
                        }
                    }
                }

                if let host = store.selectedHost {
                    Section("Connect to \(host.name)") {
                        SecureField("macOS password (SSH)", text: $sshPassword)
                            .textContentType(.password)
                        if host.useVNCPassword {
                            SecureField("VNC password", text: $vncPassword)
                                .textContentType(.password)
                        }
                        if let error = connectError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Button("Connect terminal + desktop") {
                            connect(host: host)
                        }
                        Button("Disconnect", role: .destructive) {
                            store.disconnectAll()
                        }
                    }
                }

                Section("Found on this network") {
                    if discovery.discovered.isEmpty {
                        Text("Searching… make sure this phone and the Mac are on the same Wi-Fi.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(discovery.discovered) { found in
                        Button {
                            let profile = HostProfile(
                                name: found.name, host: found.host,
                                sshUsername: store.selectedHost?.sshUsername ?? "")
                            store.addHost(profile)
                        } label: {
                            HStack {
                                Text(found.name)
                                Spacer()
                                if found.hasSSH { Text("SSH").font(.caption) }
                                if found.hasVNC { Text("VNC").font(.caption) }
                            }
                        }
                    }
                }

                Section("Mac setup") {
                    Text("On the Mac: System Settings → General → Sharing → turn on Remote Login (SSH) and Screen Sharing, then in Screen Sharing turn on “VNC viewers may control screen with password” and set that password. Full steps are in the repo README.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Hosts")
            .toolbar {
                Button {
                    editingHost = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showingEditor) {
                HostEditorView(host: editingHost) { profile in
                    if editingHost == nil {
                        store.addHost(profile)
                    } else {
                        store.updateHost(profile)
                    }
                    showingEditor = false
                }
            }
            .onAppear {
                discovery.start()
                if let host = store.selectedHost {
                    sshPassword = KeychainStore.read(kind: .ssh, hostID: host.id) ?? ""
                    vncPassword = KeychainStore.read(kind: .vnc, hostID: host.id) ?? ""
                }
            }
            .onDisappear { discovery.stop() }
            .onChange(of: store.selectedHostID) { _, _ in
                if let host = store.selectedHost {
                    sshPassword = KeychainStore.read(kind: .ssh, hostID: host.id) ?? ""
                    vncPassword = KeychainStore.read(kind: .vnc, hostID: host.id) ?? ""
                }
            }
        }
    }

    private func connect(host: HostProfile) {
        if let problem = LANValidation.validate(host) {
            connectError = problem
            return
        }
        if sshPassword.isEmpty {
            connectError = "Enter the macOS password for SSH."
            return
        }
        if host.useVNCPassword, vncPassword.isEmpty {
            connectError = "Enter the VNC password, or turn off “Use VNC password” for this host."
            return
        }
        connectError = nil
        KeychainStore.save(sshPassword, kind: .ssh, hostID: host.id)
        if host.useVNCPassword {
            KeychainStore.save(vncPassword, kind: .vnc, hostID: host.id)
        }
        store.connectAll(sshPassword: sshPassword, vncPassword: host.useVNCPassword ? vncPassword : nil)
    }
}

private struct HostEditorView: View {
    let host: HostProfile?
    let onSave: (HostProfile) -> Void

    @State private var name: String
    @State private var address: String
    @State private var sshPort: String
    @State private var username: String
    @State private var vncPort: String
    @State private var useVNCPassword: Bool
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(host: HostProfile?, onSave: @escaping (HostProfile) -> Void) {
        self.host = host
        self.onSave = onSave
        _name = State(initialValue: host?.name ?? "")
        _address = State(initialValue: host?.host ?? "")
        _sshPort = State(initialValue: host.map { String($0.sshPort) } ?? "22")
        _username = State(initialValue: host?.sshUsername ?? "")
        _vncPort = State(initialValue: host.map { String($0.vncPort) } ?? "5900")
        _useVNCPassword = State(initialValue: host?.useVNCPassword ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("IP or .local name", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("macOS username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("SSH port", text: $sshPort)
                    .keyboardType(.numberPad)
                TextField("VNC port", text: $vncPort)
                    .keyboardType(.numberPad)
                Toggle("VNC password", isOn: $useVNCPassword)
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .navigationTitle(host == nil ? "Add Mac" : "Edit Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let profile = HostProfile(
            id: host?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: address.trimmingCharacters(in: .whitespaces),
            sshPort: Int(sshPort) ?? 22,
            sshUsername: username.trimmingCharacters(in: .whitespaces),
            vncPort: Int(vncPort) ?? 5900,
            useVNCPassword: useVNCPassword)
        if let problem = LANValidation.validate(profile) {
            error = problem
            return
        }
        onSave(profile)
    }
}
