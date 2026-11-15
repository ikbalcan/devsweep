import Foundation

public enum DiskLevel: Int, Comparable, Sendable {
    case ok, low, critical

    public static func < (lhs: DiskLevel, rhs: DiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Decides when free space is low and when to notify, without nagging:
/// one notification per step down (ok → low → critical), re-armed only after
/// free space climbs back above the warning threshold plus a margin.
public struct LowDiskPolicy: Sendable {
    public var warnBytes: Int64
    public var criticalBytes: Int64
    public var rearmMarginBytes: Int64

    public init(warnBytes: Int64 = 15_000_000_000, criticalBytes: Int64 = 5_000_000_000,
                rearmMarginBytes: Int64 = 2_000_000_000) {
        self.warnBytes = warnBytes
        self.criticalBytes = min(criticalBytes, warnBytes)
        self.rearmMarginBytes = rearmMarginBytes
    }

    public func level(_ available: Int64) -> DiskLevel {
        if available < criticalBytes { return .critical }
        if available < warnBytes { return .low }
        return .ok
    }

    /// - Returns: the level to notify about (nil for none) and the new "last notified" level to remember.
    public func evaluate(available: Int64, lastNotified: DiskLevel) -> (notify: DiskLevel?, lastNotified: DiskLevel) {
        let current = level(available)
        if current > lastNotified { return (current, current) }
        if available >= warnBytes + rearmMarginBytes { return (nil, .ok) }
        return (nil, lastNotified)
    }
}

public enum CompactBytes {
    /// "19 GB", "2.3 GB", "640 MB": short enough for the menu bar.
    public static func string(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
