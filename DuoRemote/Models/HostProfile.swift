import Foundation

/// One Mac on the home LAN. Passwords are never stored here — see KeychainStore.
/// Everything in this struct is safe to persist in UserDefaults.
struct HostProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var host: String          // IP address or `<name>.local`
    var sshPort: Int = 22
    var sshUsername: String
    var vncPort: Int = 5900
    var useVNCPassword: Bool = true

    /// A sensible default for a first run. Edit the IP/username in the app.
    static var example: HostProfile {
        HostProfile(name: "Mac mini", host: "192.168.0.195", sshUsername: "charlie")
    }
}

/// LAN-only enforcement.
///
/// Only RFC 1918 private addresses and `.local` (Bonjour) names are accepted.
/// Anything else — a public IP, a random hostname — is refused before any
/// socket is opened, so the app can never be pointed at a Mac over the internet.
enum LANValidation {
    static func isPrivateOrLocal(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix(".local") { return true }
        // IPv4: 10/8, 172.16/12, 192.168/16, plus loopback for local testing.
        let parts = trimmed.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 127 { return true }
        return false
    }

    static func validate(_ profile: HostProfile) -> String? {
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Give the Mac a name."
        }
        if !isPrivateOrLocal(profile.host) {
            return "LAN only: use a private IP (10.x, 172.16–31.x, 192.168.x) or a .local name."
        }
        if !(1...65535).contains(profile.sshPort) || !(1...65535).contains(profile.vncPort) {
            return "Ports must be between 1 and 65535."
        }
        if profile.sshUsername.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the macOS username for SSH."
        }
        return nil
    }
}
