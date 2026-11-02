import SwiftUI
import LocalAuthentication

/// 04 Settings — toggles are caps-lock keys.
struct SettingsView: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(spacing: 0) {
            ScreenTitle(text: "Settings")
                .padding(.horizontal, 20)
                .padding(.top, 10)
            ScrollView {
                VStack(spacing: 6) {
                    SectionLabel(text: "Terminal")
                    Well {
                        VStack(spacing: 0) {
                            WellRow(title: "Font") {
                                Stepper(value: $prefs.fontSize, in: 9...22, step: 1) {
                                    Text("SF Mono · \(Int(prefs.fontSize))").foregroundStyle(Theme.secondary)
                                }
                                .fixedSize()
                            }
                            WellRow(title: "Option as Meta") {
                                CapsToggle(isOn: $prefs.optionAsMeta, label: "Option as Meta")
                            }
                            WellRow(title: "Key click haptics", divider: false) {
                                CapsToggle(isOn: $prefs.keyHaptics, label: "Key click haptics")
                            }
                        }
                    }

                    SectionLabel(text: "Screen").padding(.top, 8)
                    Well {
                        VStack(spacing: 0) {
                            WellRow(title: "Default input") {
                                Menu {
                                    Picker("Default input", selection: $prefs.screenInput) {
                                        ForEach(Preferences.ScreenInput.allCases) { Text($0.label).tag($0) }
                                    }
                                } label: {
                                    Text(prefs.screenInput.label).foregroundStyle(Theme.secondary)
                                }
                            }
                            WellRow(title: "Quality") {
                                Menu {
                                    Picker("Quality", selection: $prefs.quality) {
                                        ForEach(Preferences.Quality.allCases) { Text($0.label).tag($0) }
                                    }
                                } label: {
                                    Text(prefs.quality.label).foregroundStyle(Theme.secondary)
                                }
                            }
                            WellRow(title: "Keep Mac awake", divider: false) {
                                CapsToggle(isOn: $prefs.keepMacAwake, label: "Keep Mac awake")
                            }
                        }
                    }
                    Text(prefs.keepMacAwake
                         ? "Runs caffeinate on the Mac over SSH while you share its screen."
                         : "Adaptive drops to 16-bit colour when the Wi-Fi can’t keep up.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)

                    SectionLabel(text: "Security").padding(.top, 8)
                    Well {
                        NavigationLink(value: FoldedRoute.keys) {
                            WellRow(title: "SSH keys", divider: false) {
                                Text(SSHIdentity.exists ? "1 key ›" : "none ›").foregroundStyle(Theme.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The phone's SSH identity: show, copy, regenerate.
struct KeysView: View {
    @State private var line = SSHIdentity.publicKeyLine
    @State private var confirmRegenerate = false
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EscKey()
                ScreenTitle(text: "SSH keys")
                if let line {
                    Well(radius: 12, padding: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ED25519 · \(SSHIdentity.name)")
                                .font(.system(size: 10)).tracking(0.6).foregroundStyle(Theme.tertiary)
                            Text(SSHIdentity.fingerprint ?? "")
                                .font(Theme.mono(12)).foregroundStyle(Color(hex: 0xD6D7DA))
                            Text(line)
                                .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                                .lineLimit(3).truncationMode(.middle)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(protectionNote)
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string = line
                            copied = true
                            Haptics.tap()
                        } label: {
                            KeyLegend(top: "⌘C", bottom: copied ? "copied" : "copy public key")
                        }
                        .buttonStyle(KeyButtonStyle(lit: true))
                        Button { confirmRegenerate = true } label: {
                            KeyLegend(top: "↻", bottom: "new key")
                        }
                        .buttonStyle(KeyButtonStyle())
                        .frame(width: 110)
                    }
                    .frame(height: 48)
                    Text("Pairing installs this key on the Mac for you. To add it by hand, append it to ~/.ssh/authorized_keys.")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 6)
                } else {
                    Text("No key yet. One is made the first time you pair a Mac with key sign-in, or make it now.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    Button { generate() } label: { KeyLegend(top: "+", bottom: "create key") }
                        .buttonStyle(KeyButtonStyle(lit: true))
                        .frame(width: 150, height: 48)
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Replace this phone’s SSH key?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Replace key", role: .destructive) { generate() }
        } message: {
            Text("Macs paired with the old key will ask for your password once to install the new one.")
        }
    }

    private var protectionNote: String {
        guard SSHIdentity.isBiometricallyProtected else {
            return "This phone has no passcode, so the key isn’t gated by Face ID or Touch ID. Set a passcode and make a new key."
        }
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let method = switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "your passcode"
        }
        return "Stored in this phone’s Keychain. Every use asks for \(method). It never leaves the device."
    }

    private func generate() {
        do {
            line = try SSHIdentity.generate()
            copied = false
        } catch {
            self.error = "Couldn’t create a key: \(error.localizedDescription)"
        }
    }
}
