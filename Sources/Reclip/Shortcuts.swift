import Foundation

/// Keyboard-shortcut model — a port of Recordly's `lib/shortcuts.ts`. Defines the
/// configurable actions, their bindings, conflict detection against fixed + configurable
/// shortcuts, event matching, and display formatting. Kept platform-agnostic (an abstract
/// `KeyChord` stands in for the OS key event) so it is pure and unit-tested; the AppKit
/// `NSEvent` bridge is a thin adapter in the UI layer.
enum ShortcutAction: String, CaseIterable {
    case addZoom, splitClip, addAnnotation, addKeyframe, deleteSelected, playPause
}

struct ShortcutBinding: Equatable {
    var key: String
    var ctrl: Bool = false        // maps to Cmd on macOS
    var shift: Bool = false
    var alt: Bool = false
}

/// An abstract key event: the pressed key plus modifier state. `primaryModifier` is Cmd on
/// macOS (Ctrl elsewhere) — the platform mapping is resolved before constructing this.
struct KeyChord: Equatable {
    var key: String
    var primaryModifier: Bool = false
    var shift: Bool = false
    var alt: Bool = false
}

enum ShortcutConflict: Equatable {
    case configurable(ShortcutAction)
    case fixed(String)
}

enum Shortcuts {
    static let defaults: [ShortcutAction: ShortcutBinding] = [
        .addZoom: ShortcutBinding(key: "z"),
        .splitClip: ShortcutBinding(key: "c"),
        .addAnnotation: ShortcutBinding(key: "a"),
        .addKeyframe: ShortcutBinding(key: "f"),
        .deleteSelected: ShortcutBinding(key: "d", ctrl: true),
        .playPause: ShortcutBinding(key: " "),
    ]

    /// Fixed (non-rebindable) shortcuts a configurable binding must not collide with.
    static let fixed: [(label: String, bindings: [ShortcutBinding])] = [
        ("Cycle Annotations Forward", [ShortcutBinding(key: "tab")]),
        ("Cycle Annotations Backward", [ShortcutBinding(key: "tab", shift: true)]),
        ("Delete Selected (alt)", [ShortcutBinding(key: "delete"), ShortcutBinding(key: "backspace")]),
    ]

    static func bindingsEqual(_ a: ShortcutBinding, _ b: ShortcutBinding) -> Bool {
        a.key.lowercased() == b.key.lowercased()
            && a.ctrl == b.ctrl && a.shift == b.shift && a.alt == b.alt
    }

    /// Whether a key event matches a binding (primary modifier ↔ binding.ctrl).
    static func matches(_ chord: KeyChord, _ binding: ShortcutBinding) -> Bool {
        chord.key.lowercased() == binding.key.lowercased()
            && chord.primaryModifier == binding.ctrl
            && chord.shift == binding.shift
            && chord.alt == binding.alt
    }

    /// The first conflict a proposed binding has with a fixed or another configurable
    /// shortcut (excluding `forAction` itself), or nil if it's free.
    static func findConflict(_ binding: ShortcutBinding, forAction: ShortcutAction,
                             config: [ShortcutAction: ShortcutBinding]) -> ShortcutConflict? {
        for f in fixed where f.bindings.contains(where: { bindingsEqual($0, binding) }) {
            return .fixed(f.label)
        }
        for action in ShortcutAction.allCases where action != forAction {
            if let b = config[action], bindingsEqual(b, binding) { return .configurable(action) }
        }
        return nil
    }

    /// Fills any actions missing from `partial` with their defaults.
    static func mergeWithDefaults(_ partial: [ShortcutAction: ShortcutBinding]) -> [ShortcutAction: ShortcutBinding] {
        var merged = defaults
        for (action, binding) in partial { merged[action] = binding }
        return merged
    }

    private static let keyLabels: [String: String] = [" ": "Space", "tab": "Tab",
                                                       "delete": "Del", "backspace": "⌫"]

    static func formatBinding(_ binding: ShortcutBinding, isMac: Bool) -> String {
        var parts: [String] = []
        if binding.ctrl { parts.append(isMac ? "⌘" : "Ctrl") }
        if binding.shift { parts.append(isMac ? "⇧" : "Shift") }
        if binding.alt { parts.append(isMac ? "⌥" : "Alt") }
        parts.append(keyLabels[binding.key.lowercased()] ?? binding.key.uppercased())
        return parts.joined(separator: " + ")
    }
}

/// Persists the user's shortcut bindings. `Shortcuts` itself stays pure (it is the model and
/// is unit-tested); storage is this thin adapter over `UserDefaults`.
enum ShortcutStore {
    private static let key = "reclip.shortcuts"

    static func load() -> [ShortcutAction: ShortcutBinding] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] else {
            return Shortcuts.defaults
        }
        var out: [ShortcutAction: ShortcutBinding] = [:]
        for (name, dict) in raw {
            guard let action = ShortcutAction(rawValue: name),
                  let k = dict["key"] as? String else { continue }
            out[action] = ShortcutBinding(key: k,
                                          ctrl: dict["ctrl"] as? Bool ?? false,
                                          shift: dict["shift"] as? Bool ?? false,
                                          alt: dict["alt"] as? Bool ?? false)
        }
        return Shortcuts.mergeWithDefaults(out)
    }

    static func save(_ config: [ShortcutAction: ShortcutBinding]) {
        var raw: [String: [String: Any]] = [:]
        for (action, b) in config {
            raw[action.rawValue] = ["key": b.key, "ctrl": b.ctrl, "shift": b.shift, "alt": b.alt]
        }
        UserDefaults.standard.set(raw, forKey: key)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}
