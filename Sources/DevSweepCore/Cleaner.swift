import Foundation

public enum RemovalMode: String, Codable, Sendable, CaseIterable {
    /// Free the space immediately.
    case delete
    /// Undoable, but space is only freed when the Trash is emptied.
    case trash
}

public enum SafetyViolation: Error, CustomStringConvertible, Equatable {
    case outsideAllowedRoots(String)
    case tooShallow(String)
    case criticalFolder(String)
    case insideGitMetadata(String)
    case unexpectedCommand(String)
    case protected(String)

    public var description: String {
        switch self {
        case .outsideAllowedRoots(let p): return "Refused: \(p) is outside the folders DevSweep may clean"
        case .tooShallow(let p): return "Refused: \(p) is too close to the top of your home folder"
        case .criticalFolder(let p): return "Refused: \(p) is a folder DevSweep never removes"
        case .insideGitMetadata(let p): return "Refused: \(p) is inside a .git folder"
        case .unexpectedCommand(let c): return "Refused: unexpected command \(c)"
        case .protected(let why): return "Skipped: \(why)"
        }
    }
}

/// Last line of defence: every path is checked here right before it is removed,
/// independent of which recipe produced it.
public enum PathSafety {
    /// Folders that are never removed themselves even though they are deep enough.
    static let critical: [String] = [
        "Library", "Library/Developer", "Library/Developer/Xcode", "Library/Developer/CoreSimulator",
        "Library/Developer/CoreSimulator/Devices", "Library/Android", "Library/Android/sdk", "Library/Caches",
        "Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Preferences",
        ".android", ".android/avd", ".gradle", ".gradle/wrapper", ".gradle/wrapper/dists", ".npm", ".cocoapods",
        ".pub-cache", ".m2", ".ssh", ".gnupg", ".config", ".bun", ".bun/install",
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Development", "Developer", "Projects",
    ]

    public static func check(_ url: URL, allowedRoots: [URL], home: URL) throws {
        let path = url.standardizedFileURL.path
        // Resolve symlinks in the parent only: removing a symlink itself is fine, following it is not.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = (parent as NSString).appendingPathComponent(url.lastPathComponent)

        if path.split(separator: "/").contains(".git") { throw SafetyViolation.insideGitMetadata(path) }

        let roots = allowedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard let root = roots.first(where: { resolved.hasPrefix($0 + "/") }) else {
            throw SafetyViolation.outsideAllowedRoots(path)
        }
        let depth = resolved.dropFirst(root.count + 1).split(separator: "/").count
        if depth < 2 { throw SafetyViolation.tooShallow(path) }

        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved.hasPrefix(homePath + "/") {
            let rel = String(resolved.dropFirst(homePath.count + 1))
            if critical.contains(rel) { throw SafetyViolation.criticalFolder(path) }
        }
        let sdkRoots = roots.filter { $0 != homePath }
        if sdkRoots.contains(resolved) { throw SafetyViolation.criticalFolder(path) }
    }
}

public struct CleanOutcome: Sendable {
    public let item: Item
    /// Bytes actually freed (0 when moved to Trash).
    public let freed: Int64
    public let movedToTrash: Int64
    public let error: String?

    public var succeeded: Bool { error == nil }
}

public struct Cleaner: Sendable {
    public let home: URL
    public let allowedRoots: [URL]
    static let allowedExecutables: Set<String> = ["/usr/bin/xcrun"]

    public init(options: ScanOptions = ScanOptions()) {
        self.home = options.home
        self.allowedRoots = [options.home, options.androidSDK]
    }

    public init(home: URL, allowedRoots: [URL]) {
        self.home = home
        self.allowedRoots = allowedRoots
    }

    /// Cleans the given items one by one. Protected items are skipped, and live conditions
    /// (running Gradle, emulators, npx tools) are checked again right before acting.
    public func clean(_ items: [Item], mode: (Tier) -> RemovalMode,
                      progress: ((Int, Item) -> Void)? = nil) -> [CleanOutcome] {
        let snapshot = SystemSnapshot.capture()
        var outcomes: [CleanOutcome] = []
        for (i, item) in items.enumerated() {
            progress?(i, item)
            if let why = item.protection ?? liveProtection(item, snapshot) {
                outcomes.append(CleanOutcome(item: item, freed: 0, movedToTrash: 0,
                                             error: SafetyViolation.protected(why).description))
                continue
            }
            outcomes.append(clean(item, mode: mode(item.tier)))
        }
        return outcomes
    }

    func liveProtection(_ item: Item, _ s: SystemSnapshot) -> String? {
        switch item.recipeID {
        case "gradle-caches":
            if s.gradleDaemonRunning { return "Gradle daemon started running" }
            if s.androidStudioRunning { return "Android Studio was opened" }
        case "android-avd":
            if s.runningAVDs.contains(where: { item.id.hasSuffix(":\($0)") }) { return "Emulator started running" }
        case "package-caches" where item.id.hasSuffix(":npx"):
            if s.anyRunning(containing: "/.npm/_npx/") { return "A running tool uses it" }
        default: break
        }
        return nil
    }

    private func clean(_ item: Item, mode: RemovalMode) -> CleanOutcome {
        switch item.action {
        case .command(let args):
            guard let exe = args.first, Self.allowedExecutables.contains(exe) else {
                return CleanOutcome(item: item, freed: 0, movedToTrash: 0,
                                    error: SafetyViolation.unexpectedCommand(args.joined(separator: " ")).description)
            }
            let r = Shell.run(exe, Array(args.dropFirst()), timeout: 600)
            return r.ok
                ? CleanOutcome(item: item, freed: item.size, movedToTrash: 0, error: nil)
                : CleanOutcome(item: item, freed: 0, movedToTrash: 0,
                               error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))

        case .removePaths:
            do {
                for p in item.paths { try PathSafety.check(p, allowedRoots: allowedRoots, home: home) }
            } catch {
                return CleanOutcome(item: item, freed: 0, movedToTrash: 0, error: "\(error)")
            }
            let fm = FileManager.default
            for p in item.paths {
                // A dangling symlink or an already-removed path is fine.
                guard (try? p.checkResourceIsReachable()) == true || fm.fileExists(atPath: p.path) else { continue }
                do {
                    if mode == .trash { try fm.trashItem(at: p, resultingItemURL: nil) }
                    else { try fm.removeItem(at: p) }
                } catch {
                    return CleanOutcome(item: item, freed: 0, movedToTrash: 0,
                                        error: "\(PathDisplay.tilde(p)): \(error.localizedDescription)")
                }
            }
            return mode == .trash
                ? CleanOutcome(item: item, freed: 0, movedToTrash: item.size, error: nil)
                : CleanOutcome(item: item, freed: item.size, movedToTrash: 0, error: nil)
        }
    }
}

public extension Tier {
    /// Rebuilds are deleted outright: moving them to the Trash would not free any space,
    /// and they regenerate anyway. Everything else goes to the Trash by default.
    var defaultRemovalMode: RemovalMode { self == .rebuilds ? .delete : .trash }
}
