import SwiftUI
import Citadel

/// 02 Pair — first connection: verify the host key, choose how to sign in.
struct PairView: View {
    let target: PairTarget
    @Binding var path: NavigationPath

    @Environment(AppModel.self) private var model
    @Environment(MacStore.self) private var store
    @Environment(\.posture) private var posture

    @State private var hostKey: String?
    @State private var probeError: String?
    @State private var user = ""
    @State private var auth: Mac.Auth = .key
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    private var existing: Mac? { target.existing.flatMap(store.mac(id:)) }
    private var keyChanged: Bool {
        guard let pinned = existing?.hostKey, let hostKey else { return false }
        return !HostKeyTrust.sameKey(pinned, hostKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    EscKey()
                    ScreenTitle(text: target.hasSSH ? "Trust \(target.name)?" : "Add \(target.name)")
                    Text(explainer)
                        .font(.system(size: 13))
                        .foregroundStyle(keyChanged ? Theme.danger : Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                VStack(spacing: 12) {
                    if target.hasSSH { fingerprintWell }
                    WellField(label: "User", text: $user, placeholder: "Mac username")
                    if target.hasSSH {
                        authKeys
                        if auth == .password {
                            WellField(label: "Password", text: $password, secure: true)
                        }
                    }
                    if let error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }

            HStack {
                Spacer()
                Button { Task { await trustAndConnect() } } label: {
                    KeyLegend(top: working ? "…" : "⏎",
                              bottom: target.hasSSH ? "trust & connect" : "save",
                              alignment: .trailing)
                }
                .buttonStyle(KeyButtonStyle(lit: canSubmit, corner: .bottomTrailing))
                .frame(width: 170, height: 56)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await probe() }
        .onAppear {
            if let existing {
                user = existing.user
                auth = existing.auth
            }
        }
    }

    private var canSubmit: Bool {
        !working && !user.isEmpty
            && (!target.hasSSH || hostKey != nil)
            && (auth == .key || !password.isEmpty || !target.hasSSH)
    }

    private var explainer: String {
        if !target.hasSSH {
            return "Remote Login is off on this Mac, so it’s screen only. Turn on Remote Login in System Settings → General → Sharing for the terminal."
        }
        if keyChanged {
            return "This key doesn’t match the one you trusted before. If you didn’t reinstall macOS, don’t continue."
        }
        if let hostKey {
            return "Compare this with what the Mac prints in Terminal for: \(HostKeyTrust.verifyCommand(forOpenSSHKey: hostKey))"
        }
        return "Asking \(target.name) for its host key…"
    }

    private var fingerprintWell: some View {
        Well(radius: 12, padding: 14) {
            VStack(alignment: .leading, spacing: 2) {
                if let hostKey, let fp = HostKeyTrust.fingerprint(ofOpenSSHKey: hostKey) {
                    Text(HostKeyTrust.algorithmLabel(ofOpenSSHKey: hostKey))
                        .font(.system(size: 10)).tracking(0.6).foregroundStyle(Theme.tertiary)
                    Text(fp)
                        .font(Theme.mono(12))
                        .foregroundStyle(keyChanged ? Theme.danger : Color(hex: 0xD6D7DA))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let probeError {
                    Text(probeError).font(.system(size: 12)).foregroundStyle(Theme.danger)
                    Button("try again") { Task { await probe() } }
                        .font(.system(size: 12))
                        .padding(.top, 6)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Fetching host key…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var authKeys: some View {
        HStack(spacing: 8) {
            Button { auth = .key; Haptics.tap() } label: {
                KeyLegend(bottom: "key · \(SSHIdentity.name)", led: auth == .key)
            }
            .buttonStyle(KeyButtonStyle(lit: auth == .key))
            Button { auth = .password; Haptics.tap() } label: {
                KeyLegend(bottom: "password", led: auth == .password)
            }
            .buttonStyle(KeyButtonStyle(lit: auth == .password))
            .frame(width: 110)
        }
        .frame(height: 44)
    }

    // MARK: Actions

    private func probe() async {
        guard target.hasSSH else { return }
        probeError = nil
        do {
            hostKey = try await SSHConnector.probeHostKey(host: target.host, port: target.sshPort)
        } catch {
            probeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func trustAndConnect() async {
        working = true
        error = nil
        defer { working = false }

        var mac = existing ?? Mac(name: target.name, host: target.host, user: user)
        mac.name = target.name
        mac.host = target.host
        mac.user = user.trimmingCharacters(in: .whitespaces)
        mac.sshPort = target.sshPort
        mac.screenPort = target.screenPort
        mac.hasSSH = target.hasSSH
        mac.auth = auth

        guard target.hasSSH, let hostKey else {
            store.upsert(mac)
            finish(mac)
            return
        }
        mac.hostKey = hostKey

        do {
            switch auth {
            case .password:
                let client = try await SSHConnector.connect(to: mac, credential: .password(password))
                await learn(mac: &mac, client: client)
                Keychain.setPassword(password, for: mac.id)
            case .key:
                if !SSHIdentity.exists { try SSHIdentity.generate() }
                let key = try await Task.detached { try SSHIdentity.load(reason: "Sign in to \(target.name)") }.value
                do {
                    let client = try await SSHConnector.connect(to: mac, credential: .key(key))
                    await learn(mac: &mac, client: client)
                } catch SSHFailure.authFailed {
                    // The Mac doesn't know this phone's key yet: install it
                    // once using the account password, which is not kept.
                    guard let once = await model.prompter.ask(.init(
                        title: "Install this phone’s key",
                        message: "Enter \(mac.user)’s Mac password once. Home Row adds its public key to ~/.ssh/authorized_keys and won’t keep the password.",
                        offerRemember: false, macID: nil)) else { return }
                    let client = try await SSHConnector.connect(to: mac, credential: .password(once))
                    if let line = SSHIdentity.publicKeyLine {
                        try await SSHConnector.installPublicKey(line, using: client)
                    }
                    await learn(mac: &mac, client: client)
                    // Prove the key now works before calling it paired.
                    let check = try await SSHConnector.connect(to: mac, credential: .key(key))
                    try? await check.close()
                }
            }
            store.upsert(mac)
            finish(mac)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func learn(mac: inout Mac, client: SSHClient) async {
        if let hw = await SSHConnector.fetchMACAddress(using: client) { mac.macAddress = hw }
        try? await client.close()
    }

    private func finish(_ mac: Mac) {
        Haptics.tap()
        model.foldedTab = .hosts
        path = NavigationPath()
        if posture != .folded {
            Task { await model.openTerminal(mac) }
        }
    }
}
