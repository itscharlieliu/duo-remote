import SwiftUI

/// Home Row's visual language, lifted from the design file: the whole app is
/// drawn as a MacBook deck. Buttons are keycaps (legend in a corner), toggles
/// are caps-lock keys with an LED, and grouped content sits in an inset "well".
enum Theme {
    // Surfaces
    static let backgroundTop = Color(hex: 0x38393C)
    static let backgroundBottom = Color(hex: 0x2B2C2F)
    static let well = Color(hex: 0x232427)
    static let deckWell = Color(hex: 0x1C1D1F)
    static let screenBlack = Color(hex: 0x141416)
    static let remoteBlack = Color(hex: 0x0E0E10)

    // Keycaps
    static let keyTop = Color(hex: 0x1F1F21)
    static let keyBottom = Color(hex: 0x151516)
    static let keyLitTop = Color(hex: 0x2A2A2D)
    static let keyLitBottom = Color(hex: 0x1D1D20)

    // Text
    static let text = Color(hex: 0xECECEE)
    static let keyLegend = Color(hex: 0xE4E4E7)
    static let secondary = Color(hex: 0xA3A4A9)
    static let tertiary = Color(hex: 0x8D8E93)
    static let dimLegend = Color(hex: 0xCFD0D4)
    static let terminalText = Color(hex: 0xD9DADE)
    static let prompt = Color(hex: 0x7FDC8F)

    // LEDs
    static let ledOn = Color(hex: 0x5DF07A)
    static let ledOff = Color(hex: 0x46483F)
    static let ledRing = Color(hex: 0x5DF07A).opacity(0.35)
    static let danger = Color(hex: 0xFF6B5E)

    static var background: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - LED

struct LED: View {
    var on: Bool
    var size: CGFloat = 5
    var color: Color = Theme.ledOn

    var body: some View {
        Circle()
            .fill(on ? color : Theme.ledOff)
            .frame(width: size, height: size)
            .shadow(color: on ? color : .clear, radius: on ? size * 0.6 : 0)
            .accessibilityHidden(true)
    }
}

// MARK: - Well (inset panel)

struct Well<Content: View>: View {
    var radius: CGFloat = 12
    var padding: CGFloat = 0
    var color: Color = Theme.well
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color)
                    .overlay(
                        // Inner top shadow sells the "pressed into the deck" look.
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Color.black.opacity(0.55), lineWidth: 1)
                            .blur(radius: 1.5)
                            .offset(y: 1)
                            .mask(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    )
                    .shadow(color: .white.opacity(0.06), radius: 0, y: 1)
            )
    }
}

// MARK: - Keycap

/// The chrome of a single key. Used both by `KeyButtonStyle` and by the deck
/// keyboard, which needs press feedback without SwiftUI `Button` overhead.
struct KeycapBackground: View {
    var radius: CGFloat = 9
    var lit = false
    var active = false
    var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(LinearGradient(
                colors: (lit || active)
                    ? [Theme.keyLitTop, Theme.keyLitBottom]
                    : [Theme.keyTop, Theme.keyBottom],
                startPoint: .top, endPoint: .bottom))
            .overlay(
                // Top bevel highlight.
                shape.inset(by: 0.5)
                    .stroke(LinearGradient(
                        colors: [.white.opacity(lit ? 0.10 : 0.08), .clear],
                        startPoint: .top, endPoint: .center), lineWidth: 1)
            )
            .overlay {
                if active { shape.stroke(Theme.ledRing, lineWidth: 1) }
            }
            .brightness(pressed ? 0.06 : 0)
            .shadow(color: .black, radius: 0, y: pressed ? 0 : 1)
            .shadow(color: .black.opacity(0.35), radius: pressed ? 1 : 3, y: pressed ? 1 : 3)
            .offset(y: pressed ? 1 : 0)
    }
}

/// A keycap-shaped button. Legends sit in a corner like a real key.
struct KeyButtonStyle: ButtonStyle {
    enum Corner { case bottomLeading, bottomTrailing, center }
    var radius: CGFloat = 9
    var lit = false
    var corner: Corner = .bottomLeading

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(lit ? Theme.keyLegend : Theme.dimLegend)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .background(KeycapBackground(radius: radius, lit: lit, pressed: configuration.isPressed))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }

    private var alignment: Alignment {
        switch corner {
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        case .center: .center
        }
    }
}

/// A key with a symbol on top and a word on the bottom ("⏎ / trust & connect").
struct KeyLegend: View {
    var top: String?
    var bottom: String
    var alignment: HorizontalAlignment = .leading
    var led: Bool?

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            if let led {
                LED(on: led, size: 6)
            } else if let top {
                Text(top).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            Text(bottom).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

/// A caps-lock key standing in for a toggle switch.
struct CapsToggle: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Button {
            isOn.toggle()
            Haptics.tap()
        } label: {
            LED(on: isOn)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(KeycapBackground(radius: 6, lit: isOn))
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 26)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Screen chrome

struct ScreenTitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .bold))
            .tracking(-0.5)
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11))
            .tracking(0.7)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row inside a settings well.
struct WellRow<Trailing: View>: View {
    var title: String
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.text)
            Spacer()
            trailing
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1) }
        }
    }
}

/// Text field styled to sit in a well, matching the "User · you" row.
struct WellField: View {
    var label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        Well(radius: 10) {
            HStack {
                Text(label).foregroundStyle(Theme.secondary)
                Group {
                    if secure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                            .keyboardType(keyboard)
                    }
                }
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.text)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .frame(height: 44)
        }
    }
}

enum Haptics {
    @MainActor static func tap() {
        guard Preferences.shared.keyHaptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    }

    @MainActor static func warn() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
