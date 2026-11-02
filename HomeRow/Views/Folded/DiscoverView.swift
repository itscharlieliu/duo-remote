import SwiftUI

/// 01 Discover — Bonjour scan of the local network.
struct DiscoverView: View {
    @Environment(Discovery.self) private var discovery
    @Environment(MacStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LED(on: discovery.isScanning, size: 6)
                    Text(statusLine).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                ScreenTitle(text: "Macs nearby")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            ScrollView {
                Well(radius: 14, padding: 8) {
                    VStack(spacing: 8) {
                        if discovery.found.isEmpty {
                            emptyState
                        }
                        ForEach(discovery.found) { found in
                            row(found)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { discovery.restart() }

            HStack(spacing: 8) {
                NavigationLink(value: FoldedRoute.addByAddress) {
                    KeyLegend(bottom: "add by address")
                }
                .buttonStyle(KeyButtonStyle())
                NavigationLink(value: FoldedRoute.help) {
                    KeyLegend(top: "?", bottom: "help", alignment: .trailing)
                }
                .buttonStyle(KeyButtonStyle(corner: .bottomTrailing))
                .frame(width: 80)
            }
            .frame(height: 48)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private var statusLine: String {
        if discovery.permissionDenied { return "Local Network access is off for Home Row" }
        if let subnet = discovery.subnet { return "Scanning \(subnet)" }
        return "Scanning this network"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(discovery.permissionDenied ? "Allow Local Network" : "Looking for Macs…")
                .font(.system(size: 15, weight: .semibold))
            Text(discovery.permissionDenied
                 ? "Settings → Privacy & Security → Local Network → Home Row."
                 : "Macs show up here when Remote Login or Screen Sharing is on. Make sure you’re on the same Wi-Fi.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    @ViewBuilder
    private func row(_ found: Discovery.Found) -> some View {
        let saved = store.match(name: found.name, host: found.hostname)
        let target = PairTarget(
            name: found.name,
            host: found.hostname ?? "\(found.name.replacingOccurrences(of: " ", with: "-")).local",
            sshPort: found.sshPort, screenPort: found.screenPort,
            hasSSH: found.ssh, existing: saved?.id)
        NavigationLink(value: target) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(found.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle(found, saved: saved != nil))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    ServiceLED(on: found.ssh, label: "ssh")
                    ServiceLED(on: found.screen, label: "screen")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(KeycapBackground(radius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(found.ssh ? "Pair and verify the host key" : "Screen Sharing only")
    }

    private func subtitle(_ found: Discovery.Found, saved: Bool) -> String {
        if !found.ssh { return "Remote Login is off on this Mac" }
        let host = found.hostname ?? "resolving…"
        return saved ? "Saved · \(host)" : host
    }
}

struct ServiceLED: View {
    var on: Bool
    var label: String
    var body: some View {
        HStack(spacing: 4) {
            LED(on: on)
            Text(label)
        }
        .font(.system(size: 10))
        .foregroundStyle(on ? Theme.dimLegend : Theme.tertiary)
        .accessibilityLabel("\(label) \(on ? "on" : "off")")
    }
}

/// Typing a Mac's address by hand, for when Bonjour can't see it.
struct AddByAddressView: View {
    @Binding var path: NavigationPath
    @State private var name = ""
    @State private var host = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EscKey()
            ScreenTitle(text: "Add a Mac")
            Text("Use its .local name (System Settings → General → Sharing, under the computer name) or its IP address on this network.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            WellField(label: "Address", text: $host, placeholder: "studio.local", keyboard: .URL)
            WellField(label: "Name", text: $name, placeholder: "Studio")
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
            Spacer()
            HStack {
                Spacer()
                Button(action: next) {
                    KeyLegend(top: "⏎", bottom: "continue", alignment: .trailing)
                }
                .buttonStyle(KeyButtonStyle(lit: !host.isEmpty, corner: .bottomTrailing))
                .frame(width: 150, height: 56)
                .disabled(host.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func next() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if let failure = LANGuard.validateName(trimmed) {
            error = failure.errorDescription
            return
        }
        let display = name.isEmpty
            ? (trimmed.split(separator: ".").first.map { String($0).capitalized } ?? trimmed)
            : name
        path.append(PairTarget(name: display, host: trimmed))
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EscKey()
                ScreenTitle(text: "Set up a Mac")
                step("1", "Remote Login", "System Settings → General → Sharing → Remote Login. Turn it on for the terminal. Note which users are allowed.")
                step("2", "Screen Sharing", "In the same pane, turn on Screen Sharing. Home Row signs in with your macOS username and password.")
                step("3", "Same Wi-Fi", "Home Row only talks to Macs on your local network. Nothing goes through the internet or a cloud relay.")
                step("4", "Wake", "For waking a sleeping Mac, turn on System Settings → Energy → Wake for network access.")
                Text("If the Mac doesn’t show up, check Settings → Privacy & Security → Local Network → Home Row on this phone.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func step(_ n: String, _ title: String, _ body: String) -> some View {
        Well(radius: 12, padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(n).font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(body).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
