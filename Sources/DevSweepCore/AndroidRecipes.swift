import Foundation

struct AVD: Sendable {
    let name: String
    let dir: URL
    let ini: URL
    let sysdir: String?
    let displayName: String?

    static func all(home: URL) -> [AVD] {
        let avdRoot = home.appendingPathComponent(".android/avd")
        let fm = FileManager.default
        let inis = ((try? fm.contentsOfDirectory(at: avdRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ini" }
        return inis.compactMap { ini in
            let name = ini.deletingPathExtension().lastPathComponent
            let props = Self.properties(ini)
            let dir = props["path"].map { URL(fileURLWithPath: $0) } ?? avdRoot.appendingPathComponent("\(name).avd")
            let config = Self.properties(dir.appendingPathComponent("config.ini"))
            return AVD(name: name, dir: dir, ini: ini, sysdir: config["image.sysdir.1"],
                       displayName: config["avd.ini.displayname"])
        }
    }

    static func properties(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[line[..<eq].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}

struct AVDRecipe: Recipe {
    let id = "android-avd"

    func discover(_ ctx: ScanContext) async -> [Item] {
        let avds = AVD.all(home: ctx.home)
        let running = ctx.snapshot.runningAVDs
        let sizes = await FileSize.measure(avds.map(\.dir))
        let fm = FileManager.default
        return avds.map { avd in
            let last = fm.modificationDate(avd.dir.appendingPathComponent("userdata-qemu.img"))
                ?? fm.modificationDate(avd.dir)
            let image = avd.sysdir.map { $0.split(separator: "/").dropFirst().joined(separator: " · ") } ?? "unknown image"
            let isRunning = running.contains(avd.name)
            return Item(recipeID: id, key: avd.name, ecosystem: .android, tier: .hasData,
                        name: avd.displayName.map { "\($0) (\(avd.name))" } ?? avd.name,
                        detail: "Emulator · \(image) · " + (isRunning ? "Running" : "Last used \(RelativeDate.string(last, now: ctx.now))"),
                        paths: [avd.dir, avd.ini], size: sizes[avd.dir] ?? 0,
                        lossNote: "Installed apps, their data and logins, and saved snapshots on this emulator. You can recreate the device in Android Studio in about a minute.",
                        protection: isRunning ? "Emulator is running" : nil, lastUsed: last)
        }
    }
}

struct AndroidSDKRecipe: Recipe {
    let id = "android-sdk"

    func discover(_ ctx: ScanContext) async -> [Item] {
        let sdk = ctx.options.androidSDK
        let fm = FileManager.default
        guard fm.isDirectory(sdk) else { return [] }
        var items: [Item] = []

        // System images: one item per ABI folder. Locked while an emulator uses it.
        let used = Set(AVD.all(home: ctx.home).compactMap { $0.sysdir }.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        var images: [URL] = []
        for api in fm.subdirectories(of: sdk.appendingPathComponent("system-images")) {
            for tag in fm.subdirectories(of: api) { images += fm.subdirectories(of: tag) }
        }
        let imageSizes = await FileSize.measure(images)
        for img in images {
            let rel = img.path.replacingOccurrences(of: sdk.path + "/", with: "")
            let users = used.contains(rel)
            items.append(Item(recipeID: id, key: rel, ecosystem: .android, tier: .redownload,
                              name: "System image " + rel.split(separator: "/").dropFirst().joined(separator: " · "),
                              detail: users ? "Used by an emulator" : "No emulator uses it",
                              paths: [img], size: imageSizes[img] ?? 0,
                              lossNote: "Re-downloaded by Android Studio's SDK Manager when you create an emulator with it.",
                              protection: users ? "Used by an existing emulator" : nil, lastUsed: fm.modificationDate(img)))
        }

        // build-tools and NDK: one item per version. The newest build-tools stays.
        for (folder, label, keepNewest) in [("build-tools", "build-tools", true), ("ndk", "NDK", false)] {
            let versions = fm.subdirectories(of: sdk.appendingPathComponent(folder))
            let sizes = await FileSize.measure(versions)
            let newest = versions.map(\.lastPathComponent).max { $0.compare($1, options: .numeric) == .orderedAscending }
            for v in versions {
                let isNewest = keepNewest && v.lastPathComponent == newest
                items.append(Item(recipeID: id, key: "\(folder)/\(v.lastPathComponent)", ecosystem: .android, tier: .redownload,
                                  name: "\(label) \(v.lastPathComponent)",
                                  detail: isNewest ? "Newest installed version" : "Android SDK package",
                                  paths: [v], size: sizes[v] ?? 0,
                                  lossNote: "Gradle or the SDK Manager downloads it again if a project asks for this exact version.",
                                  protection: isNewest ? "Newest version is kept" : nil, lastUsed: fm.modificationDate(v)))
            }
        }
        return items
    }
}

struct GradleCachesRecipe: Recipe {
    let id = "gradle-caches"

    func discover(_ ctx: ScanContext) async -> [Item] {
        let gradle = ctx.home.appendingPathComponent(".gradle")
        let targets: [(String, String, String)] = [
            ("caches", "Gradle caches", "Downloaded dependencies, transforms and build cache"),
            ("daemon", "Gradle daemon logs", "Logs and registry of past daemons"),
        ]
        var protection: String?
        if ctx.snapshot.gradleDaemonRunning { protection = "Gradle daemon is running (./gradlew --stop)" }
        else if ctx.snapshot.androidStudioRunning { protection = "Android Studio is open" }
        let urls = targets.map { gradle.appendingPathComponent($0.0) }.filter { FileManager.default.isDirectory($0) }
        let sizes = await FileSize.measure(urls)
        return targets.compactMap { t in
            let url = gradle.appendingPathComponent(t.0)
            guard FileManager.default.isDirectory(url) else { return nil }
            return Item(recipeID: id, key: t.0, ecosystem: .gradle, tier: .rebuilds, name: t.1, detail: t.2,
                        paths: [url], size: sizes[url] ?? 0,
                        lossNote: "The next Android/Gradle build downloads its dependencies again, so it is slower once.",
                        protection: protection, lastUsed: FileManager.default.modificationDate(url))
        }
    }
}

struct GradleWrapperRecipe: Recipe {
    let id = "gradle-wrapper"

    func discover(_ ctx: ScanContext) async -> [Item] {
        let dists = FileManager.default.subdirectories(of: ctx.home.appendingPathComponent(".gradle/wrapper/dists"))
        let used = ctx.projects.reduce(into: Set<String>()) { $0.formUnion($1.gradleWrapperDists) }
        let sizes = await FileSize.measure(dists)
        return dists.map { d in
            let name = d.lastPathComponent
            let inUse = used.contains(name)
            return Item(recipeID: id, key: name, ecosystem: .gradle, tier: .redownload,
                        name: "Gradle \(name.replacingOccurrences(of: "gradle-", with: ""))",
                        detail: inUse ? "Used by a project on this Mac" : "No project on this Mac uses it",
                        paths: [d], size: sizes[d] ?? 0,
                        lossNote: "Downloaded again by ./gradlew if a project asks for this version.",
                        protection: inUse ? "A project uses this Gradle version" : nil,
                        lastUsed: FileManager.default.modificationDate(d))
        }
    }
}

struct PackageCachesRecipe: Recipe {
    let id = "package-caches"

    struct Cache {
        let key: String
        let name: String
        let path: String
        let tier: Tier
        let loss: String
        var runningMarker: String? = nil
    }

    static let caches: [Cache] = [
        Cache(key: "npm", name: "npm cache", path: ".npm/_cacache", tier: .rebuilds,
              loss: "Packages are fetched again on the next npm install."),
        Cache(key: "npx", name: "npx cache", path: ".npm/_npx", tier: .rebuilds,
              loss: "Tools run with npx are downloaded again on next use.", runningMarker: "/.npm/_npx/"),
        Cache(key: "yarn", name: "Yarn cache", path: "Library/Caches/Yarn", tier: .rebuilds,
              loss: "Packages are fetched again on the next yarn install."),
        Cache(key: "pnpm", name: "pnpm store", path: "Library/pnpm/store", tier: .rebuilds,
              loss: "Packages are fetched again on the next pnpm install."),
        Cache(key: "bun", name: "Bun cache", path: ".bun/install/cache", tier: .rebuilds,
              loss: "Packages are fetched again on the next bun install."),
        Cache(key: "pub-hosted", name: "Dart/Flutter pub cache", path: ".pub-cache/hosted", tier: .rebuilds,
              loss: "Packages are fetched again on the next flutter pub get. Globally activated tools are kept."),
        Cache(key: "pub-git", name: "Dart/Flutter git packages", path: ".pub-cache/git", tier: .rebuilds,
              loss: "Git dependencies are cloned again on the next flutter pub get."),
        Cache(key: "cocoapods-cache", name: "CocoaPods cache", path: "Library/Caches/CocoaPods", tier: .rebuilds,
              loss: "Pods are downloaded again on the next pod install."),
        Cache(key: "cocoapods-repos", name: "CocoaPods spec repos", path: ".cocoapods/repos", tier: .redownload,
              loss: "Spec repos are cloned again if a Podfile asks for them. Most projects use the CDN and never need it."),
        Cache(key: "swiftpm", name: "SwiftPM cache", path: "Library/Caches/org.swift.swiftpm", tier: .rebuilds,
              loss: "Swift packages are fetched again on the next resolve."),
        Cache(key: "homebrew", name: "Homebrew downloads", path: "Library/Caches/Homebrew", tier: .rebuilds,
              loss: "Installers are downloaded again if you reinstall a formula."),
        Cache(key: "pip", name: "pip cache", path: "Library/Caches/pip", tier: .rebuilds,
              loss: "Wheels are downloaded again on the next pip install."),
        Cache(key: "dart-server", name: "Dart analysis server cache", path: ".dartServer", tier: .rebuilds,
              loss: "The Dart/Flutter analyzer re-indexes your projects the next time an editor opens them.",
              runningMarker: "analysis_server"),
        Cache(key: "maven", name: "Maven repository", path: ".m2/repository", tier: .hasData,
              loss: "Downloaded artifacts come back on the next build, but anything you installed locally with mvn install is lost."),
    ]

    func discover(_ ctx: ScanContext) async -> [Item] {
        let present = Self.caches.filter { FileManager.default.isDirectory(ctx.home.appendingPathComponent($0.path)) }
        let urls = present.map { ctx.home.appendingPathComponent($0.path) }
        let sizes = await FileSize.measure(urls)
        return present.map { c in
            let url = ctx.home.appendingPathComponent(c.path)
            var protection: String?
            if let marker = c.runningMarker, ctx.snapshot.anyRunning(containing: marker) {
                protection = "A running tool uses it"
            }
            return Item(recipeID: id, key: c.key, ecosystem: .packages, tier: c.tier, name: c.name,
                        detail: "~/" + c.path, paths: [url], size: sizes[url] ?? 0, lossNote: c.loss,
                        protection: protection, lastUsed: FileManager.default.modificationDate(url))
        }
    }
}
