import SwiftUI

/// 03 Hosts — saved Macs. Open the phone to start; on the outer display
/// sessions still work, with the system keyboard.
struct HostsView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacStore.self) private var store
    @Environment(Discovery.self) private var discovery
    @State private var waking: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(text: "Hosts")
                .padding(.horizontal, 20)
                .padding(.top, 10)
            ScrollView {
                VStack(spacing: 10) {
                    if store.macs.isEmpty { empty }
                    ForEach(store.macs) { mac in card(mac) }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var empty: some View {
        Well(radius: 12, padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No Macs yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Find one under discover, then verify its host key to pair.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("discover") { model.foldedTab = .discover }
                    .buttonStyle(KeyButtonStyle(radius: 8, lit: true))
                    .frame(width: 110, height: 40)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func card(_ mac: Mac) -> some View {
        let online = discovery.isOnline(mac)
        let asleep = !online && discovery.isScanning && !discovery.found.isEmpty
        Well(radius: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mac.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(status(mac, asleep: asleep)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                if asleep {
                    HStack {
                        Text(mac.shortHost).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        Spacer()
                        Button { wake(mac) } label: {
                            KeyLegend(top: "⏻", bottom: waking.contains(mac.id) ? "waking…" : "wake", alignment: .trailing)
                        }
                        .buttonStyle(KeyButtonStyle(radius: 8, corner: .bottomTrailing))
                        .frame(width: 82, height: 40)
                        .disabled(waking.contains(mac.id))
                    }
                } else {
                    HStack(spacing: 8) {
                        Button { Task { await model.openTerminal(mac) } } label: {
                            KeyLegend(top: ">_", bottom: "terminal")
                        }
                        .buttonStyle(KeyButtonStyle(radius: 8))
                        .disabled(!mac.hasSSH)
                        .opacity(mac.hasSSH ? 1 : 0.45)
                        Button { Task { await model.openScreen(mac) } } label: {
                            KeyLegend(top: "▭", bottom: "screen")
                        }
                        .buttonStyle(KeyButtonStyle(radius: 8))
                    }
                    .frame(height: 40)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
        }
        .contextMenu {
            NavigationLink(value: FoldedRoute.edit(mac.id)) { Label("Edit", systemImage: "pencil") }
            Button { wake(mac) } label: { Label("Wake", systemImage: "power") }
            Button(role: .destructive) { store.delete(mac.id) } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func status(_ mac: Mac, asleep: Bool) -> String {
        let open = model.sessionCount(for: mac)
        if open > 0 { return open == 1 ? "1 session open" : "\(open) sessions open" }
        if asleep { return "Asleep" }
        guard let last = mac.lastConnected else { return "Not connected yet" }
        if Calendar.current.isDateInToday(last) {
            return last.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(last) { return "yesterday" }
        return last.formatted(.relative(presentation: .named))
    }

    private func wake(_ mac: Mac) {
        waking.insert(mac.id)
        Task {
            await WakeOnLAN.wake(mac)
            discovery.restart()
            try? await Task.sleep(for: .seconds(6))
            waking.remove(mac.id)
            if !discovery.isOnline(mac) && mac.macAddress == nil {
                model.banner = "Couldn’t wake \(mac.name). Connect to it once over SSH while it’s awake so Home Row can learn its network address, and turn on “Wake for network access” on the Mac."
            }
        }
    }
}

/// Edit / forget host key / remove.
struct EditMacView: View {
    let macID: UUID
    @Environment(MacStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mac: Mac?
    @State private var savedPassword = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EscKey { save(); dismiss() }
                ScreenTitle(text: mac?.name ?? "Mac")
                if let binding = Binding($mac) {
                    WellField(label: "Name", text: binding.name)
                    WellField(label: "Address", text: binding.host, keyboard: .URL)
                    WellField(label: "User", text: binding.user)
                    Well {
                        VStack(spacing: 0) {
                            WellRow(title: "Host key") {
                                Text(binding.wrappedValue.hostKey.flatMap(HostKeyTrust.fingerprint(ofOpenSSHKey:))?.prefix(20).appending("…") ?? "not pinned")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                            }
                            WellRow(title: "Sign in with") {
                                Text(binding.wrappedValue.auth == .key ? "Key" : "Password").foregroundStyle(Theme.secondary)
                            }
                            WellRow(title: "Saved password", divider: false) {
                                Text(savedPassword ? "Yes" : "No").foregroundStyle(Theme.secondary)
                            }
                        }
                        .font(.system(size: 14))
                    }
                    HStack(spacing: 8) {
                        Button("forget host key") {
                            mac?.hostKey = nil
                            save()
                        }
                        .buttonStyle(KeyButtonStyle(radius: 8))
                        Button("forget password") {
                            Keychain.deletePassword(for: macID)
                            savedPassword = false
                        }
                        .buttonStyle(KeyButtonStyle(radius: 8))
                    }
                    .frame(height: 44)
                    Button {
                        store.delete(macID)
                        dismiss()
                    } label: {
                        Text("remove this Mac").foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(KeyButtonStyle(radius: 8))
                    .frame(height: 44)
                    Text("After forgetting the host key, pair again from discover to verify the new one.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            mac = store.mac(id: macID)
            savedPassword = Keychain.password(for: macID) != nil
        }
    }

    private func save() {
        guard var mac else { return }
        mac.host = mac.host.trimmingCharacters(in: .whitespaces)
        if LANGuard.validateName(mac.host) == nil { store.upsert(mac) }
    }
}
