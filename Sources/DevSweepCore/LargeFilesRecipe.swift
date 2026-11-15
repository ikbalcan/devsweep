import CoreServices
import Foundation

/// What kind of big file this is, for grouping in the app.
public enum LargeFileKind: String, CaseIterable, Sendable, Identifiable {
    case diskImage, archive, video, document, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .diskImage: return "Installers & disk images"
        case .archive: return "Archives"
        case .video: return "Video & audio"
        case .document: return "Documents"
        case .other: return "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .diskImage: return "opticaldiscdrive"
        case .archive: return "doc.zipper"
        case .video: return "film"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }

    static let extensions: [LargeFileKind: Set<String>] = [
        .diskImage: ["dmg", "iso", "pkg", "img", "sparseimage", "xip", "ipsw", "vmdk", "vdi", "qcow2"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "aar"],
        .video: ["mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "mpg", "mpeg", "mts", "m2ts", "prores",
                 "wav", "aif", "aiff", "flac", "mp3", "m4a"],
        .document: ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "csv", "txt", "rtf", "epub", "psd", "ai",
                    "indd", "sketch", "fig", "key", "pages", "numbers", "json", "sql"],
    ]

    public static func kind(of url: URL) -> LargeFileKind {
        let ext = url.pathExtension.lowercased()
        return extensions.first { $0.value.contains(ext) }?.key ?? .other
    }
}

/// The user's own big files (installers, archives, videos, documents) outside the developer
/// folders the other recipes know. Nothing here regenerates, so every item is "Has data":
/// never selected for the user, never part of a safe clean, a rule, the menu bar or an agent,
/// and always moved to the Trash, never deleted outright.
struct LargeFilesRecipe: Recipe {
    static let recipeID = "large-files"
    let id = LargeFilesRecipe.recipeID

    /// Files smaller than this are never listed. The app can filter higher without a rescan.
    static let minBytes: Int64 = 100 * 1_048_576
    static let maxItems = 300

    /// Folders searched directly when Spotlight has nothing (indexing off, or an unindexed volume).
    static let fallbackFolders = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"]

    /// A folder with one of these extensions is one document to the user. Nothing inside is listed.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "framework", "bundle",
        "pvm", "vmwarevm", "utm", "sparsebundle", "xcarchive", "xcodeproj", "xcworkspace", "playground",
        "rtfd", "pages", "numbers", "key", "logicx", "band", "photolibrary",
    ]
    /// Folders owned by other tools, or covered by the developer recipes.
    static let skippedFolders: Set<String> = ["node_modules", "Pods", "DerivedData", "build", "Carthage", "venv",
                                              "iTunes Media"]
    /// Sync folders: removing a file there removes it on every other device too.
    static let syncFolders: Set<String> = ["Dropbox", "Google Drive", "Box", "pCloud Drive", "MEGA", "Sync",
                                           "Creative Cloud Files"]
    /// Unfinished downloads and scratch files.
    static let skippedExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]

    func discover(_ ctx: ScanContext) async -> [Item] {
        var candidates = Self.spotlight(home: ctx.home)
        if candidates.isEmpty { candidates = Self.walk(home: ctx.home) }
        var gitCache: [String: Bool] = [:]
        var found: [(URL, Int64)] = []
        for url in candidates {
            guard Self.eligible(url, home: ctx.home, gitCache: &gitCache),
                  let size = Self.size(of: url), size >= Self.minBytes else { continue }
            found.append((url, size))
        }
        found.sort { $0.1 > $1.1 }
        return found.prefix(Self.maxItems).map { item($0.0, $0.1, ctx) }
    }

    private func item(_ url: URL, _ size: Int64, _ ctx: ScanContext) -> Item {
        let kind = LargeFileKind.kind(of: url)
        let protection = ctx.snapshot.anyRunning(containing: url.path) ? "A running process uses this file" : nil
        return Item(recipeID: id, key: url.standardizedFileURL.path, ecosystem: .largeFiles, tier: .hasData,
                    name: url.lastPathComponent,
                    detail: "\(kind.title) · \(PathDisplay.tilde(url.deletingLastPathComponent()))",
                    paths: [url], size: size,
                    lossNote: "The file itself. DevSweep cannot tell what is in it or whether you still need it. It is moved to the Trash, so you can put it back until you empty the Trash.",
                    protection: protection, lastUsed: Self.lastUsed(url))
    }

    // MARK: Finding candidates

    static func spotlight(home: URL) -> [URL] {
        let r = Shell.run("/usr/bin/mdfind", ["-onlyin", home.path,
                                              "kMDItemFSSize >= \(minBytes) && kMDItemContentType != 'public.folder'"],
                          timeout: 60)
        guard r.ok else { return [] }
        return r.stdout.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    static func walk(home: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for folder in fallbackFolders {
            let root = home.appendingPathComponent(folder)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                        errorHandler: { _, _ in true }) else { continue }
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
                      v.isRegularFile == true, Int64(v.totalFileAllocatedSize ?? 0) >= minBytes else { continue }
                out.append(f)
            }
        }
        return out
    }

    // MARK: Rules

    /// Whether this file may be listed at all. `gitCache` remembers which folders sit inside a git repository.
    static func eligible(_ url: URL, home: URL, gitCache: inout [String: Bool]) -> Bool {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return false }
        let parts = path.dropFirst(homePath.count + 1).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return false }  // PathSafety refuses files directly in the home folder
        // Hidden folders (including the Trash), ~/Library and ~/Applications are not "your files".
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if ["Library", "Applications"].contains(parts[0]) { return false }
        if syncFolders.contains(parts[0]) || parts[0].hasPrefix("OneDrive") || parts[0].hasPrefix("GoogleDrive") {
            return false
        }
        let folders = parts.dropLast()
        if folders.contains(where: { skippedFolders.contains($0) }) { return false }
        if folders.contains(where: { packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) { return false }
        if skippedExtensions.contains(url.pathExtension.lowercased()) { return false }
        return !insideGitRepo(url.deletingLastPathComponent(), home: home, cache: &gitCache)
    }

    /// Anything inside a git repository may be tracked work, and agent worktrees live in one.
    static func insideGitRepo(_ dir: URL, home: URL, cache: inout [String: Bool]) -> Bool {
        let homePath = home.standardizedFileURL.path
        var chain: [String] = []
        var current = dir.standardizedFileURL.path
        var result = false
        while current.hasPrefix(homePath + "/") {
            if let known = cache[current] { result = known; break }
            chain.append(current)
            if FileManager.default.fileExists(atPath: current + "/.git") { result = true; break }
            current = (current as NSString).deletingLastPathComponent
        }
        for c in chain { cache[c] = result }
        return result
    }

    static func size(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true,
              v.isSymbolicLink != true else { return nil }
        return Int64(v.totalFileAllocatedSize ?? 0)
    }

    static func lastUsed(_ url: URL) -> Date? {
        if let md = MDItemCreateWithURL(nil, url as CFURL),
           let d = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date { return d }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Why this file must not be removed right now, checked again by the Cleaner just before removal.
    static func problem(_ url: URL, home: URL, snapshot: SystemSnapshot) -> String? {
        var cache: [String: Bool] = [:]
        if size(of: url) == nil { return "It is no longer a regular file" }
        if insideGitRepo(url.deletingLastPathComponent(), home: home, cache: &cache) {
            return "It sits inside a git repository"
        }
        if snapshot.anyRunning(containing: url.path) { return "A running process uses this file" }
        return nil
    }
}
