import Foundation

/// Settings shared by the app, the CLI and the MCP server. They live in the app's defaults
/// domain so a change in the app's settings is seen by `devsweep mcp` too.
public enum SharedSettings {
    public static let suite = "dev.devsweep.app"

    static var defaults: UserDefaults {
        // Inside the app this domain *is* the standard one (asking for it by suite name returns nil).
        if Bundle.main.bundleIdentifier == suite { return .standard }
        return UserDefaults(suiteName: suite) ?? .standard
    }

    /// Item IDs the user chose to always keep. Scans mark them protected.
    public static var keepList: Set<String> {
        get { Set(defaults.stringArray(forKey: "keepList") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "keepList") }
    }

    /// Whether AI agents may clean (Rebuilds only) through the MCP server.
    public static var allowAgentClean: Bool {
        get { defaults.object(forKey: "allowAgentClean") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "allowAgentClean") }
    }
}

/// The last scan on disk, so the app opens with results instantly and agents can answer
/// "how full is the disk" without a 45-second scan.
public enum ScanCache {
    public static var url: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("dev.devsweep/last-scan.json")
    }

    public static func save(_ result: ScanResult, to url: URL = url) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(result) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL = url) -> ScanResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ScanResult.self, from: data)
    }
}

/// Append-only log of every clean: who started it, what was removed, what it freed.
public enum CleanHistory {
    public struct Entry: Codable, Sendable, Identifiable {
        public var id: Date { date }
        public let date: Date
        /// "app", "menu bar", "notification", "cli", "mcp", or "rule: <name>".
        public let source: String
        public let freed: Int64
        public let trashed: Int64
        public let items: [String]
        public let failures: Int
    }

    public static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("DevSweep/history.jsonl")
    }

    @discardableResult
    public static func record(_ outcomes: [CleanOutcome], source: String, to url: URL = url) -> Entry? {
        guard !outcomes.isEmpty else { return nil }
        let ok = outcomes.filter(\.succeeded)
        let entry = Entry(date: Date(), source: source, freed: ok.reduce(0) { $0 + $1.freed },
                          trashed: ok.reduce(0) { $0 + $1.movedToTrash }, items: ok.map(\.item.name),
                          failures: outcomes.count - ok.count)
        append(entry, to: url)
        return entry
    }

    public static func append(_ entry: Entry, to url: URL = url) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// Most recent first.
    public static func load(limit: Int = 50, from url: URL = url) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).reversed()
            .compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
    }
}
