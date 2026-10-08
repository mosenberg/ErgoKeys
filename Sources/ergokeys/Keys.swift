import Foundation

/// Names the special keys of a Microsoft Natural Ergonomic Keyboard 4000.
///
/// Those keys are not keyboard scancodes. They arrive on the keyboard's second
/// USB interface (HID Consumer Control, usage page 0x0C) plus a vendor field
/// for the five My Favorites buttons.
enum Keys {
    static let consumerNames: [UInt32: String] = [
        0x0223: "home",
        0x0221: "search",
        0x018A: "mail",
        0x0192: "calculator",
        0x0224: "back",
        0x0225: "forward",
        0x022D: "zoom-in",
        0x022E: "zoom-out",
        0x0182: "star",
        0x00E2: "mute",
        0x00E9: "volume-up",
        0x00EA: "volume-down",
        0x00CD: "play",
        0x00B5: "scan-next",
        0x00B6: "scan-previous",
    ]

    /// Media keys macOS already handles. Unbound presses stay quiet.
    static let quietWhenUnbound: Set<String> = [
        "mute", "volume-up", "volume-down", "play", "scan-next", "scan-previous",
    ]

    static let knownNames: Set<String> = Set(consumerNames.values).union([
        "favorite-1", "favorite-2", "favorite-3", "favorite-4", "favorite-5",
        "extra-1", "extra-2",
    ])

    static func consumerName(_ usage: UInt32) -> String {
        if let name = consumerNames[usage] {
            return name
        }
        return String(format: "consumer-%04x", usage)
    }

    static func favoriteName(_ value: Int) -> String? {
        switch value {
        case 0x01: return "favorite-1"
        case 0x02: return "favorite-2"
        case 0x04: return "favorite-3"
        case 0x08: return "favorite-4"
        case 0x10: return "favorite-5"
        case 0: return nil
        default: return String(format: "favorite-raw-%02x", value)
        }
    }

    static func isPlausibleBindingName(_ name: String) -> Bool {
        if knownNames.contains(name) { return true }
        let prefixes = ["consumer-", "favorite-", "key-", "extra-"]
        return prefixes.contains { name.hasPrefix($0) }
    }
}

/// Tracks press and release edges for one consumer-control interface.
final class KeyTracker {
    private var down = Set<String>()
    private var favorite: String?

    var onPress: ((String) -> Void)?
    var onRelease: ((String) -> Void)?

    func handle(page: UInt32, usage: UInt32, value: Int) {
        // Modifier echo. Linux ignores this byte; it copies Shift/Ctrl state
        // and would otherwise look like a key of its own.
        if page == 0xFF00 && usage == 0xFF02 {
            return
        }

        if page == 0xFF00 && usage == 0xFF05 {
            let next = Keys.favoriteName(value)
            if next == favorite { return }
            if let previous = favorite {
                release(previous)
            }
            favorite = next
            if let next {
                press(next)
            }
            return
        }

        guard let name = name(page: page, usage: usage) else { return }
        if value != 0 {
            press(name)
        } else {
            release(name)
        }
    }

    func reset() {
        let released = down
        down.removeAll()
        favorite = nil
        for name in released {
            onRelease?(name)
        }
    }

    private func name(page: UInt32, usage: UInt32) -> String? {
        if usage == 0 { return nil }
        switch page {
        case 0x0C:
            // 0xFFFFFFFF is the empty slot of the consumer-control array, not a key.
            if usage == 0 || usage > 0x03FF { return nil }
            return Keys.consumerName(usage)
        case 0x07:
            return String(format: "key-%02x", usage)
        case 0xFF00:
            switch usage {
            case 0xFE03: return "extra-1"
            case 0xFE04: return "extra-2"
            default: return String(format: "vendor-%04x", usage)
            }
        default:
            return nil
        }
    }

    private func press(_ name: String) {
        guard down.insert(name).inserted else { return }
        onPress?(name)
    }

    private func release(_ name: String) {
        guard down.remove(name) != nil else { return }
        onRelease?(name)
    }
}
