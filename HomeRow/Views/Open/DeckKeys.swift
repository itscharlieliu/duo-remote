import SwiftUI
import Observation

// MARK: - Key model

enum Modifier: Hashable, CaseIterable {
    case shift, control, option, command, fn
}

enum Arrow { case left, right, up, down }

enum DeckKeyKind: Hashable {
    case char(lower: Character, upper: Character)
    case space, returnKey, tab, delete, escape
    case modifier(Modifier)
    case capsLock
    case function(Int)
    case power
    case arrow(Arrow)
    case missionControl
    case toggleKeyboard
    case toggleTouch
}

struct DeckKey: Identifiable {
    let id = UUID()
    var kind: DeckKeyKind
    var width: CGFloat = 1
    /// Upper legend (symbol / shifted character), lower legend (word / char).
    var top: String?
    var bottom: String
    var align: Align = .center
    var fontSize: CGFloat = 13
    /// Half-height arrow keys sit at the bottom of the row.
    var half = false

    enum Align { case leading, trailing, center }

    var repeats: Bool {
        switch kind {
        case .delete, .arrow, .space: true
        case .char: true
        default: false
        }
    }
}

/// Which pressed key and with what modifiers. Handed to a `KeyTarget`.
struct KeyPress {
    var kind: DeckKeyKind
    var modifiers: Set<Modifier>
    var capsLock: Bool
}

@MainActor
protocol KeyTarget: AnyObject {
    func press(_ press: KeyPress)
}

// MARK: - Modifier state

/// Sticky modifiers, like Accessibility's Sticky Keys:
/// tap = applies to the next key; double-tap = locked until tapped again;
/// hold while pressing another key = a normal chord.
@MainActor
@Observable
final class ModifierState {
    private(set) var latched: Set<Modifier> = []
    private(set) var locked: Set<Modifier> = []
    var capsLock = false
    @ObservationIgnored private var held: Set<Modifier> = []
    @ObservationIgnored private var usedWhileHeld: Set<Modifier> = []
    @ObservationIgnored private var lastTap: [Modifier: Date] = [:]

    var active: Set<Modifier> { latched.union(locked).union(held) }

    func isActive(_ m: Modifier) -> Bool { active.contains(m) }
    func isLocked(_ m: Modifier) -> Bool { locked.contains(m) }

    func modifierDown(_ m: Modifier) {
        held.insert(m)
        usedWhileHeld.remove(m)
    }

    func modifierUp(_ m: Modifier) {
        held.remove(m)
        if usedWhileHeld.contains(m) {
            // Was a chord: don't leave it latched.
            latched.remove(m)
            return
        }
        let now = Date()
        if locked.contains(m) {
            locked.remove(m)
            latched.remove(m)
        } else if let last = lastTap[m], now.timeIntervalSince(last) < 0.35 {
            locked.insert(m)
            latched.remove(m)
        } else if latched.contains(m) {
            latched.remove(m)
        } else {
            latched.insert(m)
        }
        lastTap[m] = now
    }

    /// Snapshot for a key press, then consume one-shot modifiers.
    func consume() -> Set<Modifier> {
        let snapshot = active
        usedWhileHeld.formUnion(held)
        latched.removeAll()
        return snapshot
    }
}

// MARK: - Layouts

enum DeckLayout {
    private static func letters(_ s: String) -> [DeckKey] {
        s.map { DeckKey(kind: .char(lower: Character($0.lowercased()), upper: $0), bottom: String($0)) }
    }

    private static func pairs(_ p: [(String, String)]) -> [DeckKey] {
        p.map { DeckKey(kind: .char(lower: Character($0.1), upper: Character($0.0)), top: $0.0, bottom: $0.1, fontSize: 11) }
    }

    static func mod(_ m: Modifier, _ word: String, _ symbol: String, width: CGFloat = 1, align: DeckKey.Align = .leading) -> DeckKey {
        DeckKey(kind: .modifier(m), width: width, top: symbol, bottom: word, align: align, fontSize: 9)
    }

    /// The full MacBook layout from the design (rows 1–6).
    static let full: [[DeckKey]] = [
        [DeckKey(kind: .escape, width: 1.5, bottom: "esc", align: .leading, fontSize: 9)]
            + (1...12).map { DeckKey(kind: .function($0), bottom: "F\($0)", fontSize: 8.5) }
            + [DeckKey(kind: .power, width: 1.5, bottom: "⏻", fontSize: 10)],
        pairs([("~", "`"), ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"),
               ("&", "7"), ("*", "8"), ("(", "9"), (")", "0"), ("_", "-"), ("+", "=")])
            + [DeckKey(kind: .delete, width: 2, top: "⌫", bottom: "delete", align: .trailing, fontSize: 9)],
        [DeckKey(kind: .tab, width: 1.5, top: "⇥", bottom: "tab", align: .leading, fontSize: 9)]
            + letters("QWERTYUIOP")
            + pairs([("{", "["), ("}", "]"), ("|", "\\")]).enumerated().map { i, k in
                var k = k; if i == 2 { k.width = 1.5 }; return k
            },
        [DeckKey(kind: .capsLock, width: 1.75, bottom: "caps lock", align: .leading, fontSize: 8.5)]
            + letters("ASDFGHJKL")
            + pairs([(":", ";"), ("\"", "'")])
            + [DeckKey(kind: .returnKey, width: 2.25, top: "⏎", bottom: "return", align: .trailing, fontSize: 9)],
        [mod(.shift, "shift", "⇧", width: 2.25)]
            + letters("ZXCVBNM")
            + pairs([("<", ","), (">", "."), ("?", "/")])
            + [mod(.shift, "shift", "⇧", width: 2.75, align: .trailing)],
        [
            DeckKey(kind: .modifier(.fn), bottom: "fn", align: .leading, fontSize: 9),
            mod(.control, "control", "⌃"),
            mod(.option, "option", "⌥"),
            mod(.command, "command", "⌘", width: 1.5),
            DeckKey(kind: .space, width: 5, bottom: ""),
            mod(.command, "command", "⌘", width: 1.5, align: .trailing),
            mod(.option, "option", "⌥", align: .trailing),
            DeckKey(kind: .arrow(.left), bottom: "◀", fontSize: 8, half: true),
            // Up/down share one column; see `ArrowColumn`.
            DeckKey(kind: .arrow(.up), bottom: "▲", fontSize: 8, half: true),
            DeckKey(kind: .arrow(.right), bottom: "▶", fontSize: 8, half: true),
        ],
    ]

    /// The one-row strip for screen sessions.
    static func strip(flat: Bool) -> [DeckKey] {
        var keys = [
            DeckKey(kind: .escape, bottom: "esc", align: .leading, fontSize: 9.5),
            mod(.control, "control", "⌃"),
            mod(.option, "option", "⌥"),
            mod(.command, "command", "⌘", width: 1.25),
            mod(.shift, "shift", "⇧", width: 1.25),
            DeckKey(kind: .missionControl, top: "⊞", bottom: "F3", fontSize: 10),
            DeckKey(kind: .toggleKeyboard, width: 1.25, top: "⌨", bottom: "keyboard", align: .trailing, fontSize: 9.5),
        ]
        if flat {
            keys.append(DeckKey(kind: .toggleTouch, width: 1.6, bottom: "touch", align: .leading, fontSize: 9.5))
        }
        return keys
    }
}

// MARK: - Views

/// The full deck keyboard. Rows scale to the space below the crease.
struct DeckKeyboard: View {
    let target: KeyTarget
    @Bindable var modifiers: ModifierState
    var showFunctionRow = true

    var body: some View {
        GeometryReader { geo in
            let rows = showFunctionRow ? DeckLayout.full : Array(DeckLayout.full.dropFirst())
            let gap: CGFloat = 6
            let units = rows.enumerated().map { i, _ in (showFunctionRow && i == 0) ? 0.57 : 1.0 }
            let available = geo.size.height - gap * CGFloat(rows.count - 1)
            let unit = min(56, available / units.reduce(0, +))
            VStack(spacing: gap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let height = unit * units[index]
                    WeightedRow(spacing: gap) {
                        ForEach(rowItems(row), id: \.id) { item in
                            switch item {
                            case .key(let key):
                                KeyCap(key: key, height: key.half ? (height - 2) / 2 : height,
                                       scale: unit / 56, target: target, modifiers: modifiers)
                                    .layoutValue(key: KeyWeight.self, value: key.width)
                            case .arrowColumn:
                                VStack(spacing: 2) {
                                    KeyCap(key: DeckKey(kind: .arrow(.up), bottom: "▲", fontSize: 8),
                                           height: (height - 2) / 2, scale: unit / 56, target: target, modifiers: modifiers)
                                    KeyCap(key: DeckKey(kind: .arrow(.down), bottom: "▼", fontSize: 8),
                                           height: (height - 2) / 2, scale: unit / 56, target: target, modifiers: modifiers)
                                }
                                .frame(height: height)
                                .layoutValue(key: KeyWeight.self, value: 1)
                            }
                        }
                    }
                    .frame(height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private enum Item: Identifiable {
        case key(DeckKey)
        case arrowColumn(UUID)
        var id: UUID {
            switch self {
            case .key(let k): k.id
            case .arrowColumn(let id): id
            }
        }
    }

    private func rowItems(_ row: [DeckKey]) -> [Item] {
        row.map { key in
            if case .arrow(.up) = key.kind { return .arrowColumn(key.id) }
            return .key(key)
        }
    }
}

/// Lays keys out by relative width, like CSS `flex: w 1 0`, bottom-aligned
/// so the half-height arrow keys sit low like a MacBook's.
struct WeightedRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 300, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let weights = subviews.map { $0[KeyWeight.self] }
        let total = weights.reduce(0, +)
        let free = bounds.width - spacing * CGFloat(max(0, subviews.count - 1))
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = free * weights[index] / max(total, 0.001)
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: bounds.height))
            let height = min(size.height, bounds.height)
            subview.place(at: CGPoint(x: x, y: bounds.maxY - height),
                          proposal: ProposedViewSize(width: width, height: height))
            x += width + spacing
        }
    }
}

struct KeyWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// A single key. Fires on touch-down (like hardware), repeats when held.
struct KeyCap: View {
    let key: DeckKey
    var height: CGFloat
    var scale: CGFloat = 1
    let target: KeyTarget
    let modifiers: ModifierState
    var radius: CGFloat = 7
    var lit = false

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        let active = isActive
        ZStack(alignment: alignment) {
            KeycapBackground(radius: radius * max(0.75, scale), lit: lit || isLocked,
                             active: active, pressed: pressed)
            if hasLED {
                LED(on: ledOn, size: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 5).padding(.leading, 6)
            }
            legend
                .padding(.horizontal, 5 * scale + 1)
                .padding(.vertical, 5 * scale + 1)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { down() } }
                .onEnded { _ in up() }
        )
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(.isKeyboardKey)
        .accessibilityAction { down(); up() }
    }

    private var alignment: Alignment {
        switch key.align {
        case .leading: .bottomLeading
        case .trailing: .bottomTrailing
        case .center: .center
        }
    }

    @ViewBuilder
    private var legend: some View {
        let size = key.fontSize * max(0.8, min(1.3, 1.3 * scale))
        let isMod = if case .modifier = key.kind { true } else { false }
        VStack(alignment: key.align == .trailing ? .trailing : .leading, spacing: key.align == .center ? 3 : 0) {
            if let top = key.top {
                Text(top)
                    .font(.system(size: isMod ? 11 * max(0.8, scale * 1.2) : size * 0.8))
                    .opacity(0.8)
                if key.align != .center { Spacer(minLength: 0) }
            }
            Text(key.bottom).font(.system(size: size)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(Theme.keyLegend)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .multilineTextAlignment(key.align == .trailing ? .trailing : .leading)
    }

    private var hasLED: Bool {
        if case .capsLock = key.kind { return true }
        return false
    }

    private var ledOn: Bool { modifiers.capsLock }

    private var isActive: Bool {
        if case .modifier(let m) = key.kind { return modifiers.isActive(m) }
        return false
    }

    private var isLocked: Bool {
        if case .modifier(let m) = key.kind { return modifiers.isLocked(m) }
        return false
    }

    private func down() {
        pressed = true
        Haptics.tap()
        switch key.kind {
        case .modifier(let m):
            modifiers.modifierDown(m)
        case .capsLock:
            modifiers.capsLock.toggle()
            target.press(KeyPress(kind: .capsLock, modifiers: [], capsLock: modifiers.capsLock))
        default:
            fire()
            if key.repeats {
                repeatTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(420))
                    while !Task.isCancelled && pressed {
                        fire(consume: false)
                        try? await Task.sleep(for: .milliseconds(55))
                    }
                }
            }
        }
    }

    @State private var heldModifiers: Set<Modifier> = []

    private func fire(consume: Bool = true) {
        let mods = consume ? modifiers.consume() : heldModifiers
        if consume { heldModifiers = mods }
        target.press(KeyPress(kind: key.kind, modifiers: mods, capsLock: modifiers.capsLock))
    }

    private func up() {
        pressed = false
        repeatTask?.cancel()
        repeatTask = nil
        if case .modifier(let m) = key.kind { modifiers.modifierUp(m) }
    }

    private var accessibilityName: String {
        switch key.kind {
        case .char(let lower, _): String(lower)
        case .space: "space"
        case .returnKey: "return"
        case .tab: "tab"
        case .delete: "delete"
        case .escape: "escape"
        case .modifier(let m): "\(m)"
        case .capsLock: "caps lock"
        case .function(let n): "F\(n)"
        case .power: "lock screen"
        case .arrow(let a): "\(a) arrow"
        case .missionControl: "Mission Control"
        case .toggleKeyboard: "keyboard"
        case .toggleTouch: "direct touch"
        }
    }
}
