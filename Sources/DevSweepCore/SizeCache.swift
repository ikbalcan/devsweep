import Foundation

/// Remembers directory sizes between scans. A cached size is reused when the folder's own
/// modification date and those of its direct children are unchanged, and the measurement is
/// less than `maxAge` old. Deeper in-place edits can make a size lag by up to `maxAge`; that
/// only affects the number shown, never what is protected (protection is recomputed every scan).
///
/// Why: measuring is the slow part of a scan. On the author's Mac ~/.cocoapods/repos alone
/// (818k files) took 36 of a 42-second scan, and it changes only on `pod repo update`.
public final class SizeCache: @unchecked Sendable {
    struct Entry: Codable {
        var size: Int64
        var signature: UInt64
        var measuredAt: Date
    }

    public let url: URL
    public let maxAge: TimeInterval
    private var entries: [String: Entry]
    private var used = Set<String>()
    private let lock = NSLock()
    public private(set) var hits = 0
    public private(set) var misses = 0

    public static var defaultURL: URL { ScanCache.url.deletingLastPathComponent().appendingPathComponent("sizes.json") }

    public init(url: URL = SizeCache.defaultURL, maxAge: TimeInterval = 24 * 3600, load: Bool = true) {
        self.url = url
        self.maxAge = maxAge
        if load, let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            entries = (try? dec.decode([String: Entry].self, from: data)) ?? [:]
        } else {
            entries = [:]
        }
    }

    /// The size of a directory, from the cache when still valid, else from `compute`.
    public func size(of dir: URL, now: Date = Date(), compute: () -> Int64) -> Int64 {
        let key = dir.standardizedFileURL.path
        guard let sig = Self.signature(dir) else { return compute() }
        lock.lock()
        let cached = entries[key]
        used.insert(key)
        lock.unlock()
        if let c = cached, c.signature == sig, now.timeIntervalSince(c.measuredAt) < maxAge {
            lock.lock(); hits += 1; lock.unlock()
            return c.size
        }
        let size = compute()
        lock.lock()
        entries[key] = Entry(size: size, signature: sig, measuredAt: now)
        misses += 1
        lock.unlock()
        return size
    }

    /// Writes the cache, dropping folders this scan did not look at (removed or no longer relevant).
    public func save() {
        lock.lock()
        let kept = entries.filter { used.contains($0.key) }
        lock.unlock()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(kept) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// FNV-1a over the folder's own mtime and each direct child's name, mtime and file size.
    static func signature(_ dir: URL) -> UInt64? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let own = try? dir.resourceValues(forKeys: Set(keys)), own.isDirectory == true,
              let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
        else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ s: String) {
            for b in s.utf8 { hash ^= UInt64(b); hash = hash &* 0x0000_0100_0000_01B3 }
        }
        mix(String(own.contentModificationDate?.timeIntervalSince1970 ?? 0))
        for c in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let v = try? c.resourceValues(forKeys: Set(keys))
            mix(c.lastPathComponent)
            mix(String(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            mix(String(v?.fileSize ?? 0))
        }
        return hash
    }
}
