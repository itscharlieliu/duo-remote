import Foundation
import Network
import Observation
import dnssd

/// Bonjour scan for Macs: Remote Login advertises `_ssh._tcp`, Screen
/// Sharing advertises `_rfb._tcp`. A Mac appears once per service name with
/// a flag for each.
@MainActor
@Observable
final class Discovery {
    static let shared = Discovery()

    struct Found: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var hostname: String?
        var ssh = false
        var screen = false
        var sshPort = 22
        var screenPort = 5900
    }

    private(set) var found: [Found] = []
    private(set) var isScanning = false
    private(set) var subnet: String?
    private(set) var permissionDenied = false

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var resolvers: [String: Resolver] = [:]

    func start() {
        guard browsers.isEmpty else { return }
        subnet = LocalNetwork.wifiSubnet()
        isScanning = true
        for type in ["_ssh._tcp", "_rfb._tcp"] {
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.update(type: type, results: results) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .waiting(let error) = state, case .dns(let code) = error,
                       code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        self?.permissionDenied = true
                    }
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolvers.removeAll()
        isScanning = false
    }

    func restart() {
        stop()
        found.removeAll()
        start()
    }

    func isOnline(_ mac: Mac) -> Bool {
        found.contains { f in
            f.name.caseInsensitiveCompare(mac.name) == .orderedSame
                || (f.hostname.map { $0.caseInsensitiveCompare(mac.shortHost) == .orderedSame } ?? false)
        }
    }

    private func update(type: String, results: Set<NWBrowser.Result>) {
        let isSSH = type == "_ssh._tcp"
        var names = Set<String>()
        for result in results {
            guard case .service(let name, _, let domain, _) = result.endpoint else { continue }
            names.insert(name)
            if let index = found.firstIndex(where: { $0.name == name }) {
                if isSSH { found[index].ssh = true } else { found[index].screen = true }
            } else {
                var f = Found(name: name)
                if isSSH { f.ssh = true } else { f.screen = true }
                found.append(f)
            }
            resolve(name: name, type: type, domain: domain)
        }
        // Drop services that disappeared.
        for index in found.indices.reversed() where !names.contains(found[index].name) {
            if isSSH { found[index].ssh = false } else { found[index].screen = false }
            if !found[index].ssh && !found[index].screen { found.remove(at: index) }
        }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func resolve(name: String, type: String, domain: String) {
        let key = name + type
        guard resolvers[key] == nil else { return }
        resolvers[key] = Resolver(name: name, type: type, domain: domain) { [weak self] host, port in
            guard let self, let index = self.found.firstIndex(where: { $0.name == name }) else { return }
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            self.found[index].hostname = trimmed.lowercased()
            if type == "_ssh._tcp" { self.found[index].sshPort = port } else { self.found[index].screenPort = port }
        }
    }
}

/// Resolves a Bonjour service to its hostname ("Studio.local.") with
/// DNSServiceResolve.
private final class Resolver {
    private var ref: DNSServiceRef?
    private let onResolve: @MainActor (String, Int) -> Void

    init(name: String, type: String, domain: String, onResolve: @escaping @MainActor (String, Int) -> Void) {
        self.onResolve = onResolve
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = DNSServiceResolve(&ref, 0, 0, name, type, domain, { _, _, _, error, _, hosttarget, port, _, _, context in
            guard error == kDNSServiceErr_NoError, let hosttarget, let context else { return }
            let resolver = Unmanaged<Resolver>.fromOpaque(context).takeUnretainedValue()
            let host = String(cString: hosttarget)
            let p = Int(UInt16(bigEndian: port))
            MainActor.assumeIsolated { resolver.onResolve(host, p) }
        }, context)
        if status == kDNSServiceErr_NoError, let ref {
            DNSServiceSetDispatchQueue(ref, .main)
        }
    }

    deinit {
        if let ref { DNSServiceRefDeallocate(ref) }
    }
}

/// Wake-on-LAN, best effort.
///
/// Sends the magic packet to the Mac's last known address (unicast, which
/// iOS permits) and to the subnet broadcast address (which iOS only
/// delivers for apps with the multicast entitlement). Then pokes the SSH
/// port, because a Mac with "Wake for network access" on is usually woken by
/// the Bonjour Sleep Proxy (an Apple TV or HomePod) when something connects.
enum WakeOnLAN {
    static func wake(_ mac: Mac) async {
        if let hw = mac.macAddress, let packet = magicPacket(hw) {
            var targets: [String] = []
            if let last = mac.lastAddress { targets.append(last) }
            if let subnet = LocalNetwork.wifiSubnet(), let broadcast = broadcastAddress(subnet) {
                targets.append(broadcast)
            }
            for target in targets {
                for port in [9, 7] { send(packet, to: target, port: port) }
            }
        }
        // Sleep-proxy wake: an SSH connection attempt.
        _ = try? await LANGuard.resolve(mac.host, port: mac.sshPort)
        let connection = NWConnection(host: NWEndpoint.Host(mac.lastAddress ?? mac.host),
                                      port: NWEndpoint.Port(rawValue: UInt16(mac.sshPort)) ?? 22,
                                      using: .tcp)
        connection.start(queue: .global())
        try? await Task.sleep(for: .seconds(4))
        connection.cancel()
    }

    private static func magicPacket(_ hardware: String) -> Data? {
        let bytes = hardware.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    private static func send(_ packet: Data, to host: String, port: Int) {
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .udp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: .global())
    }

    private static func broadcastAddress(_ cidr: String) -> String? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { return nil }
        let ip = octets[0] << 24 | octets[1] << 16 | octets[2] << 8 | octets[3]
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        let b = ip | ~mask
        return "\(b >> 24).\((b >> 16) & 0xFF).\((b >> 8) & 0xFF).\(b & 0xFF)"
    }
}
