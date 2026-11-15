import Foundation

public struct ScanOptions: Sendable {
    public var home: URL
    /// Projects with commits or uncommitted changes within this window are never touched.
    public var activeProjectDays: Int
    /// Xcode archives newer than this are protected (dSYMs may still be needed).
    public var archiveKeepDays: Int
    /// Where to look for projects. Hidden folders, ~/Library and media folders are skipped.
    public var projectRoots: [URL]
    public var projectSearchDepth: Int
    /// Item IDs the user chose to always keep.
    public var keepList: Set<String>

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), activeProjectDays: Int = 7,
                archiveKeepDays: Int = 90, projectRoots: [URL]? = nil, projectSearchDepth: Int = 5,
                keepList: Set<String>? = nil) {
        self.keepList = keepList ?? SharedSettings.keepList
        self.home = home
        self.activeProjectDays = activeProjectDays
        self.archiveKeepDays = archiveKeepDays
        self.projectRoots = projectRoots ?? [home]
        self.projectSearchDepth = projectSearchDepth
    }

    public var androidSDK: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return home.appendingPathComponent("Library/Android/sdk")
    }
}

public struct ScanContext: Sendable {
    public let options: ScanOptions
    public let snapshot: SystemSnapshot
    public let projects: [Project]
    public let now: Date

    public var home: URL { options.home }
}

public extension Scanner {
    /// Recipes that read the discovered project list (and so wait for the project search).
    static let needsProjects: Set<String> = ["project-artifacts", "gradle-wrapper", "worktrees"]
}

public protocol Recipe: Sendable {
    var id: String { get }
    func discover(_ context: ScanContext) async -> [Item]
}

public enum Recipes {
    public static let all: [Recipe] = [
        ProjectArtifactsRecipe(),
        DerivedDataRecipe(),
        ArchivesRecipe(),
        DeviceSupportRecipe(),
        SimulatorDevicesRecipe(),
        SimulatorRuntimesRecipe(),
        AVDRecipe(),
        AndroidSDKRecipe(),
        GradleCachesRecipe(),
        GradleWrapperRecipe(),
        PackageCachesRecipe(),
        AIToolsRecipe(),
        WorktreesRecipe(),
        DockerRecipe(),
    ]
}

public enum ScanEvent: Sendable {
    /// All steps, in display order: "projects" (finding projects) then one per recipe.
    case started(steps: [String])
    case projectSearch(foldersVisited: Int)
    case stepFinished(id: String, items: Int, bytes: Int64)
}

public enum ScanSteps {
    public static let projectSearch = "projects"
    public static let titles: [String: String] = [
        projectSearch: "Finding projects",
        "project-artifacts": "Project build folders",
        "xcode-deriveddata": "DerivedData",
        "xcode-archives": "Archives",
        "xcode-devicesupport": "Device support",
        "simulator-devices": "Simulator devices",
        "simulator-runtimes": "Simulator runtimes",
        "android-avd": "Emulators",
        "android-sdk": "SDK packages",
        "gradle-caches": "Gradle caches",
        "gradle-wrapper": "Gradle distributions",
        "package-caches": "Package manager caches",
        "ai-tools": "AI tools & editors",
        "worktrees": "Agent worktrees",
        "docker": "Docker",
    ]
    public static func title(_ id: String) -> String { titles[id] ?? id }
}

public struct Scanner: Sendable {
    public let options: ScanOptions
    public let recipes: [Recipe]

    public init(options: ScanOptions = ScanOptions(), recipes: [Recipe] = Recipes.all) {
        self.options = options
        self.recipes = recipes
    }

    /// - Parameter reuseSizes: reuse sizes of unchanged folders from earlier scans (fast). Pass false for a full rescan.
    public func scan(reuseSizes: Bool = true, progress: (@Sendable (ScanEvent) -> Void)? = nil) async -> ScanResult {
        let start = Date()
        let sizeCache = SizeCache(load: reuseSizes)
        FileSize.cache = sizeCache
        defer {
            sizeCache.save()
            FileSize.cache = nil
        }
        progress?(.started(steps: [ScanSteps.projectSearch] + recipes.map(\.id)))
        let snapshot = SystemSnapshot.capture()

        // Recipes that do not need the project list start right away, in parallel with the project search.
        let independent = recipes.filter { !Self.needsProjects.contains($0.id) }
        let dependent = recipes.filter { Self.needsProjects.contains($0.id) }
        let options = self.options
        let items = await withTaskGroup(of: [Item].self) { group in
            let early = ScanContext(options: options, snapshot: snapshot, projects: [], now: start)
            for r in independent {
                group.addTask {
                    let found = await r.discover(early)
                    progress?(.stepFinished(id: r.id, items: found.count, bytes: found.reduce(0) { $0 + $1.size }))
                    return found
                }
            }
            group.addTask {
                let projects = ProjectFinder(options: options).find { visited in
                    progress?(.projectSearch(foldersVisited: visited))
                }
                progress?(.stepFinished(id: ScanSteps.projectSearch, items: projects.count, bytes: 0))
                let context = ScanContext(options: options, snapshot: snapshot, projects: projects, now: start)
                return await withTaskGroup(of: [Item].self) { inner in
                    for r in dependent {
                        inner.addTask {
                            let found = await r.discover(context)
                            progress?(.stepFinished(id: r.id, items: found.count, bytes: found.reduce(0) { $0 + $1.size }))
                            return found
                        }
                    }
                    var all: [Item] = []
                    for await batch in inner { all += batch }
                    return all
                }
            }
            var all: [Item] = []
            for await batch in group { all += batch }
            return all
        }
        let keep = options.keepList
        let marked = items.map { item -> Item in
            var i = item
            if keep.contains(i.id) && i.protection == nil { i.protection = "You chose to always keep this" }
            // Never offer what the Cleaner would refuse: run the same last-line safety check now.
            if i.protection == nil, case .removePaths = i.action, let why = Self.safetyProblem(i, options) {
                i.protection = why
            }
            return i
        }
        let sorted = marked.filter { $0.size > 0 }.sorted { a, b in
            a.ecosystem.rawValue != b.ecosystem.rawValue ? a.ecosystem.rawValue < b.ecosystem.rawValue : a.size > b.size
        }
        return ScanResult(items: sorted, disk: DiskInfo.current(for: options.home), scannedAt: start,
                          duration: Date().timeIntervalSince(start))
    }

    /// The reason PathSafety would refuse one of the item's paths, if any.
    static func safetyProblem(_ item: Item, _ options: ScanOptions) -> String? {
        for p in item.paths {
            do { try PathSafety.check(p, allowedRoots: [options.home, options.androidSDK], home: options.home) }
            catch { return "\(error)" }
        }
        return nil
    }
}
