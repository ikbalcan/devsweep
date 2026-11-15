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

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), activeProjectDays: Int = 7,
                archiveKeepDays: Int = 90, projectRoots: [URL]? = nil, projectSearchDepth: Int = 5) {
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
    ]
}

public struct Scanner: Sendable {
    public let options: ScanOptions
    public let recipes: [Recipe]

    public init(options: ScanOptions = ScanOptions(), recipes: [Recipe] = Recipes.all) {
        self.options = options
        self.recipes = recipes
    }

    public func scan() async -> ScanResult {
        let start = Date()
        let snapshot = SystemSnapshot.capture()
        let projects = ProjectFinder(options: options).find()
        let context = ScanContext(options: options, snapshot: snapshot, projects: projects, now: start)
        let items = await withTaskGroup(of: [Item].self) { group in
            for r in recipes { group.addTask { await r.discover(context) } }
            var all: [Item] = []
            for await batch in group { all += batch }
            return all
        }
        let sorted = items.filter { $0.size > 0 }.sorted { a, b in
            a.ecosystem.rawValue != b.ecosystem.rawValue ? a.ecosystem.rawValue < b.ecosystem.rawValue : a.size > b.size
        }
        return ScanResult(items: sorted, disk: DiskInfo.current(for: options.home), scannedAt: start,
                          duration: Date().timeIntervalSince(start))
    }
}
