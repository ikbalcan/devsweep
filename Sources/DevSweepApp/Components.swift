import AppKit
import DevSweepCore
import SwiftUI

extension Tier {
    var color: Color {
        switch self {
        case .rebuilds: return .green
        case .redownload: return .blue
        case .hasData: return .orange
        }
    }
}

struct TierBadge: View {
    let tier: Tier

    var body: some View {
        Text(tier.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tier.color)
            .background(tier.color.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}

/// Horizontal stacked bar of the whole disk: other usage, the three tiers, free space.
struct DiskBar: View {
    let result: ScanResult
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(result.disk.total), 1)
            let used = Double(result.disk.total - result.disk.available)
            let tiers = Tier.allCases.map { Double(result.total(tier: $0)) }
            let other = max(used - tiers.reduce(0, +), 0)
            HStack(spacing: 0) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: geo.size.width * other / total)
                ForEach(Array(Tier.allCases.enumerated()), id: \.offset) { i, tier in
                    Rectangle().fill(tier.color).frame(width: geo.size.width * tiers[i] / total)
                }
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Disk usage")
        .accessibilityValue("\(ByteFormat.string(result.disk.available)) free of \(ByteFormat.string(result.disk.total))")
    }
}

struct FreeSpaceHeader: View {
    let disk: DiskInfo

    var isCritical: Bool { disk.available < 5_000_000_000 }
    var isLow: Bool { disk.available < 15_000_000_000 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(ByteFormat.string(disk.available)) free")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(isCritical ? Color.red : isLow ? Color.orange : Color.primary)
            Text("of \(ByteFormat.string(disk.total))")
                .foregroundStyle(.secondary)
        }
    }
}

func revealInFinder(_ urls: [URL]) {
    let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !existing.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(existing)
}
