import XCTest
@testable import DevSweepCore

final class PathSafetyTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/tester")

    func check(_ path: String) throws {
        try PathSafety.check(URL(fileURLWithPath: path), allowedRoots: [home], home: home)
    }

    func testAllowsDeepPathsInsideHome() throws {
        XCTAssertNoThrow(try check("/Users/tester/Development/app/node_modules"))
        XCTAssertNoThrow(try check("/Users/tester/.gradle/caches"))
        XCTAssertNoThrow(try check("/Users/tester/elci/node_modules"))
    }

    func testRefusesOutsideHome() {
        XCTAssertThrowsError(try check("/System/Library/Foo/Bar"))
        XCTAssertThrowsError(try check("/Users/other/project/node_modules"))
        XCTAssertThrowsError(try check("/Users/tester-evil/a/b"))
    }

    func testRefusesShallowAndCriticalFolders() {
        XCTAssertThrowsError(try check("/Users/tester/Documents"))
        XCTAssertThrowsError(try check("/Users/tester"))
        XCTAssertThrowsError(try check("/Users/tester/Library/Developer"))
        XCTAssertThrowsError(try check("/Users/tester/.android/avd"))
        XCTAssertThrowsError(try check("/Users/tester/Library/Android/sdk"))
    }

    func testRefusesGitMetadataAndTraversal() {
        XCTAssertThrowsError(try check("/Users/tester/app/.git/objects"))
        XCTAssertThrowsError(try check("/Users/tester/app/../../other/x"))
    }
}

final class LowDiskPolicyTests: XCTestCase {
    let gb: Int64 = 1_000_000_000
    lazy var policy = LowDiskPolicy(warnBytes: 15 * gb, criticalBytes: 5 * gb, rearmMarginBytes: 2 * gb)

    func testLevels() {
        XCTAssertEqual(policy.level(20 * gb), .ok)
        XCTAssertEqual(policy.level(10 * gb), .low)
        XCTAssertEqual(policy.level(2 * gb), .critical)
    }

    func testNotifiesOncePerStepDownAndRearmsWithMargin() {
        var last = DiskLevel.ok
        func step(_ free: Int64) -> DiskLevel? {
            let r = policy.evaluate(available: free * gb, lastNotified: last)
            last = r.lastNotified
            return r.notify
        }
        XCTAssertNil(step(30))
        XCTAssertEqual(step(14), .low)
        XCTAssertNil(step(13))            // still low: no repeat
        XCTAssertNil(step(16))            // above warn but inside the margin: not re-armed
        XCTAssertNil(step(14))
        XCTAssertEqual(step(4), .critical)
        XCTAssertNil(step(3))
        XCTAssertNil(step(12))            // recovered to low: no new low warning
        XCTAssertNil(step(18))            // re-armed
        XCTAssertEqual(step(14), .low)
    }

    func testCompactBytes() {
        XCTAssertEqual(CompactBytes.string(19_660_000_000), "20 GB")
        XCTAssertEqual(CompactBytes.string(2_300_000_000), "2.3 GB")
        XCTAssertEqual(CompactBytes.string(640_000_000), "640 MB")
    }
}

final class ParsingTests: XCTestCase {
    func testDerivedDataDisplayName() {
        XCTAssertEqual(DerivedDataRecipe.displayName("Runner-cvhfebcvlxujzzebrdqomjgnkbao"), "Runner")
        XCTAssertEqual(DerivedDataRecipe.displayName("ModuleCache.noindex"), "ModuleCache")
        XCTAssertEqual(DerivedDataRecipe.displayName("my-app"), "my-app")
    }

    func testRuntimeName() {
        XCTAssertEqual(SimulatorDevicesRecipe.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-2"), "iOS 26.2")
    }

    func testWrapperDist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("gradle-wrapper.properties")
        try "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.9-bin.zip\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectFinder.wrapperDist(from: f), "gradle-8.9-bin")
    }

    func testRunningAVDs() {
        let s = SystemSnapshot(commandLines: [
            "/Users/x/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Test_API_35 -netdelay none",
            "/Users/x/Library/Android/sdk/emulator/emulator @Pixel_8",
        ])
        XCTAssertEqual(s.runningAVDs, ["Test_API_35", "Pixel_8"])
    }
}

/// Builds a fake home folder with real files and runs the finder and cleaner against it.
final class SandboxHomeTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("devsweep-test-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    func make(_ rel: String, file: Bool = false, content: String = "x") throws {
        let url = home.appendingPathComponent(rel)
        if file {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func testFinderOnlyPicksArtifactsNextToTheirMarker() throws {
        try make("Dev/web/package.json", file: true)
        try make("Dev/web/node_modules/left-pad/index.js", file: true)
        try make("Dev/web/.next/cache/a", file: true)
        try make("Dev/flutter/pubspec.yaml", file: true)
        try make("Dev/flutter/build/app.apk", file: true)
        try make("Dev/flutter/.dart_tool/x", file: true)
        try make("Dev/flutter/android/build.gradle", file: true)
        try make("Dev/flutter/android/app/build.gradle", file: true)
        try make("Dev/flutter/android/app/build/out", file: true)
        // A folder called "build" with no marker next to it must be ignored.
        try make("Documents/notes/build/important.txt", file: true)
        // Pods without a lockfile are not reproducible, so they are ignored.
        try make("Dev/ios/Podfile", file: true)
        try make("Dev/ios/Pods/x", file: true)

        let projects = ProjectFinder(options: ScanOptions(home: home)).find()
        let artifacts = Set(projects.flatMap(\.artifacts).map { $0.path.replacingOccurrences(of: home.path + "/", with: "") })
        XCTAssertEqual(artifacts, ["Dev/web/node_modules", "Dev/web/.next", "Dev/flutter/build", "Dev/flutter/.dart_tool",
                                   "Dev/flutter/android/app/build"])
        // Nested Gradle modules are grouped under the outermost project.
        XCTAssertEqual(Set(projects.map { $0.root.lastPathComponent }), ["web", "flutter"])
    }

    func testCleanerDeletesSafeItemAndRefusesProtectedAndOutside() throws {
        try make("Dev/web/package.json", file: true)
        try make("Dev/web/node_modules/a/index.js", file: true, content: String(repeating: "x", count: 10_000))
        let nm = home.appendingPathComponent("Dev/web/node_modules")
        let cleaner = Cleaner(home: home, allowedRoots: [home])

        let ok = Item(recipeID: "test", key: "a", ecosystem: .projects, tier: .rebuilds, name: "web", detail: "",
                      paths: [nm], size: 10, lossNote: "")
        let protected = Item(recipeID: "test", key: "b", ecosystem: .projects, tier: .rebuilds, name: "p", detail: "",
                             paths: [home.appendingPathComponent("Dev/web/package.json")], size: 1, lossNote: "",
                             protection: "Active project")
        let outside = Item(recipeID: "test", key: "c", ecosystem: .projects, tier: .rebuilds, name: "o", detail: "",
                           paths: [URL(fileURLWithPath: "/tmp/devsweep-should-never/x")], size: 1, lossNote: "")
        let shallow = Item(recipeID: "test", key: "d", ecosystem: .projects, tier: .rebuilds, name: "s", detail: "",
                           paths: [home.appendingPathComponent("Dev")], size: 1, lossNote: "")

        let out = cleaner.clean([ok, protected, outside, shallow], mode: { $0.defaultRemovalMode })
        XCTAssertTrue(out[0].succeeded)
        XCTAssertFalse(fm.fileExists(atPath: nm.path))
        XCTAssertFalse(out[1].succeeded)
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("Dev/web/package.json").path))
        XCTAssertFalse(out[2].succeeded)
        XCTAssertFalse(out[3].succeeded)
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("Dev").path))
    }

    func testRefusesSymlinkedParentEscapingHome() throws {
        let outside = fm.temporaryDirectory.appendingPathComponent("devsweep-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try make("Dev")
        try fm.createSymbolicLink(at: home.appendingPathComponent("Dev/link"), withDestinationURL: outside)
        XCTAssertThrowsError(try PathSafety.check(home.appendingPathComponent("Dev/link/node_modules"),
                                                  allowedRoots: [home], home: home))
    }

    func testScannerNeverOffersWhatTheCleanerRefuses() throws {
        try make(".dartServer/.analysis-driver/x", file: true)
        func item(_ rel: String) -> Item {
            Item(recipeID: "package-caches", key: "t", ecosystem: .packages, tier: .rebuilds, name: "t", detail: "",
                 paths: [home.appendingPathComponent(rel)], size: 1, lossNote: "")
        }
        let opts = ScanOptions(home: home)
        XCTAssertNotNil(Scanner.safetyProblem(item(".dartServer"), opts))  // directly under home: refused
        XCTAssertNil(Scanner.safetyProblem(item(".dartServer/.analysis-driver"), opts))
        XCTAssertTrue(PackageCachesRecipe.caches.allSatisfy { $0.path.contains("/") },
                      "every cache path must be at least two levels deep, or the cleaner refuses it")
    }

    func testWorktreesAreFoundProtectedAndRemovedThroughGit() async throws {
        let repo = home.appendingPathComponent("Development/app")
        try make("Development/app/README.md", file: true)
        func git(_ args: String...) {
            let r = Shell.run("/usr/bin/git", ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args)
            XCTAssertTrue(r.ok, r.stderr)
        }
        git("init", "-q", "-b", "main"); git("add", "."); git("commit", "-qm", "init")
        git("worktree", "add", "-q", ".claude/worktrees/clean", "-b", "agent/clean")
        git("worktree", "add", "-q", ".claude/worktrees/dirty", "-b", "agent/dirty")
        try make("Development/app/.claude/worktrees/dirty/notes.txt", file: true)  // untracked work
        git("worktree", "add", "-q", "--detach", ".claude/worktrees/detached")
        let detached = repo.appendingPathComponent(".claude/worktrees/detached")
        _ = Shell.run("/usr/bin/git", ["-C", detached.path, "-c", "user.name=t", "-c", "user.email=t@t",
                                       "commit", "-q", "--allow-empty", "-m", "orphan work"])

        let later = Date().addingTimeInterval(30 * 86_400)  // as if nobody touched them for a month
        let ctx = ScanContext(options: ScanOptions(home: home), snapshot: SystemSnapshot(commandLines: []),
                              projects: [Project(root: repo)], now: later)
        let items = await WorktreesRecipe().discover(ctx)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.paths[0].lastPathComponent, $0) })
        XCTAssertEqual(Set(byName.keys), ["clean", "dirty", "detached"])
        XCTAssertNil(byName["clean"]?.protection)
        XCTAssertEqual(byName["clean"]?.detail.hasPrefix("Claude Code · branch agent/clean"), true)
        XCTAssertEqual(byName["dirty"]?.protection, "Has 1 uncommitted or untracked file")
        XCTAssertEqual(byName["detached"]?.protection, "Has commits that are on no branch")

        // Touched today: kept, an agent may still be working there.
        let today = ScanContext(options: ScanOptions(home: home), snapshot: SystemSnapshot(commandLines: []),
                                projects: [Project(root: repo)], now: Date())
        let fresh = await WorktreesRecipe().discover(today).first { $0.paths[0].lastPathComponent == "clean" }
        XCTAssertEqual(fresh?.protection?.contains("an agent may still be working here"), true)

        let cleaner = Cleaner(home: home, allowedRoots: [home])
        let outcomes = cleaner.clean(items, mode: { _ in .delete })
        XCTAssertEqual(outcomes.filter(\.succeeded).map { $0.item.paths[0].lastPathComponent }, ["clean"])
        XCTAssertFalse(fm.fileExists(atPath: repo.appendingPathComponent(".claude/worktrees/clean").path))
        XCTAssertTrue(fm.fileExists(atPath: repo.appendingPathComponent(".claude/worktrees/dirty/notes.txt").path))
        let branches = Shell.run("/usr/bin/git", ["-C", repo.path, "branch", "--list", "agent/clean"]).stdout
        XCTAssertTrue(branches.contains("agent/clean"), "the branch survives the worktree")

        // git is only allowed in one exact shape.
        XCTAssertThrowsError(try cleaner.checkWorktreeRemoval(["/usr/bin/git", "-C", repo.path, "worktree", "remove",
                                                                "--force", detached.path]))
        XCTAssertThrowsError(try cleaner.checkWorktreeRemoval(["/usr/bin/git", "-C", repo.path, "clean", "-fdx"]))
        XCTAssertThrowsError(try cleaner.checkWorktreeRemoval(["/usr/bin/git", "-C", repo.path, "worktree", "remove",
                                                                "/etc/somewhere"]))
    }

    func testAIToolsFindsCachesOrphansAndOllama() async throws {
        let support = "Library/Application Support/Cursor"
        try make("\(support)/Cache/data_0", file: true)
        try make("\(support)/User/globalStorage/state.vscdb", file: true)
        try make("\(support)/User/workspaceStorage/aaa/workspace.json", file: true,
                 content: #"{"folder":"file:///nonexistent/devsweep/project"}"#)
        try make("\(support)/User/workspaceStorage/bbb/workspace.json", file: true,
                 content: "{\"folder\":\"file://\(home.path)\"}")
        try make(".ollama/models/manifests/registry.ollama.ai/library/gemma4/latest", file: true,
                 content: #"{"layers":[{"size":100},{"size":23}]}"#)
        try make(".ollama/models/blobs/sha256-x", file: true)

        let ctx = ScanContext(options: ScanOptions(home: home), snapshot: SystemSnapshot(commandLines: []),
                              projects: [], now: Date())
        let items = await AIToolsRecipe().discover(ctx)
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(byKey["ai-tools:Cursor:caches"]?.tier, .rebuilds)
        XCTAssertEqual(byKey["ai-tools:Cursor:state-db"]?.tier, .hasData)
        let orphans = byKey["ai-tools:Cursor:workspaces-orphaned"]
        XCTAssertEqual(orphans?.paths.map(\.lastPathComponent), ["aaa"])
        XCTAssertNotNil(byKey["ai-tools:ollama-orphaned"])  // no ollama binary in the test home
        XCTAssertEqual(AIToolsRecipe.ollamaManifests(home.appendingPathComponent(".ollama/models/manifests")).first?.name,
                       "gemma4:latest")
        XCTAssertEqual(AIToolsRecipe.ollamaManifests(home.appendingPathComponent(".ollama/models/manifests")).first?.size, 123)

        // While the app runs, everything of it is protected.
        let running = ScanContext(options: ScanOptions(home: home),
                                  snapshot: SystemSnapshot(commandLines: ["/Applications/Cursor.app/Contents/MacOS/Cursor"]),
                                  projects: [], now: Date())
        let locked = await AIToolsRecipe().discover(running).filter { $0.id.hasPrefix("ai-tools:Cursor:") }
        XCTAssertTrue(locked.allSatisfy(\.isProtected))
    }

    func testRefusesWholeAppSupportFolder() {
        XCTAssertThrowsError(try PathSafety.check(home.appendingPathComponent("Library/Application Support/Cursor"),
                                                  allowedRoots: [home], home: home))
        XCTAssertNoThrow(try PathSafety.check(home.appendingPathComponent("Library/Application Support/Cursor/Cache"),
                                              allowedRoots: [home], home: home))
    }

    func testDefaultModes() {
        XCTAssertEqual(Tier.rebuilds.defaultRemovalMode, .delete)
        XCTAssertEqual(Tier.redownload.defaultRemovalMode, .trash)
        XCTAssertEqual(Tier.hasData.defaultRemovalMode, .trash)
    }
}

final class MCPServerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("devsweep-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func item(_ key: String, _ tier: Tier, protection: String? = nil) -> Item {
        Item(recipeID: "test", key: key, ecosystem: .projects, tier: tier, name: key, detail: "", paths: [],
             size: 1_000_000_000, lossNote: "rebuilt", protection: protection)
    }

    func server(allow: Bool = true, cleaned: @escaping ([Item]) -> Void = { _ in }) -> MCPServer {
        let result = ScanResult(items: [item("safe", .rebuilds), item("active", .rebuilds, protection: "Active project"),
                                        item("runtime", .redownload)],
                                disk: DiskInfo(total: 100, available: 10), scannedAt: Date(), duration: 1)
        return MCPServer(scan: { result },
                         clean: { items in
                             cleaned(items)
                             return items.map { CleanOutcome(item: $0, freed: $0.size, movedToTrash: 0, error: nil) }
                         },
                         cacheURL: dir.appendingPathComponent("scan.json"),
                         historyURL: dir.appendingPathComponent("history.jsonl"),
                         allowClean: { allow })
    }

    func json(_ s: String?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(s).utf8)) as? [String: Any])
    }

    func toolPayload(_ response: String?) throws -> (payload: [String: Any], isError: Bool) {
        let result = try XCTUnwrap(json(response)["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]),
                result["isError"] as? Bool ?? false)
    }

    func testInitializeListAndNotifications() async throws {
        let s = server()
        let initResp = try json(await s.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        XCTAssertEqual((initResp["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        let none = await s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(none)
        let list = try json(await s.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["disk_status", "plan_cleanup", "clean_safe"])
        let unknown = try json(await s.handle(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#))
        XCTAssertNotNil(unknown["error"])
    }

    func testCleanSafeOnlyRemovesUnprotectedRebuilds() async throws {
        var removed: [String] = []
        let s = server(cleaned: { removed = $0.map(\.name) })
        let r = try toolPayload(await s.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"clean_safe","arguments":{}}}"#))
        XCTAssertFalse(r.isError)
        XCTAssertEqual(removed, ["safe"])
        XCTAssertEqual(CleanHistory.load(from: dir.appendingPathComponent("history.jsonl")).first?.source, "mcp")
    }

    func testCleanSafeRespectsTheSwitchAndDryRun() async throws {
        var called = false
        let off = server(allow: false, cleaned: { _ in called = true })
        let r = try toolPayload(await off.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"clean_safe","arguments":{}}}"#))
        XCTAssertTrue(r.isError)
        XCTAssertFalse(called)

        let dry = server(cleaned: { _ in called = true })
        let d = try toolPayload(await dry.handle(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"clean_safe","arguments":{"dry_run":true}}}"#))
        XCTAssertFalse(called)
        XCTAssertEqual((d.payload["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((d.payload["protected"] as? [[String: Any]])?.first?["reason"] as? String, "Active project")
    }
}

final class SizeCacheTests: XCTestCase {
    func testReusesUntilSomethingChangesOrItExpires() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("devsweep-size-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "a".write(to: dir.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        let cache = SizeCache(url: dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + "-cache.json"), maxAge: 3600, load: false)
        var computed = 0
        func size(_ now: Date = Date()) -> Int64 { cache.size(of: dir, now: now) { computed += 1; return Int64(computed) } }

        XCTAssertEqual(size(), 1)
        XCTAssertEqual(size(), 1)                        // unchanged: reused
        XCTAssertEqual(computed, 1)
        try "b".write(to: dir.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(size(), 2)                        // a child folder changed: measured again
        XCTAssertEqual(size(Date().addingTimeInterval(7200)), 3)  // too old: measured again

        cache.save()
        let reloaded = SizeCache(url: dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + "-cache.json"), maxAge: 3600)
        XCTAssertEqual(reloaded.size(of: dir, now: Date().addingTimeInterval(7200)) { 99 }, 3)
    }
}

final class DockerParsingTests: XCTestCase {
    func testParsesSystemDf() {
        let out = """
        {"Active":"2","Reclaimable":"1.2GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
        {"Active":"1","Reclaimable":"512MB (100%)","Size":"512MB","TotalCount":"3","Type":"Containers"}
        {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"3.5GB","Size":"3.5GB","TotalCount":"40","Type":"Build Cache"}
        """
        let rows = DockerRecipe.parse(out)
        XCTAssertEqual(rows.map(\.type), ["Images", "Containers", "Local Volumes", "Build Cache"])
        XCTAssertEqual(rows[0].reclaimable, 1_200_000_000)
        XCTAssertEqual(rows[1].reclaimable, 512_000_000)
        XCTAssertEqual(rows[2].reclaimable, 0)
        XCTAssertEqual(DockerRecipe.bytes("12.5kB"), 12_500)
    }
}

final class LargeFilesTests: XCTestCase {
    let fm = FileManager.default
    var home: URL!

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("devsweep-large-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    @discardableResult
    func make(_ rel: String, mb: Int = 0) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let h = fm.createFile(atPath: url.path, contents: nil)
        XCTAssertTrue(h)
        if mb > 0 {
            let f = try FileHandle(forWritingTo: url)
            // Real bytes, not a sparse file: the recipe measures allocated size.
            let chunk = Data(repeating: 1, count: 1_048_576)
            for _ in 0..<mb { try f.write(contentsOf: chunk) }
            try f.close()
        }
        return url
    }

    func eligible(_ rel: String) -> Bool {
        var cache: [String: Bool] = [:]
        return LargeFilesRecipe.eligible(home.appendingPathComponent(rel), home: home, gitCache: &cache)
    }

    func testEligibilityKeepsOwnFilesAndSkipsEverythingElse() throws {
        try make("Downloads/a.dmg")
        try make("Dev/repo/.git/HEAD")
        try make("Dev/repo/assets/big.mov")
        XCTAssertTrue(eligible("Downloads/a.dmg"))
        XCTAssertFalse(eligible("big.mov"), "directly in home")
        XCTAssertFalse(eligible("Library/Caches/x.bin"))
        XCTAssertFalse(eligible(".Trash/x.zip"))
        XCTAssertFalse(eligible("Downloads/Photos.photoslibrary/originals/x.heic"))
        XCTAssertFalse(eligible("Downloads/App.app/Contents/x.bin"))
        XCTAssertFalse(eligible("Dropbox/x/y.zip"))
        XCTAssertFalse(eligible("OneDrive - Corp/x/y.zip"))
        XCTAssertFalse(eligible("Downloads/movie.mp4.crdownload"))
        XCTAssertFalse(eligible("Dev/web/node_modules/x/y.node"))
        XCTAssertFalse(eligible("Dev/repo/assets/big.mov"), "inside a git repository")
        var cache: [String: Bool] = [:]
        XCTAssertFalse(LargeFilesRecipe.eligible(URL(fileURLWithPath: "/etc/hosts"), home: home, gitCache: &cache))
    }

    func testKinds() {
        func k(_ n: String) -> LargeFileKind { LargeFileKind.kind(of: URL(fileURLWithPath: "/x/\(n)")) }
        XCTAssertEqual(k("Xcode.xip"), .diskImage)
        XCTAssertEqual(k("a.ZIP"), .archive)
        XCTAssertEqual(k("a.mov"), .video)
        XCTAssertEqual(k("a.pdf"), .document)
        XCTAssertEqual(k("a.bin"), .other)
    }

    func testLargeFilesNeverCountTowardsDeveloperTotals() {
        let disk = DiskInfo(total: 100, available: 50)
        func item(_ eco: Ecosystem, _ tier: Tier, _ size: Int64) -> Item {
            Item(recipeID: "t", key: "\(eco)\(size)", ecosystem: eco, tier: tier, name: "n", detail: "", paths: [],
                 size: size, lossNote: "")
        }
        let r = ScanResult(items: [item(.largeFiles, .hasData, 900), item(.xcode, .hasData, 10), item(.xcode, .rebuilds, 5)],
                           disk: disk, scannedAt: Date(), duration: 0)
        XCTAssertEqual(r.total(tier: .hasData), 10)
        XCTAssertEqual(r.total, 15)
        XCTAssertEqual(r.total(ecosystem: .largeFiles), 900)
        XCTAssertEqual(r.safeSelection.map(\.size), [5])
        XCTAssertFalse(Ecosystem.developerAreas.contains(.largeFiles))
    }

    func testCleanerAlwaysTrashesLargeFilesEvenWhenAskedToDelete() throws {
        let file = try make("Downloads/old.iso", mb: 1)
        let item = Item(recipeID: LargeFilesRecipe.recipeID, key: file.path, ecosystem: .largeFiles, tier: .hasData,
                        name: "old.iso", detail: "", paths: [file], size: 1, lossNote: "")
        let out = Cleaner(home: home, allowedRoots: [home]).clean([item], mode: { _ in .delete })
        XCTAssertTrue(out[0].succeeded, out[0].error ?? "")
        XCTAssertEqual(out[0].freed, 0)
        XCTAssertEqual(out[0].movedToTrash, 1)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }

    func testCleanerRefusesALargeFileThatMovedIntoAGitRepo() throws {
        let file = try make("Dev/repo/big.zip", mb: 1)
        try fm.createDirectory(at: home.appendingPathComponent("Dev/repo/.git"), withIntermediateDirectories: true)
        let item = Item(recipeID: LargeFilesRecipe.recipeID, key: file.path, ecosystem: .largeFiles, tier: .hasData,
                        name: "big.zip", detail: "", paths: [file], size: 1, lossNote: "")
        let out = Cleaner(home: home, allowedRoots: [home]).clean([item], mode: { _ in .trash })
        XCTAssertFalse(out[0].succeeded)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }

    func testFallbackWalkFindsOnlyBigFilesInKnownFolders() throws {
        try make("Downloads/big.zip", mb: 150)
        try make("Downloads/small.zip", mb: 1)
        try make("Projects/other/big.zip", mb: 150)
        let found = LargeFilesRecipe.walk(home: home).map(\.lastPathComponent)
        XCTAssertEqual(found, ["big.zip"])
    }
}
