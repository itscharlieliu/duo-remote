import SwiftUI
import Observation

/// App-wide settings (the Settings screen). Backed by UserDefaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    enum ScreenInput: String, CaseIterable, Identifiable {
        case trackpad, directTouch
        var id: String { rawValue }
        var label: String { self == .trackpad ? "Trackpad" : "Direct touch" }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case adaptive, high, low
        var id: String { rawValue }
        var label: String {
            switch self {
            case .adaptive: "Adaptive"
            case .high: "High"
            case .low: "Low"
            }
        }
    }

    private let defaults = UserDefaults.standard

    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var optionAsMeta: Bool { didSet { defaults.set(optionAsMeta, forKey: "optionAsMeta") } }
    var keyHaptics: Bool { didSet { defaults.set(keyHaptics, forKey: "keyHaptics") } }
    var screenInput: ScreenInput { didSet { defaults.set(screenInput.rawValue, forKey: "screenInput") } }
    var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    var keepMacAwake: Bool { didSet { defaults.set(keepMacAwake, forKey: "keepMacAwake") } }

    private init() {
        defaults.register(defaults: [
            "fontSize": 13.0,
            "optionAsMeta": true,
            "keyHaptics": true,
            "screenInput": ScreenInput.trackpad.rawValue,
            "quality": Quality.adaptive.rawValue,
            "keepMacAwake": false,
        ])
        fontSize = defaults.double(forKey: "fontSize")
        optionAsMeta = defaults.bool(forKey: "optionAsMeta")
        keyHaptics = defaults.bool(forKey: "keyHaptics")
        screenInput = ScreenInput(rawValue: defaults.string(forKey: "screenInput") ?? "") ?? .trackpad
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .adaptive
        keepMacAwake = defaults.bool(forKey: "keepMacAwake")
    }
}
