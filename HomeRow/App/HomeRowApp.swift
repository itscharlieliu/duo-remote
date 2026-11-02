import SwiftUI

@main
struct HomeRowApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(MacStore.shared)
                .environment(Discovery.shared)
                .environment(Preferences.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.ledOn)
        }
        .onChange(of: phase) { _, phase in
            if phase == .active { Discovery.shared.start() } else if phase == .background { Discovery.shared.stop() }
        }
    }
}

/// Feeds hinge updates into the model. A zero-size UIKit view, because
/// `UIHingeInteraction` attaches to a view hierarchy.
struct HingeObserver: UIViewRepresentable {
    var onChange: (UIHinge.Status?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        let interaction = UIHingeInteraction { _, update in
            onChange(update.hinge?.status)
        }
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    /// The whole window, keyboard included. Posture must come from this, not
    /// from the safe-area size: a software keyboard in landscape shrinks the
    /// safe area below the inner-display threshold, which would flip the app
    /// to the folded layout, dismiss the keyboard, flip back, and loop.
    @State private var windowSize: CGSize = .zero

    var body: some View {
        @Bindable var model = model
        let posture = DebugPosture.forced ?? Posture.from(size: windowSize, hinge: model.hinge)
        Group {
            ZStack {
                Theme.background.ignoresSafeArea()
                switch posture {
                case .folded:
                    FoldedRoot()
                case .deck, .flat:
                    if model.hasSessions {
                        OpenWorkspace(posture: posture)
                    } else {
                        // Nothing open yet: the folded screens, centred on the
                        // inner display.
                        FoldedRoot()
                            .frame(maxWidth: 520)
                    }
                }
            }
            .environment(\.posture, posture)
            .animation(.snappy(duration: 0.25), value: posture)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { windowSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in windowSize = size }
            }
            .ignoresSafeArea()
        }
        .background(HingeObserver { status in model.hinge = status })
        .sheet(item: $model.prompter.current) { request in
            PasswordSheet(request: request)
                .presentationDetents([.height(300)])
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.banner)
        .onAppear {
            Discovery.shared.start()
            #if DEBUG
            DebugDemo.run(model)
            #endif
        }
    }
}

private struct PostureKey: EnvironmentKey {
    static let defaultValue: Posture = .folded
}

extension EnvironmentValues {
    var posture: Posture {
        get { self[PostureKey.self] }
        set { self[PostureKey.self] = newValue }
    }
}

struct BannerView: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .top, spacing: 10) {
                LED(on: true, size: 6, color: Theme.danger).padding(.top, 5)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(KeycapBackground(radius: 12, lit: true))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .task {
            try? await Task.sleep(for: .seconds(7))
            dismiss()
        }
    }
}

struct PasswordSheet: View {
    @Environment(AppModel.self) private var model
    let request: PasswordPrompter.Request
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            Text(request.message).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            WellField(label: "Password", text: $password, secure: true)
                .focused($focused)
                .onSubmit(submit)
            if request.offerRemember {
                HStack {
                    Text("Remember on this phone").font(.system(size: 14)).foregroundStyle(Theme.text)
                    Spacer()
                    CapsToggle(isOn: $remember, label: "Remember password")
                }
                .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { model.prompter.finish(nil, remember: false) } label: {
                    KeyLegend(top: nil, bottom: "esc")
                }
                .buttonStyle(KeyButtonStyle())
                .frame(width: 80, height: 48)
                Spacer()
                Button(action: submit) {
                    KeyLegend(top: "⏎", bottom: "sign in", alignment: .trailing)
                }
                .buttonStyle(KeyButtonStyle(lit: true, corner: .bottomTrailing))
                .frame(width: 150, height: 48)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .presentationBackground(Theme.background)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        model.prompter.finish(password, remember: remember)
    }
}

/// Debug builds can force a posture (HOMEROW_DEMO_POSTURE=deck|flat|folded)
/// so UI tests can reach the open-phone layouts without a hinge.
enum DebugPosture {
    static let forced: Posture? = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["HOMEROW_DEMO_POSTURE"] {
        case "deck": return .deck
        case "flat": return .flat
        case "folded": return .folded
        default: return nil
        }
        #else
        return nil
        #endif
    }()
}
