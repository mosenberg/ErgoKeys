import AppKit
import Foundation

let agentLabel = "com.ergokeys.agent"

func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    let command = args.first ?? "help"
    switch command {
    case "run":
        runForeground()
    case "listen":
        listen()
    case "doctor":
        doctor()
    case "install":
        install()
    case "uninstall":
        uninstall()
    case "restart":
        restartAgent()
    case "edit":
        editConfig()
    case "selftest":
        let ok = selftest()
        exit(ok ? 0 : 1)
    case "help", "-h", "--help":
        printHelp()
    default:
        fputs("Unknown command: \(command)\n\n", stderr)
        printHelp()
        exit(1)
    }
}

func printHelp() {
    let text = """
    ErgoKeys assigns actions to the special keys of a Microsoft Natural Ergonomic Keyboard 4000.

    Commands:
      run         Perform the actions in the config
      listen      Print key names without performing actions
      doctor      Check the keyboard, permissions, and brightness
      install     Install the app and start it at login
      uninstall   Remove the login item
      restart     Restart the background app
      edit        Open the config in the default editor
      selftest    Check internal key recognition

    Config: \(ConfigStore.fileURL.path)
    """
    print(text)
}

func runForeground() {
    let engine = Engine(mode: .run)
    engine.start()
    installSignalStop()
    CFRunLoopRun()
}

func listen() {
    log("Listening. Press keys, Ctrl-C stops. Nothing is performed.")
    log("Use the printed name as a config key.")
    let engine = Engine(mode: .listen)
    engine.start()
    installSignalStop()
    CFRunLoopRun()
}

func doctor() {
    let keyboard = shellHIDPresent()
    print("Keyboard: \(keyboard ? "connected" : "not found")")
    print("Brightness: \(Actions.readBrightness())")
    print("Desktops: \(Actions.desktopSummary())")
    print("Accessibility: \(Actions.accessibilityTrusted() ? "allowed" : "missing (required so the arrow keys switch desktops)")")

    let engine = Engine(mode: .listen)
    engine.start()
    CFRunLoopRunInMode(.defaultMode, 0.6, false)
    if engine.hidOpen {
        print("Input Monitoring: allowed")
    } else {
        print("Input Monitoring: missing")
        print("  System Settings → Privacy & Security → Input Monitoring")
    }
    if engine.sawKeyboard {
        print("Special-key interface: visible")
    } else if engine.hidOpen {
        print("Special-key interface: not reported yet (plug in the keyboard)")
    }
    do {
        _ = try ConfigStore.ensureDefault()
        print("Config: \(ConfigStore.fileURL.path)")
    } catch {
        print("Config: \(error.localizedDescription)")
    }
}

func editConfig() {
    do {
        let url = try ConfigStore.ensureDefault()
        NSWorkspace.shared.open(url)
        print(url.path)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func install() {
    let app = installedAppURL()
    let executable = app.appendingPathComponent("Contents/MacOS/ergokeys")
    let source = executableURL()
    guard let icon = iconURL() else {
        fputs("App icon not found. Run scripts/make-icon.sh or pass --icon path/to/AppIcon.icns\n", stderr)
        exit(1)
    }
    do {
        try FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        _ = try ConfigStore.ensureDefault()
        try installApp(at: app, executableSource: source, icon: icon)
        // Earlier builds copied a bare binary here. The app bundle replaces it.
        let legacyBinary = ConfigStore.directory.appendingPathComponent("ergokeys")
        if FileManager.default.fileExists(atPath: legacyBinary.path) {
            try? FileManager.default.removeItem(at: legacyBinary)
        }
    } catch {
        fputs("Install failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ergokeys.log")
    try? FileManager.default.createDirectory(
        at: logURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(agentLabel)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(executable.path)</string>
        <string>run</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>ThrottleInterval</key>
      <integer>2</integer>
      <key>LimitLoadToSessionType</key>
      <string>Aqua</string>
      <key>ProcessType</key>
      <string>Interactive</string>
      <key>StandardOutPath</key>
      <string>\(logURL.path)</string>
      <key>StandardErrorPath</key>
      <string>\(logURL.path)</string>
    </dict>
    </plist>
    """
    do {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    } catch {
        fputs("Could not write the LaunchAgent: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let domain = "gui/\(getuid())"
    _ = runLaunchctl(["bootout", "\(domain)/\(agentLabel)"])
    // bootout and bootstrap back to back often returns EIO until launchd settles.
    var boot = runLaunchctl(["bootstrap", domain, plistURL.path])
    if boot != 0 {
        Thread.sleep(forTimeInterval: 0.8)
        boot = runLaunchctl(["bootstrap", domain, plistURL.path])
    }
    if boot != 0 {
        fputs("launchctl bootstrap failed (\(boot)).\n", stderr)
        exit(boot)
    }

    print("Installed: \(app.path)")
    print("Config: \(ConfigStore.fileURL.path)")
    print("Log: \(logURL.path)")
    print("")
    print("Allow ErgoKeys once in System Settings → Privacy & Security:")
    print("  Input Monitoring")
    print("  Accessibility")
    print("Then restart:")
    print("  \(executable.path) restart")
}

func uninstall() {
    let domain = "gui/\(getuid())"
    _ = runLaunchctl(["bootout", "\(domain)/\(agentLabel)"])
    let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    try? FileManager.default.removeItem(at: plistURL)
    try? FileManager.default.removeItem(at: installedAppURL())
    try? FileManager.default.removeItem(at: ConfigStore.directory.appendingPathComponent("ergokeys"))
    print("Login item removed. The config remains at \(ConfigStore.fileURL.path)")
}

func restartAgent() {
    let status = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"])
    if status != 0 {
        fputs("Restart failed (\(status)). Is ErgoKeys installed?\n", stderr)
        exit(status)
    }
    print("Restarted.")
}

private func installedAppURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/ErgoKeys.app", isDirectory: true)
}

private func iconURL() -> URL? {
    let args = CommandLine.arguments
    if let flag = args.firstIndex(of: "--icon"), args.count > flag + 1 {
        return URL(fileURLWithPath: args[flag + 1])
    }
    let candidates = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets/AppIcon.icns"),
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns"),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
}

private func installApp(at app: URL, executableSource: URL, icon: URL) throws {
    let fileManager = FileManager.default
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    if fileManager.fileExists(atPath: app.path) {
        try fileManager.removeItem(at: app)
    }
    try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
    let executable = macOS.appendingPathComponent("ergokeys")
    try fileManager.copyItem(at: executableSource, to: executable)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try fileManager.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns"))
    try appInfoPlist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", app.path]
    try sign.run()
    sign.waitUntilExit()
    NSWorkspace.shared.setIcon(NSImage(contentsOf: icon), forFile: app.path, options: [])
}

private let appInfoPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ergokeys</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.ergokeys.app</string>
  <key>CFBundleName</key>
  <string>ErgoKeys</string>
  <key>CFBundleDisplayName</key>
  <string>ErgoKeys</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
"""

func selftest() -> Bool {
    var presses: [String] = []
    var releases: [String] = []
    let tracker = KeyTracker()
    tracker.onPress = { presses.append($0) }
    tracker.onRelease = { releases.append($0) }

    tracker.handle(page: 0x0C, usage: 0x0192, value: 1)
    tracker.handle(page: 0x0C, usage: 0x0192, value: 1)
    tracker.handle(page: 0x0C, usage: 0x0192, value: 0)
    tracker.handle(page: 0xFF00, usage: 0xFF05, value: 0x01)
    tracker.handle(page: 0xFF00, usage: 0xFF05, value: 0x02)
    tracker.handle(page: 0xFF00, usage: 0xFF05, value: 0)
    tracker.handle(page: 0xFF00, usage: 0xFF02, value: 0x02)
    tracker.handle(page: 0x0C, usage: 0, value: 0x0224)
    tracker.handle(page: 0x0C, usage: 0x0224, value: 1)
    tracker.handle(page: 0xFF00, usage: 0xFE03, value: 1)
    tracker.handle(page: 0xFF00, usage: 0xFE03, value: 0)

    let expectedPresses = ["calculator", "favorite-1", "favorite-2", "back", "extra-1"]
    let expectedReleases = ["calculator", "favorite-1", "favorite-2", "extra-1"]
    if presses != expectedPresses || releases != expectedReleases {
        fputs("selftest failed\n  press \(presses)\n  release \(releases)\n", stderr)
        return false
    }
    print("selftest ok")
    return true
}

private func executableURL() -> URL {
    if let url = Bundle.main.executableURL {
        return url
    }
    return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

private func shellHIDPresent() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    task.arguments = ["-p", "IOUSB", "-n", "Natural® Ergonomic Keyboard 4000@00140000", "-r"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return !data.isEmpty && task.terminationStatus == 0
}

@discardableResult
private func runLaunchctl(_ arguments: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = arguments
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    } catch {
        return 1
    }
}

private func installSignalStop() {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    interrupt.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
    terminate.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
    interrupt.resume()
    terminate.resume()
}

main()
