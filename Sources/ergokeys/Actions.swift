import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum Actions {
    private static let getBrightness: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32)? = load(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        "DisplayServicesGetBrightness"
    )
    private static let setBrightness: (@convention(c) (UInt32, Float) -> Int32)? = load(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        "DisplayServicesSetBrightness"
    )
    private static let lockScreenNow: (@convention(c) () -> Void)? = load(
        "/System/Library/PrivateFrameworks/login.framework/login",
        "SACLockScreenImmediate"
    )

    private static var warnedAccessibility = false
    private static var warnedBrightness = false

    static func describe(_ binding: Binding) -> String {
        switch binding.action {
        case "lock":
            return "Lock screen"
        case "brightness":
            let delta = binding.delta ?? 0
            let percent = Int((delta * 100).rounded())
            return percent >= 0 ? "Brightness +\(percent)%" : "Brightness \(percent)%"
        case "open":
            return "Open \(binding.target ?? "?")"
        case "desktop":
            return binding.direction == "right" ? "Next desktop" : "Previous desktop"
        case "keystroke":
            let mods = (binding.modifiers ?? []).joined(separator: "+")
            let key = binding.key ?? "?"
            return mods.isEmpty ? "Key \(key)" : "\(mods)+\(key)"
        case "shell":
            return "Command: \(binding.command ?? "?")"
        default:
            return binding.action
        }
    }

    static func perform(_ binding: Binding) {
        switch binding.action {
        case "lock":
            lock()
        case "brightness":
            adjustBrightness(by: binding.delta ?? 0.0625)
        case "open":
            guard let target = binding.target else {
                log("open is missing target")
                return
            }
            openTarget(target)
        case "desktop":
            switchDesktop(right: binding.direction == "right")
        case "keystroke":
            guard let name = binding.key, let code = keyCode(named: name) else {
                log("keystroke: unknown key \(binding.key ?? "(empty)")")
                return
            }
            postKey(code, modifiers: modifierFlags(binding.modifiers ?? []))
        case "shell":
            guard let command = binding.command, !command.isEmpty else {
                log("shell is missing command")
                return
            }
            runShell(command)
        default:
            log("Unknown action \(binding.action)")
        }
    }

    static func readBrightness() -> String {
        let displays = onlineDisplays()
        guard !displays.isEmpty else { return "no display" }
        var parts: [String] = []
        for id in displays {
            guard let getBrightness else {
                return "DisplayServices missing"
            }
            var value: Float = -1
            let rc = getBrightness(id, &value)
            if rc == 0 {
                parts.append(String(format: "Display %u: %d%%", id, Int((value * 100).rounded())))
            }
        }
        return parts.isEmpty ? "unreadable" : parts.joined(separator: ", ")
    }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Switches the visible desktop with the system shortcut Control+Arrow.
    /// The private space API only moves the frontmost window on this macOS.
    private static func switchDesktop(right: Bool) {
        let key: CGKeyCode = right ? 124 : 123
        postKey(key, modifiers: .maskControl)
    }

    static func desktopSummary() -> String {
        let layouts = desktopLayouts()
        guard let layout = layouts.first else { return "unreadable" }
        let position = (layout.ordered.firstIndex(of: layout.current) ?? -1) + 1
        return "\(layout.ordered.count) desktops, current \(position)"
    }

    private struct DesktopLayout {
        var ordered: [UInt64]
        var current: UInt64
    }

    private static func desktopLayouts() -> [DesktopLayout] {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connectionSymbol = dlsym(handle, "SLSMainConnectionID"),
              let copySymbol = dlsym(handle, "SLSCopyManagedDisplaySpaces") else {
            return []
        }

        let connectionID = unsafeBitCast(connectionSymbol, to: (@convention(c) () -> Int32).self)()
        let copySpaces = unsafeBitCast(copySymbol, to: (@convention(c) (Int32) -> Unmanaged<CFArray>).self)
        let displays = copySpaces(connectionID).takeRetainedValue() as NSArray

        var layouts: [DesktopLayout] = []
        for case let display as NSDictionary in displays {
            guard let spaces = display["Spaces"] as? NSArray,
                  let current = display["Current Space"] as? NSDictionary,
                  let currentID = integer(current["id64"]) else { continue }

            var ordered: [UInt64] = []
            for case let space as NSDictionary in spaces {
                let uuid = space["uuid"] as? String ?? ""
                guard !uuid.isEmpty, let id = integer(space["id64"]) else { continue }
                ordered.append(id)
            }
            guard !ordered.isEmpty else { continue }
            layouts.append(DesktopLayout(ordered: ordered, current: currentID))
        }
        return layouts
    }

    private static func integer(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private static func lock() {
        if let lockScreenNow {
            lockScreenNow()
            return
        }
        // Ctrl-Command-Q, the system shortcut for locking the screen.
        postKey(12, modifiers: [.maskCommand, .maskControl])
    }

    private static func adjustBrightness(by delta: Double) {
        guard let getBrightness, let setBrightness else {
            if !warnedBrightness {
                warnedBrightness = true
                log("Cannot change brightness (DisplayServices is missing).")
            }
            return
        }
        var changed = false
        for id in onlineDisplays() {
            var current: Float = 0
            guard getBrightness(id, &current) == 0 else { continue }
            let next = min(1, max(0, current + Float(delta)))
            if setBrightness(id, next) == 0 {
                changed = true
            }
        }
        if !changed && !warnedBrightness {
            warnedBrightness = true
            log("Brightness could not be set on any display.")
        }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func openTarget(_ target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let url = URL(string: trimmed) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let url = resolveApp(trimmed) else {
            log("App not found: \(trimmed)")
            return
        }
        if url.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    log("Failed to launch \(trimmed): \(error.localizedDescription)")
                }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func resolveApp(_ name: String) -> URL? {
        let expanded = (name as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }

        let bundles = [
            "finder": "com.apple.finder",
            "safari": "com.apple.Safari",
            "mail": "com.apple.mail",
            "google chrome": "com.google.Chrome",
            "chrome": "com.google.Chrome",
            "terminal": "com.apple.Terminal",
            "notes": "com.apple.Notes",
            "calendar": "com.apple.iCal",
            "kalender": "com.apple.iCal",
            "system settings": "com.apple.systempreferences",
            "systemeinstellungen": "com.apple.systempreferences",
            "calculator": "com.apple.calculator",
            "rechner": "com.apple.calculator",
            "preview": "com.apple.Preview",
            "vorschau": "com.apple.Preview",
            "music": "com.apple.Music",
            "musik": "com.apple.Music",
            "textedit": "com.apple.TextEdit",
        ]
        if let bundleID = bundles[name.lowercased()],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        if name.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return url
        }

        let file = name.hasSuffix(".app") ? name : name + ".app"
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for root in roots {
            let path = (root as NSString).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func postKey(_ keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard ensureAccessibility() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        func tap(_ code: CGKeyCode, _ isDown: Bool, _ flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        // The space shortcut is Control+Arrow. The modifier has to be a real
        // key, otherwise Mission Control never sees the combination.
        if modifiers.contains(.maskControl) {
            tap(59, true, .maskControl)
        }
        tap(keyCode, true, modifiers)
        tap(keyCode, false, modifiers)
        if modifiers.contains(.maskControl) {
            tap(59, false, [])
        }
    }

    private static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !warnedAccessibility {
            warnedAccessibility = true
            promptForAccessibility()
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            log("Accessibility permission is missing. Enable ErgoKeys in the settings window, then press the arrow key again.")
        }
        return false
    }

    private static func modifierFlags(_ names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: log("Unknown modifier \(name)")
            }
        }
        return flags
    }

    private static func keyCode(named name: String) -> CGKeyCode? {
        let codes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        return codes[name.lowercased()]
    }

    private static func runShell(_ command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            try task.run()
        } catch {
            log("Command failed: \(error.localizedDescription)")
        }
    }

    private static func load<T>(_ path: String, _ symbol: String) -> T? {
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard let raw = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}

func log(_ message: String) {
    fputs("ergokeys: \(message)\n", stderr)
    fflush(stderr)
}
