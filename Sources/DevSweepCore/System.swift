import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// Runs an executable directly (no shell interpolation) and captures its output.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) -> ShellResult {
        // Output goes to temp files, not pipes: tools like git and simctl may leave a helper
        // process holding a pipe open, and waiting for EOF on it would hang forever.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("devsweep-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: outURL); try? fm.removeItem(at: errURL) }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return ShellResult(status: -1, stdout: "", stderr: "could not create temp files")
        }
        defer { try? outHandle.close(); try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"  // never take git locks while the user is working
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            return ShellResult(status: -2, stdout: "", stderr: "timed out after \(Int(timeout)) s")
        }
        return ShellResult(status: process.terminationStatus,
                           stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                           stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }
}

public enum FileSize {
    /// Allocated size on disk of a file or directory tree. Symlinks are not followed.
    public static func allocated(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .isDirectoryKey]
        guard let top = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if top.isSymbolicLink == true { return 0 }
        if top.isDirectory != true {
            return Int64(top.totalFileAllocatedSize ?? top.fileAllocatedSize ?? 0)
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    public static func allocated(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + allocated($1) } }

    /// Measures many paths in parallel.
    public static func measure(_ urls: [URL]) async -> [URL: Int64] {
        await withTaskGroup(of: (URL, Int64).self) { group in
            for u in urls { group.addTask { (u, allocated(u)) } }
            var result: [URL: Int64] = [:]
            for await (u, s) in group { result[u] = s }
            return result
        }
    }
}

public extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    func subdirectories(of url: URL) -> [URL] {
        let items = (try? contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                              options: [.skipsHiddenFiles])) ?? []
        return items.filter { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return v?.isDirectory == true && v?.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// A point-in-time view of what is running, used by protection rules.
public struct SystemSnapshot: Sendable {
    public let commandLines: [String]

    public init(commandLines: [String]) { self.commandLines = commandLines }

    public static func capture() -> SystemSnapshot {
        let r = Shell.run("/bin/ps", ["-axww", "-o", "command="], timeout: 10)
        return SystemSnapshot(commandLines: r.stdout.split(separator: "\n").map(String.init))
    }

    public func anyRunning(containing needle: String) -> Bool {
        commandLines.contains { $0.contains(needle) }
    }

    public var xcodeRunning: Bool { anyRunning(containing: "/Contents/MacOS/Xcode") }
    public var androidStudioRunning: Bool {
        commandLines.contains { $0.contains("Android Studio") && $0.contains("/Contents/MacOS/studio") }
    }
    public var gradleDaemonRunning: Bool { anyRunning(containing: "GradleDaemon") }

    /// Names of Android emulators currently running (from `-avd NAME` or `@NAME`).
    public var runningAVDs: Set<String> {
        var names = Set<String>()
        for line in commandLines where line.contains("qemu-system") || line.contains("/emulator") {
            let parts = line.split(separator: " ").map(String.init)
            for (i, p) in parts.enumerated() {
                if p == "-avd", i + 1 < parts.count { names.insert(parts[i + 1]) }
                if p.hasPrefix("@"), p.count > 1 { names.insert(String(p.dropFirst())) }
            }
        }
        return names
    }
}

/// How recently a project was worked on. Used to keep active projects safe.
public struct ProjectActivity: Sendable {
    public let lastCommit: Date?
    public let hasUncommittedChanges: Bool
    public let lastModified: Date?

    public var lastActivity: Date? {
        [lastCommit, lastModified].compactMap { $0 }.max()
    }

    public func isActive(withinDays days: Int, now: Date = Date()) -> Bool {
        if hasUncommittedChanges { return true }
        guard let last = lastCommit ?? lastModified else { return false }
        return now.timeIntervalSince(last) < Double(days) * 86_400
    }

    public static func of(_ dir: URL, markerFiles: [URL]) -> ProjectActivity {
        let git = "/usr/bin/git"
        let inside = Shell.run(git, ["-C", dir.path, "rev-parse", "--is-inside-work-tree"], timeout: 10)
        let markerDate = markerFiles.compactMap { FileManager.default.modificationDate($0) }.max()
        guard inside.ok, inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return ProjectActivity(lastCommit: nil, hasUncommittedChanges: false, lastModified: markerDate)
        }
        let log = Shell.run(git, ["-C", dir.path, "log", "-1", "--format=%ct", "--", "."], timeout: 15)
        let ts = TimeInterval(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let status = Shell.run(git, ["-C", dir.path, "status", "--porcelain", "--untracked-files=no", "--", "."],
                               timeout: 30)
        let dirty = status.ok && !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ProjectActivity(lastCommit: ts.map { Date(timeIntervalSince1970: $0) },
                               hasUncommittedChanges: dirty, lastModified: markerDate)
    }
}

public enum RelativeDate {
    public static func string(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "unknown" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: "en_US")  // the UI copy is English; keep phrases consistent
        return f.localizedString(for: date, relativeTo: now)
    }
}
