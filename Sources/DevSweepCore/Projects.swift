import Foundation

public struct Project: Sendable {
    public let root: URL
    public var artifacts: [URL] = []
    public var markerFiles: [URL] = []
    public var kinds: [String] = []
    /// Gradle wrapper distributions this project uses, e.g. "gradle-8.9-bin".
    public var gradleWrapperDists: Set<String> = []
}

/// Walks the project roots and finds build artifacts that belong to real projects.
///
/// An artifact is only recorded when the marker that produces it sits next to it
/// (`node_modules` next to `package.json`, `build` next to `build.gradle` or `pubspec.yaml`, ...),
/// so a folder that merely happens to be called `build` is never picked up.
public struct ProjectFinder: Sendable {
    public let options: ScanOptions

    public init(options: ScanOptions) { self.options = options }

    static let markers: Set<String> = ["package.json", "pubspec.yaml", "build.gradle", "build.gradle.kts",
                                       "settings.gradle", "settings.gradle.kts", "Podfile", "Cargo.toml",
                                       "Package.swift", ".git"]

    /// Folders never descended into.
    static let skipNames: Set<String> = ["node_modules", "Pods", "build", "target", "DerivedData", "venv",
                                         "vendor", "dist", "Carthage", "bower_components", "site-packages"]
    static let skipAtHome: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public"]

    /// Rules: artifact folder name -> marker files, any of which must exist in the same folder.
    static let artifactRules: [(name: String, markers: [String], requires: String?)] = [
        ("node_modules", ["package.json"], nil),
        (".next", ["package.json"], nil),
        (".nuxt", ["package.json"], nil),
        (".turbo", ["package.json"], nil),
        (".parcel-cache", ["package.json"], nil),
        (".svelte-kit", ["package.json"], nil),
        (".dart_tool", ["pubspec.yaml"], nil),
        ("build", ["pubspec.yaml", "build.gradle", "build.gradle.kts"], nil),
        (".gradle", ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], nil),
        ("Pods", ["Podfile"], "Podfile.lock"),
        ("target", ["Cargo.toml"], "Cargo.lock"),
        (".build", ["Package.swift"], nil),
    ]

    public func find(progress: ((Int) -> Void)? = nil) -> [Project] {
        let acc = Accumulator()
        acc.progress = progress
        for root in options.projectRoots {
            walk(root, depth: 0, project: nil, acc: acc)
        }
        return acc.projects.filter { !$0.artifacts.isEmpty || !$0.gradleWrapperDists.isEmpty }
    }

    private final class Accumulator {
        var projects: [Project] = []
        var visited = 0
        var progress: ((Int) -> Void)?
    }

    private func walk(_ dir: URL, depth: Int, project: Int?, acc: Accumulator) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        acc.visited += 1
        if acc.visited % 250 == 0 { acc.progress?(acc.visited) }
        let names = Set(entries)
        let isHome = dir.standardizedFileURL.path == options.home.standardizedFileURL.path
        var current = project

        let hasMarker = !names.isDisjoint(with: Self.markers) && !isHome
        if hasMarker && current == nil {
            acc.projects.append(Project(root: dir))
            current = acc.projects.count - 1
        }

        if let idx = current, hasMarker {
            var p = acc.projects[idx]
            for marker in Self.markers where marker != ".git" && names.contains(marker) {
                p.markerFiles.append(dir.appendingPathComponent(marker))
            }
            for rule in Self.artifactRules where names.contains(rule.name) {
                guard rule.markers.contains(where: names.contains) else { continue }
                if let req = rule.requires, !names.contains(req) { continue }
                let url = dir.appendingPathComponent(rule.name)
                if isRealDirectory(url) && !isForbidden(url) { p.artifacts.append(url) }
            }
            for kind in kinds(for: names) where !p.kinds.contains(kind) { p.kinds.append(kind) }
            let props = dir.appendingPathComponent("gradle/wrapper/gradle-wrapper.properties")
            if let dist = Self.wrapperDist(from: props) { p.gradleWrapperDists.insert(dist) }
            acc.projects[idx] = p
        }

        guard depth < options.projectSearchDepth else { return }
        for name in entries.sorted() {
            if name.hasPrefix(".") || Self.skipNames.contains(name) || name.hasSuffix(".app") { continue }
            if isHome && Self.skipAtHome.contains(name) { continue }
            let child = dir.appendingPathComponent(name)
            guard isRealDirectory(child) else { continue }
            walk(child, depth: depth + 1, project: current, acc: acc)
        }
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }

    /// Never treat the global Gradle home or anything directly in $HOME as a project artifact.
    private func isForbidden(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == options.home.standardizedFileURL.path
    }

    private func kinds(for names: Set<String>) -> [String] {
        var k: [String] = []
        if names.contains("pubspec.yaml") { k.append("Flutter") }
        if names.contains("build.gradle") || names.contains("build.gradle.kts") { k.append("Android/Gradle") }
        if names.contains("package.json") {
            k.append(names.contains("next.config.js") || names.contains("next.config.mjs") || names.contains("next.config.ts")
                     ? "Next.js" : "Node")
        }
        if names.contains("Podfile") { k.append("CocoaPods") }
        if names.contains("Cargo.toml") { k.append("Rust") }
        if names.contains("Package.swift") { k.append("Swift") }
        return k
    }

    static func wrapperDist(from properties: URL) -> String? {
        guard let text = try? String(contentsOf: properties, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("distributionUrl") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: eq)...].replacingOccurrences(of: "\\:", with: ":")
            let file = (value.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            return file.hasSuffix(".zip") ? String(file.dropLast(4)) : file
        }
        return nil
    }
}

struct ProjectArtifactsRecipe: Recipe {
    let id = "project-artifacts"

    func discover(_ ctx: ScanContext) async -> [Item] {
        await withTaskGroup(of: Item?.self) { group in
            for project in ctx.projects where !project.artifacts.isEmpty {
                group.addTask { item(for: project, ctx) }
            }
            var items: [Item] = []
            for await i in group { if let i { items.append(i) } }
            return items
        }
    }

    private func item(for project: Project, _ ctx: ScanContext) -> Item? {
        // Skip anything git actually tracks: then it is not a generated artifact.
        let artifacts = project.artifacts.filter { !isTrackedByGit($0) }
        guard !artifacts.isEmpty else { return nil }
        let activity = ProjectActivity.of(project.root, markerFiles: project.markerFiles)
        let size = FileSize.allocated(artifacts)
        var protection: String?
        if activity.hasUncommittedChanges {
            protection = "Active project: uncommitted changes"
        } else if activity.isActive(withinDays: ctx.options.activeProjectDays, now: ctx.now) {
            protection = "Active project: worked on \(RelativeDate.string(activity.lastActivity, now: ctx.now))"
        }
        let rel = artifacts.map { a -> String in
            let r = a.path.replacingOccurrences(of: project.root.path + "/", with: "")
            return r + "/"
        }
        let kind = project.kinds.isEmpty ? "" : project.kinds.joined(separator: ", ") + " · "
        return Item(recipeID: id, key: project.root.path, ecosystem: .projects, tier: .rebuilds,
                    name: project.root.lastPathComponent,
                    detail: PathDisplay.tilde(project.root) + " · " + kind + rel.joined(separator: " "),
                    paths: artifacts, size: size,
                    lossNote: "Rebuilt by the next build or install (npm install, flutter pub get, Gradle). Source code is never touched.",
                    protection: protection, lastUsed: activity.lastActivity)
    }

    private func isTrackedByGit(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().path
        let r = Shell.run("/usr/bin/git", ["-C", parent, "ls-files", "--", url.lastPathComponent], timeout: 30)
        return r.ok && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
