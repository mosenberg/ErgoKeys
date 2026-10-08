import Foundation

struct Binding: Decodable {
    var action: String
    var target: String?
    var delta: Double?
    var direction: String?
    var key: String?
    var modifiers: [String]?
    var command: String?
}

struct ConfigFile: Decodable {
    var bindings: [String: Binding]
}

enum ConfigStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ergokeys", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    static let defaultJSON = """
    {
      "bindings": {
        "calculator": { "action": "open", "target": "Calculator" },
        "favorite-1": { "action": "brightness", "delta": -0.0625 },
        "favorite-2": { "action": "brightness", "delta": 0.0625 },
        "favorite-3": { "action": "open", "target": "Terminal" },
        "favorite-4": { "action": "open", "target": "Google Chrome" },
        "favorite-5": { "action": "open", "target": "Notes" },
        "back": { "action": "desktop", "direction": "left" },
        "forward": { "action": "desktop", "direction": "right" },
        "home": { "action": "lock" },
        "mail": { "action": "open", "target": "Mail" }
      }
    }
    """

    static func ensureDefault() throws -> URL {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try defaultJSON.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func load() throws -> ConfigFile {
        let url = try ensureDefault()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(ConfigFile.self, from: data)
    }
}
