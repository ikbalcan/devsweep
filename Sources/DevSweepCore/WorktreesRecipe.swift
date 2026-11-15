import Foundation

/// Git worktrees, the way AI agents (Cursor, Claude Code, Codex) run tasks in parallel. Each one is a
/// full checkout with its own node_modules and build output, and agents rarely clean them up.
///
/// Removal goes through `git worktree remove` without --force: git itself refuses when the worktree
/// has modified or untracked files, or is locked. The branch and its commits stay in the repository.
struct WorktreesRecipe: Recipe {
    let id = "worktrees"

    struct Worktree: Hashable {
        let path: URL
        /// The main repository (the folder that holds .git).
        let repo: URL
        /// <repo>/.git/worktrees/<name>
        let admin: URL
    }

    /// Folders where agents create worktrees outside the repository, as <folder>/<repo>/<id>.
    static let toolFolders = [".cursor/worktrees", ".codex/worktrees"]

    func discover(_ ctx: ScanContext) async -> [Item] {
        var found = Set<Worktree>()
        var repos = Set<URL>()
        for p in ctx.projects {
            if let r = Self.repoRoot(of: p.root, home: ctx.home) { repos.insert(r) }
        }
        for r in repos { found.formUnion(Self.registered(in: r)) }
        let fm = FileManager.default
        for folder in Self.toolFolders {
            for repoDir in fm.subdirectories(of: ctx.home.appendingPathComponent(folder)) {
                for dir in fm.subdirectories(of: repoDir) {
                    if let wt = Self.worktree(at: dir) { found.insert(wt) }
                }
            }
        }
        var items: [Item] = []
        for wt in found.sorted(by: { $0.path.path < $1.path.path }) {
            items.append(await item(wt, ctx))
        }
        return items
    }

    private func item(_ wt: Worktree, _ ctx: ScanContext) async -> Item {
        let size = await FileSize.measure([wt.path]).values.reduce(0, +)
        let branch = Shell.run("/usr/bin/git", ["-C", wt.path.path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 10)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastUsed = Self.lastUsed(wt)
        var protection = Self.problem(wt) ?? (ctx.snapshot.anyRunning(containing: wt.path.path)
                                               ? "A running process uses this worktree" : nil)
        if protection == nil, let last = lastUsed,
           ctx.now.timeIntervalSince(last) < Double(ctx.options.activeProjectDays) * 86_400 {
            protection = "Used \(RelativeDate.string(last, now: ctx.now)); an agent may still be working here"
        }
        let branchText = branch.isEmpty || branch == "HEAD" ? "detached" : "branch \(branch)"
        return Item(recipeID: id, key: wt.path.standardizedFileURL.path, ecosystem: .aiTools, tier: .redownload,
                    name: "\(wt.repo.lastPathComponent) worktree \(wt.path.lastPathComponent)",
                    detail: "\(Self.tool(for: wt.path)) · \(branchText) · \(PathDisplay.tilde(wt.path))",
                    paths: [wt.path], size: size,
                    action: .command(["/usr/bin/git", "-C", wt.repo.path, "worktree", "remove", wt.path.path]),
                    lossNote: "The checkout and its ignored files (node_modules, build output, local .env copies). The branch and its commits stay in \(wt.repo.lastPathComponent); bring it back with git worktree add.",
                    protection: protection, lastUsed: lastUsed)
    }

    /// Why this worktree must not be removed right now, checked again by the Cleaner just before removal.
    static func problem(_ wt: Worktree) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: wt.admin.appendingPathComponent("locked").path) {
            return "Locked with git worktree lock"
        }
        let git = "/usr/bin/git"
        let status = Shell.run(git, ["-C", wt.path.path, "status", "--porcelain"], timeout: 30)
        guard status.ok else { return "Could not read its git status" }
        let changed = status.stdout.split(whereSeparator: \.isNewline).count
        if changed > 0 { return "Has \(changed) uncommitted or untracked file\(changed == 1 ? "" : "s")" }
        // A detached HEAD whose commits are on no branch would become unreachable.
        let branch = Shell.run(git, ["-C", wt.path.path, "symbolic-ref", "-q", "HEAD"], timeout: 10)
        if !branch.ok {
            // for-each-ref lists real refs only; `git branch --contains` would also print "(HEAD detached at …)".
            let containing = Shell.run(git, ["-C", wt.path.path, "for-each-ref", "--contains", "HEAD", "--format=%(refname)",
                                             "refs/heads", "refs/remotes", "refs/tags"], timeout: 30)
            if !containing.ok || containing.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Has commits that are on no branch"
            }
        }
        return nil
    }

    static func tool(for path: URL) -> String {
        let p = path.path
        if p.contains("/.cursor/worktrees/") { return "Cursor" }
        if p.contains("/.claude/worktrees/") { return "Claude Code" }
        if p.contains("/.codex/worktrees/") { return "Codex" }
        return "git worktree"
    }

    /// Walks up from a project folder to the folder holding a real .git directory, staying inside home.
    static func repoRoot(of dir: URL, home: URL) -> URL? {
        let fm = FileManager.default
        var d = dir.standardizedFileURL
        let homePath = home.standardizedFileURL.path
        while d.path.hasPrefix(homePath + "/") {
            if fm.isDirectory(d.appendingPathComponent(".git")) { return d }
            d = d.deletingLastPathComponent()
        }
        return nil
    }

    /// Worktrees a repository knows about: .git/worktrees/<name>/gitdir holds "<worktree>/.git".
    static func registered(in repo: URL) -> [Worktree] {
        let admins = FileManager.default.subdirectories(of: repo.appendingPathComponent(".git/worktrees"))
        return admins.compactMap { admin in
            guard let text = try? String(contentsOf: admin.appendingPathComponent("gitdir"), encoding: .utf8) else {
                return nil
            }
            let path = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines)).deletingLastPathComponent()
            guard FileManager.default.isDirectory(path) else { return nil }  // stale entry; git worktree prune handles it
            return Worktree(path: path.standardizedFileURL, repo: repo.standardizedFileURL, admin: admin)
        }
    }

    /// A folder whose .git is a file "gitdir: <repo>/.git/worktrees/<name>".
    static func worktree(at dir: URL) -> Worktree? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(".git"), encoding: .utf8),
              text.hasPrefix("gitdir:") else { return nil }
        let admin = URL(fileURLWithPath: text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines))
        let worktrees = admin.deletingLastPathComponent()
        let dotGit = worktrees.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees", dotGit.lastPathComponent == ".git",
              FileManager.default.isDirectory(admin) else { return nil }
        return Worktree(path: dir.standardizedFileURL, repo: dotGit.deletingLastPathComponent().standardizedFileURL,
                        admin: admin)
    }

    /// Latest of the worktree's index, HEAD and reflog (touched by every git operation) and the folder itself.
    static func lastUsed(_ wt: Worktree) -> Date? {
        let fm = FileManager.default
        let candidates = [wt.admin.appendingPathComponent("index"), wt.admin.appendingPathComponent("HEAD"),
                          wt.admin.appendingPathComponent("logs/HEAD"), wt.path]
        return candidates.compactMap { fm.modificationDate($0) }.max()
    }
}
