import Foundation
import Combine

/// App-wide session state: the host list, the selected Mac, and the two
/// live connections (SSH + VNC). Views read this; they never own sockets.
@MainActor
final class SessionStore: ObservableObject {
    @Published var hosts: [HostProfile] {
        didSet { persistHosts() }
    }
    @Published var selectedHostID: UUID?
    @Published var ssh = SSHSession()
    @Published var vnc = VNCClient()

    var selectedHost: HostProfile? {
        hosts.first { $0.id == selectedHostID }
    }

    private static let hostsKey = "duoRemote.hosts.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.hostsKey),
           let decoded = try? JSONDecoder().decode([HostProfile].self, from: data),
           !decoded.isEmpty {
            hosts = decoded
        } else {
            hosts = [HostProfile.example]
        }
        selectedHostID = hosts.first?.id
    }

    private func persistHosts() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.hostsKey)
        }
    }

    func addHost(_ profile: HostProfile) {
        hosts.append(profile)
        selectedHostID = profile.id
    }

    func updateHost(_ profile: HostProfile) {
        if let index = hosts.firstIndex(where: { $0.id == profile.id }) {
            hosts[index] = profile
        }
    }

    func removeHost(_ profile: HostProfile) {
        hosts.removeAll { $0.id == profile.id }
        KeychainStore.delete(kind: .ssh, hostID: profile.id)
        KeychainStore.delete(kind: .vnc, hostID: profile.id)
        if selectedHostID == profile.id {
            selectedHostID = hosts.first?.id
        }
    }

    // MARK: - Connect / disconnect

    /// Connects SSH and VNC independently: if VNC is misconfigured, the
    /// terminal still works, and vice versa. Each pane shows its own error.
    func connectAll(sshPassword: String, vncPassword: String?) {
        guard let host = selectedHost else { return }
        ssh.connect(profile: host, password: sshPassword)
        if host.useVNCPassword {
            vnc.connect(host: host.host, port: host.vncPort, password: vncPassword)
        } else {
            vnc.connect(host: host.host, port: host.vncPort, password: nil)
        }
    }

    func disconnectAll() {
        ssh.disconnect()
        vnc.disconnect()
    }
}
