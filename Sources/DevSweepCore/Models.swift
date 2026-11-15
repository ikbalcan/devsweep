import Foundation

/// How safe an item is to remove. Drives default selection and the removal mode.
public enum Tier: String, Codable, CaseIterable, Sendable, Comparable {
    /// Regenerated automatically by the next build or install. Never holds user data.
    case rebuilds
    /// No data loss, but has to be downloaded again if it is needed later.
    case redownload
    /// May contain the user's own state (app data, snapshots, dSYMs, local installs).
    case hasData

    public var title: String {
        switch self {
        case .rebuilds: return "Rebuilds"
        case .redownload: return "Re-download"
        case .hasData: return "Has data"
        }
    }

    public var explanation: String {
        switch self {
        case .rebuilds: return "Comes back on the next build or install. No data loss."
        case .redownload: return "No data loss, but needs internet if you use it again."
        case .hasData: return "May contain your data. Review one by one."
        }
    }

    private var order: Int {
        switch self {
        case .rebuilds: return 0
        case .redownload: return 1
        case .hasData: return 2
        }
    }

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.order < rhs.order }
}

public enum Ecosystem: String, Codable, CaseIterable, Sendable, Identifiable {
    case projects, xcode, simulators, android, gradle, packages, aiTools, docker, largeFiles

    public var id: String { rawValue }

    /// The areas of developer data DevSweep understands. Large files are the user's own files and live apart.
    public static var developerAreas: [Ecosystem] { allCases.filter { $0 != .largeFiles } }

    public var title: String {
        switch self {
        case .projects: return "Projects"
        case .xcode: return "Xcode"
        case .simulators: return "Simulators"
        case .android: return "Android SDK & Emulators"
        case .gradle: return "Gradle"
        case .packages: return "Package caches"
        case .aiTools: return "AI tools & editors"
        case .docker: return "Docker"
        case .largeFiles: return "Large files"
        }
    }

    /// SF Symbol name used in the app.
    public var symbol: String {
        switch self {
        case .projects: return "folder"
        case .xcode: return "hammer"
        case .simulators: return "iphone"
        case .android: return "smartphone"
        case .gradle: return "shippingbox"
        case .packages: return "archivebox"
        case .aiTools: return "sparkles"
        case .docker: return "cube"
        case .largeFiles: return "doc.text.magnifyingglass"
        }
    }
}

/// What actually happens when an item is cleaned.
public enum CleanAction: Codable, Sendable, Hashable {
    /// Remove `Item.paths` (deleted or moved to Trash depending on the chosen mode).
    case removePaths
    /// Run an official tool, e.g. `xcrun simctl delete <udid>`. The first element is the executable path.
    case command([String])
}

public struct Item: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let recipeID: String
    public let ecosystem: Ecosystem
    public let tier: Tier
    public let name: String
    public let detail: String
    public let paths: [URL]
    public var size: Int64
    public let action: CleanAction
    /// Plain-language description of what is lost if this item is removed.
    public let lossNote: String
    /// Non-nil when the item must not be cleaned right now; the string says why.
    public var protection: String?
    public var lastUsed: Date?

    public var isProtected: Bool { protection != nil }

    public init(recipeID: String, key: String, ecosystem: Ecosystem, tier: Tier, name: String, detail: String,
                paths: [URL], size: Int64, action: CleanAction = .removePaths, lossNote: String,
                protection: String? = nil, lastUsed: Date? = nil) {
        self.id = "\(recipeID):\(key)"
        self.recipeID = recipeID
        self.ecosystem = ecosystem
        self.tier = tier
        self.name = name
        self.detail = detail
        self.paths = paths
        self.size = size
        self.action = action
        self.lossNote = lossNote
        self.protection = protection
        self.lastUsed = lastUsed
    }

    /// Human-readable description of how the item is removed.
    public var howRemoved: String {
        switch action {
        case .removePaths:
            return paths.map { PathDisplay.tilde($0) }.joined(separator: "\n")
        case .command(let args):
            return args.map { ($0 as NSString).lastPathComponent == $0 ? $0 : ($0 as NSString).lastPathComponent }
                .joined(separator: " ")
        }
    }
}

public struct DiskInfo: Codable, Sendable {
    public let total: Int64
    /// Space available for important usage (what Finder reports, includes purgeable space).
    public let available: Int64

    public var usedFraction: Double { total > 0 ? Double(total - available) / Double(total) : 0 }

    public static func current(for url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> DiskInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        let values = try? url.resourceValues(forKeys: keys)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(values?.volumeAvailableCapacity ?? 0)
        return DiskInfo(total: total, available: important > 0 ? important : plain)
    }
}

public struct ScanResult: Codable, Sendable {
    public let items: [Item]
    public let disk: DiskInfo
    public let scannedAt: Date
    public let duration: TimeInterval

    public init(items: [Item], disk: DiskInfo, scannedAt: Date, duration: TimeInterval) {
        self.items = items
        self.disk = disk
        self.scannedAt = scannedAt
        self.duration = duration
    }

    /// Developer data only: the user's own large files never count towards the tier totals,
    /// the disk bar or "safe to free".
    public func total(tier: Tier) -> Int64 {
        items.filter { $0.tier == tier && $0.ecosystem != .largeFiles }.reduce(0) { $0 + $1.size }
    }
    public func total(ecosystem: Ecosystem) -> Int64 {
        items.filter { $0.ecosystem == ecosystem }.reduce(0) { $0 + $1.size }
    }
    public var total: Int64 { items.filter { $0.ecosystem != .largeFiles }.reduce(0) { $0 + $1.size } }

    /// The default safe selection: every unprotected Rebuilds item.
    public var safeSelection: [Item] { items.filter { $0.tier == .rebuilds && !$0.isProtected } }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB, .useKB]
        return f.string(fromByteCount: bytes)
    }
}

public enum PathDisplay {
    public static func tilde(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
