import Foundation

/// Docker Desktop, OrbStack, Colima: anything with a `docker` CLI and a running daemon.
/// Cleaning goes through `docker ... prune`, never by touching the VM disk image.
struct DockerRecipe: Recipe {
    let id = "docker"

    static let binaries = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                           "/Applications/Docker.app/Contents/Resources/bin/docker",
                           NSHomeDirectory() + "/.orbstack/bin/docker"]

    struct Row { let type: String; let reclaimable: Int64; let total: Int64; let count: String; let active: String }

    func discover(_ ctx: ScanContext) async -> [Item] {
        guard let docker = Self.binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let r = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 30)
        guard r.ok else {
            // CLI present but no daemon: show the VM disk so the space is at least visible.
            let raw = ctx.home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
            guard let size = (try? raw.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize else { return [] }
            return [Item(recipeID: id, key: "vm-disk", ecosystem: .docker, tier: .hasData, name: "Docker disk image",
                         detail: "Docker is not running", paths: [raw], size: Int64(size),
                         lossNote: "All images, containers and volumes. DevSweep only cleans inside it, with docker prune.",
                         protection: "Start Docker to see and clean what is inside")]
        }
        return Self.parse(r.stdout).compactMap { row in item(row, docker) }
    }

    private func item(_ row: Row, _ docker: String) -> Item? {
        guard row.reclaimable > 0 else { return nil }
        let (key, name, tier, args, loss): (String, String, Tier, [String], String)
        switch row.type {
        case "Build Cache":
            (key, name, tier, args, loss) = ("build-cache", "Docker build cache", .rebuilds, ["builder", "prune", "-f"],
                                             "Layers are rebuilt on the next docker build, which is slower once.")
        case "Images":
            (key, name, tier, args, loss) = ("images", "Unused Docker images", .redownload, ["image", "prune", "-a", "-f"],
                                             "Images no container uses. Pulled or rebuilt again when you need them.")
        case "Containers":
            (key, name, tier, args, loss) = ("containers", "Stopped Docker containers", .hasData, ["container", "prune", "-f"],
                                             "Stopped containers and anything written inside them.")
        case "Local Volumes":
            (key, name, tier, args, loss) = ("volumes", "Unused anonymous Docker volumes", .hasData, ["volume", "prune", "-f"],
                                             "Data in volumes no container uses, such as old database files. Named volumes are kept.")
        default:
            return nil
        }
        return Item(recipeID: id, key: key, ecosystem: .docker, tier: tier, name: name,
                    detail: "\(row.count) total, \(row.active) in use", paths: [], size: row.reclaimable,
                    action: .command([docker] + args), lossNote: loss)
    }

    /// One JSON object per line: {"Type":"Images","TotalCount":"5","Active":"2","Size":"2.4GB","Reclaimable":"1.2GB (50%)"}
    static func parse(_ output: String) -> [Row] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["Type"] as? String else { return nil }
            return Row(type: type, reclaimable: bytes(obj["Reclaimable"] as? String ?? "0"),
                       total: bytes(obj["Size"] as? String ?? "0"),
                       count: obj["TotalCount"] as? String ?? "?", active: obj["Active"] as? String ?? "?")
        }
    }

    /// "1.2GB (50%)" -> 1_200_000_000. Docker prints decimal units.
    static func bytes(_ s: String) -> Int64 {
        let token = s.split(separator: " ").first.map(String.init) ?? ""
        let number = token.prefix { $0.isNumber || $0 == "." }
        let unit = token.dropFirst(number.count).uppercased()
        let mult: Double
        switch unit {
        case "KB": mult = 1e3
        case "MB": mult = 1e6
        case "GB": mult = 1e9
        case "TB": mult = 1e12
        default: mult = 1
        }
        return Int64((Double(number) ?? 0) * mult)
    }
}
