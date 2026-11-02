import Foundation
import Observation

/// A Mac the user has paired with.
struct Mac: Codable, Identifiable, Hashable {
    enum Auth: String, Codable { case key, password }

    var id = UUID()
    /// Display name, usually the Bonjour service name ("Studio").
    var name: String
    /// Hostname or IP, e.g. "studio.local". Must pass `LANGuard`.
    var host: String
    var user: String
    var sshPort = 22
    var screenPort = 5900
    var auth: Auth = .key
    /// Pinned SSH host key in OpenSSH form ("ssh-ed25519 AAAA…"). `nil` until
    /// the user has verified and trusted it on the Pair screen.
    var hostKey: String?
    /// Learned over SSH after pairing; used for Wake-on-LAN.
    var macAddress: String?
    var lastAddress: String?
    var lastConnected: Date?
    /// Whether this Mac advertised Remote Login when it was added. Macs with
    /// Remote Login off can still be used for Screen Sharing.
    var hasSSH = true

    var shortHost: String {
        host.hasSuffix(".") ? String(host.dropLast()) : host
    }
}

/// The saved-Mac list (the Hosts screen). Stored as JSON in UserDefaults;
/// secrets never live here — see `Keychain`.
@MainActor
@Observable
final class MacStore {
    static let shared = MacStore()

    private(set) var macs: [Mac] = []
    private let key = "macs.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Mac].self, from: data) {
            macs = decoded
        }
    }

    func mac(id: Mac.ID) -> Mac? { macs.first { $0.id == id } }

    func upsert(_ mac: Mac) {
        if let index = macs.firstIndex(where: { $0.id == mac.id }) {
            macs[index] = mac
        } else {
            macs.append(mac)
        }
        save()
    }

    func update(_ id: Mac.ID, _ change: (inout Mac) -> Void) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        change(&macs[index])
        save()
    }

    func delete(_ id: Mac.ID) {
        macs.removeAll { $0.id == id }
        Keychain.deletePassword(for: id)
        save()
    }

    /// Finds an existing saved Mac for a Bonjour discovery, by name or host.
    func match(name: String, host: String?) -> Mac? {
        macs.first { mac in
            mac.name.caseInsensitiveCompare(name) == .orderedSame
                || (host.map { mac.shortHost.caseInsensitiveCompare($0) == .orderedSame } ?? false)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
