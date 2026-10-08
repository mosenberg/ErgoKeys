import Foundation
import IOKit
import IOKit.hid

enum RunMode {
    case run
    case listen
}

final class Engine {
    let mode: RunMode
    private var manager: IOHIDManager?
    private var config = ConfigFile(bindings: [:])
    private let tracker = KeyTracker()
    private var repeatTimers: [String: Timer] = [:]
    private var keyboardConnected = false
    private var openResult: IOReturn = kIOReturnNotOpen
    private var loggedPermission = false
    private var retrying = false
    private var configStamp: Date?

    init(mode: RunMode) {
        self.mode = mode
        tracker.onPress = { [weak self] name in self?.pressed(name) }
        tracker.onRelease = { [weak self] name in self?.released(name) }
    }

    func start() {
        if mode == .run {
            reloadConfig(logBindings: true)
            watchConfig()
            if configNeedsAccessibility() {
                Actions.promptForAccessibility()
            }
        }
        openHID()
        if mode == .run && openResult != kIOReturnSuccess {
            scheduleRetry()
        }
    }

    var hidOpen: Bool { openResult == kIOReturnSuccess }
    var sawKeyboard: Bool { keyboardConnected }

    func reloadConfig(logBindings: Bool) {
        do {
            config = try ConfigStore.load()
        } catch {
            log("Could not read config: \(error.localizedDescription)")
            return
        }
        for name in config.bindings.keys where !Keys.isPlausibleBindingName(name) {
            log("Unknown key name in config: \(name)")
        }
        if logBindings {
            log("Config: \(ConfigStore.fileURL.path)")
            let names = config.bindings.keys.sorted()
            if names.isEmpty {
                log("No keys are bound.")
            }
            for name in names {
                guard let binding = config.bindings[name] else { continue }
                log("  \(name) → \(Actions.describe(binding))")
            }
        }
    }

    private func configNeedsAccessibility() -> Bool {
        config.bindings.values.contains { $0.action == "desktop" || $0.action == "keystroke" }
    }

    private func openHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager

        let matches: [[String: Any]] = [0x00DB, 0x00DC].map { product in
            [
                kIOHIDVendorIDKey as String: 0x045E,
                kIOHIDProductIDKey as String: product,
                kIOHIDDeviceUsagePageKey as String: 0x0C,
                kIOHIDDeviceUsageKey as String: 0x01,
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, hidInputValue, context)
        if mode == .listen {
            IOHIDManagerRegisterInputReportCallback(manager, hidInputReport, context)
        }

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnSuccess {
            loggedPermission = false
            if mode == .run {
                log("Listening for special keys.")
            }
        } else if !loggedPermission {
            loggedPermission = true
            log("Input Monitoring permission is missing (error \(String(format: "0x%08x", openResult))).")
            log("System Settings → Privacy & Security → Input Monitoring: enable ErgoKeys.")
            log("Then restart: launchctl kickstart -k gui/\(getuid())/com.ergokeys.agent")
        }
    }

    private func scheduleRetry() {
        guard mode == .run, !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.retrying = false
            if self.openResult == kIOReturnSuccess { return }
            if let manager = self.manager {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                self.manager = nil
            }
            self.openHID()
            if self.openResult != kIOReturnSuccess {
                self.scheduleRetry()
            }
        }
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice) {
        keyboardConnected = true
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Natural Ergonomic Keyboard 4000"
        log("Keyboard connected: \(name)")
    }

    fileprivate func deviceRemoved() {
        keyboardConnected = false
        tracker.reset()
        log("Keyboard disconnected.")
    }

    fileprivate func handle(page: UInt32, usage: UInt32, value: Int) {
        tracker.handle(page: page, usage: usage, value: value)
    }

    fileprivate func logReport(_ bytes: [UInt8], reportID: UInt32) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        log("report id=\(reportID) \(hex)")
    }

    private func pressed(_ name: String) {
        if mode == .listen {
            log("↓ \(name)")
            return
        }
        guard let binding = config.bindings[name] else {
            if !Keys.quietWhenUnbound.contains(name) {
                log("\(name) is not bound")
            }
            return
        }
        log("\(name) → \(Actions.describe(binding))")
        Actions.perform(binding)
        guard binding.action == "brightness" else { return }
        let delay = Timer(timeInterval: 0.32, repeats: false) { [weak self] _ in
            guard let self else { return }
            let repeater = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
                self?.config.bindings[name].map { Actions.perform($0) }
            }
            RunLoop.main.add(repeater, forMode: .common)
            self.repeatTimers[name] = repeater
        }
        RunLoop.main.add(delay, forMode: .common)
        repeatTimers[name] = delay
    }

    private func released(_ name: String) {
        repeatTimers[name]?.invalidate()
        repeatTimers[name] = nil
        if mode == .listen {
            log("↑ \(name)")
        }
    }

    private func watchConfig() {
        configStamp = Self.modificationDate(of: ConfigStore.fileURL)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = Self.modificationDate(of: ConfigStore.fileURL)
            guard current != self.configStamp else { return }
            self.configStamp = current
            self.reloadConfig(logBindings: true)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

private func hidInputValue(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    let engine = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
    let element = IOHIDValueGetElement(value)
    engine.handle(
        page: IOHIDElementGetUsagePage(element),
        usage: IOHIDElementGetUsage(element),
        value: Int(IOHIDValueGetIntegerValue(value))
    )
}

private func hidInputReport(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ type: IOHIDReportType,
    _ reportID: UInt32,
    _ report: UnsafeMutablePointer<UInt8>,
    _ length: CFIndex
) {
    guard result == kIOReturnSuccess, let context, length > 0 else { return }
    let engine = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    engine.logReport(bytes, reportID: reportID)
}

private func hidDeviceMatched(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
}

private func hidDeviceRemoved(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue().deviceRemoved()
}
