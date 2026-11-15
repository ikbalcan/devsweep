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

    func testDefaultModes() {
        XCTAssertEqual(Tier.rebuilds.defaultRemovalMode, .delete)
        XCTAssertEqual(Tier.redownload.defaultRemovalMode, .trash)
        XCTAssertEqual(Tier.hasData.defaultRemovalMode, .trash)
    }
}
