import Foundation

/// Bonjour discovery for Macs on the local network.
///
/// macOS advertises Remote Login as `_ssh._tcp.` and Screen Sharing as
/// `_rfb._tcp.` (and `_ard._tcp.` for Remote Management). Found services are
/// only surfaced if they resolve to a LAN address — discovery never returns
/// a host the LAN check would refuse.
@MainActor
final class DiscoveryService: NSObject, ObservableObject {
    @Published var discovered: [DiscoveredHost] = []

    private var sshBrowser: NetServiceBrowser?
    private var rfbBrowser: NetServiceBrowser?
    private var resolving: [NetService] = []

    struct DiscoveredHost: Identifiable, Equatable {
        var id: String { name + "@" + host }
        let name: String
        let host: String
        let hasSSH: Bool
        let hasVNC: Bool
    }

    func start() {
        stop()
        sshBrowser = makeBrowser(service: "_ssh._tcp.")
        rfbBrowser = makeBrowser(service: "_rfb._tcp.")
    }

    func stop() {
        sshBrowser?.stop()
        rfbBrowser?.stop()
        sshBrowser = nil
        rfbBrowser = nil
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }

    private func makeBrowser(service: String) -> NetServiceBrowser {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: service, inDomain: "local.")
        return browser
    }

    private func merge(name: String, host: String, ssh: Bool, vnc: Bool) {
        if let index = discovered.firstIndex(where: { $0.host == host }) {
            let existing = discovered[index]
            discovered[index] = DiscoveredHost(
                name: existing.name, host: host,
                hasSSH: existing.hasSSH || ssh, hasVNC: existing.hasVNC || vnc)
        } else {
            discovered.append(DiscoveredHost(name: name, host: host, hasSSH: ssh, hasVNC: vnc))
        }
        discovered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension DiscoveryService: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            service.delegate = self
            resolving.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        // Entries stay until the next refresh; hosts rarely vanish mid-session,
        // and dropping a live entry on a transient browse event would be worse.
    }
}

extension DiscoveryService: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            defer { resolving.removeAll { $0 === sender } }
            // Prefer a hostname (.local) over a raw address: it survives DHCP changes.
            let host = sender.hostName ?? ""
            guard !host.isEmpty, LANValidation.isPrivateOrLocal(host) else { return }
            let isSSH = sender.type == "_ssh._tcp."
            merge(name: sender.name, host: host, ssh: isSSH, vnc: !isSSH)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in
            resolving.removeAll { $0 === sender }
        }
    }
}
