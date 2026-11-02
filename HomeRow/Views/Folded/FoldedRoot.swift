import SwiftUI

/// The outer display: Hosts / Discover / Settings, switched by three keys.
struct FoldedRoot: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Group {
                    switch model.foldedTab {
                    case .hosts: HostsView()
                    case .discover: DiscoverView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                TabKeys(selection: $model.foldedTab)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PairTarget.self) { target in
                PairView(target: target, path: $path)
            }
            .navigationDestination(for: FoldedRoute.self) { route in
                switch route {
                case .addByAddress: AddByAddressView(path: $path)
                case .help: HelpView()
                case .keys: KeysView()
                case .edit(let id): EditMacView(macID: id)
                }
            }
        }
        .fullScreenCover(isPresented: foldedSessionBinding) {
            FoldedSessionView()
        }
    }

    /// While folded, an open session covers the host list.
    private var foldedSessionBinding: Binding<Bool> {
        Binding(
            get: { model.showSessionWhileFolded && model.hasSessions && posture == .folded },
            set: { if !$0 { model.showSessionWhileFolded = false } })
    }

    @Environment(\.posture) private var posture
}

enum FoldedRoute: Hashable {
    case addByAddress, help, keys
    case edit(UUID)
}

/// What the Pair screen is pairing: a Bonjour discovery or a typed address.
struct PairTarget: Hashable {
    var name: String
    var host: String
    var sshPort = 22
    var screenPort = 5900
    var hasSSH = true
    var existing: UUID?
}

struct TabKeys: View {
    @Binding var selection: AppModel.FoldedTab

    var body: some View {
        HStack(spacing: 8) {
            key(.hosts, "hosts")
            key(.discover, "discover")
            key(.settings, "settings")
        }
        .frame(height: 44)
    }

    private func key(_ tab: AppModel.FoldedTab, _ title: String) -> some View {
        Button {
            selection = tab
            Haptics.tap()
        } label: {
            KeyLegend(bottom: title, led: selection == tab)
        }
        .buttonStyle(KeyButtonStyle(radius: 8, lit: selection == tab))
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}

/// The small "esc" key that backs out of a pushed screen.
struct EscKey: View {
    @Environment(\.dismiss) private var dismiss
    var action: (() -> Void)?

    var body: some View {
        Button { (action ?? { dismiss() })() } label: {
            Text("esc").font(.system(size: 11))
        }
        .buttonStyle(KeyButtonStyle(radius: 7))
        .frame(width: 52, height: 30)
        .accessibilityLabel("Back")
    }
}
