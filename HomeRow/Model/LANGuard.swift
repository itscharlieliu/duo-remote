import Foundation
import Darwin

/// Keeps Home Row on the local network.
///
/// Two checks: `validateName` runs when a Mac is saved (cheap, on the string),
/// and `resolve` runs before every connection and checks every address the
/// name actually resolves to. The second check is the one that matters — a
/// name like "studio.example.com" could point anywhere, so names are only
/// trusted after resolution lands on a private address.
enum LANGuard {
    enum Failure: LocalizedError {
        case notLocal(String)
        case unresolvable(String)

        var errorDescription: String? {
            switch self {
            case .notLocal(let host):
                "\(host) isn’t on your local network. Home Row only connects to Macs on the same Wi-Fi."
            case .unresolvable(let host):
                "Couldn’t find \(host) on this network. Is the Mac awake and on the same Wi-Fi?"
            }
        }
    }

    /// Accepts `.local` names, bare hostnames, and private/link-local IPs.
    static func validateName(_ raw: String) -> Failure? {
        let host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return .notLocal(raw) }
        if let ip = IPAddress(host) { return ip.isLocal ? nil : .notLocal(raw) }
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        if trimmed.hasSuffix(".local") || !trimmed.contains(".") { return nil }
        // Any other dotted name: allowed to be saved, but `resolve` will refuse
        // it unless every address it resolves to is private.
        return nil
    }

    /// Resolves `host` and returns its first address, throwing unless every
    /// resolved address is on the LAN.
    ///
    /// If `fallback` is given (a previously learned address, see
    /// `Mac.lastAddress`), it is tried only when the primary name fails to
    /// resolve — the case for a `.local` name over a VPN, where mDNS does
    /// not cross the tunnel. The fallback must itself pass the same local
    /// check, and the primary name is always tried first, so a stale
    /// fallback never shadows a working name. If the fallback also fails,
    /// the primary error is thrown, since that is the one the user can act on.
    static func resolve(_ host: String, port: Int, fallback: String? = nil) async throws -> String {
        do {
            return try await resolveOnce(host, port: port)
        } catch let primaryError {
            guard let fallback, !fallback.isEmpty,
                  fallback.lowercased() != host.lowercased() else { throw primaryError }
            do {
                return try await resolveOnce(fallback, port: port)
            } catch {
                throw primaryError
            }
        }
    }

    /// Single resolution attempt, with the LAN check described above.
    private static func resolveOnce(_ host: String, port: Int) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_family = AF_UNSPEC
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, String(port), &hints, &result)
            guard status == 0, let first = result else { throw Failure.unresolvable(host) }
            defer { freeaddrinfo(result) }

            var addresses: [IPAddress] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                if let ip = IPAddress(sockaddr: info.pointee.ai_addr) { addresses.append(ip) }
                cursor = info.pointee.ai_next
            }
            guard !addresses.isEmpty else { throw Failure.unresolvable(host) }
            guard addresses.allSatisfy(\.isLocal) else { throw Failure.notLocal(host) }
            // Prefer IPv4: it's what Screen Sharing and Wake-on-LAN want.
            return (addresses.first { $0.isV4 } ?? addresses[0]).string
        }.value
    }
}

struct IPAddress {
    let bytes: [UInt8]
    var isV4: Bool { bytes.count == 4 }

    init?(_ string: String) {
        var v4 = in_addr()
        var v6 = in6_addr()
        let s = string.split(separator: "%").first.map(String.init) ?? string
        if inet_pton(AF_INET, s, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, s, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
    }

    init?(sockaddr pointer: UnsafeMutablePointer<sockaddr>?) {
        guard let pointer else { return nil }
        switch Int32(pointer.pointee.sa_family) {
        case AF_INET:
            bytes = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
        case AF_INET6:
            bytes = pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
        default:
            return nil
        }
    }

    var isLocal: Bool {
        if isV4 {
            let (a, b) = (bytes[0], bytes[1])
            return a == 10
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168)
                || (a == 169 && b == 254)
                || a == 127
        }
        // IPv4-mapped IPv6 (::ffff:a.b.c.d)
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            var mapped = Array(bytes[12...])
            return IPAddress(raw: &mapped).isLocal
        }
        return (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) // fe80::/10 link-local
            || (bytes[0] & 0xFE) == 0xFC                        // fc00::/7 unique local
            || (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1) // ::1
    }

    private init(raw: inout [UInt8]) { bytes = raw }

    var string: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var copy = bytes
        let family = isV4 ? AF_INET : AF_INET6
        _ = inet_ntop(family, &copy, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }
}

/// The phone's own Wi-Fi subnet, for the "Scanning 192.168.1.0/24" line.
enum LocalNetwork {
    static func wifiSubnet() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }
            let name = String(cString: iface.pointee.ifa_name)
            guard name == "en0",
                  let addr = iface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = iface.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            var network = in_addr(s_addr: ip & netmask)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &network, &buffer, socklen_t(buffer.count))
            let prefix = UInt32(bigEndian: netmask).nonzeroBitCount
            return "\(String(cString: buffer))/\(prefix)"
        }
        return nil
    }
}
