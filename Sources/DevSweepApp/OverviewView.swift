import DevSweepCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let result: ScanResult
    @Binding var route: Route?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    FreeSpaceHeader(disk: result.disk)
                    DiskBar(result: result)
                    Text("\(ByteFormat.string(result.total)) of this disk is developer data DevSweep understands. Scanned \(RelativeDate.string(result.scannedAt)) in \(String(format: "%.1f", result.duration)) s.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 14) {
                    ForEach(Tier.allCases, id: \.self) { tier in TierCard(tier: tier, result: result) }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("By area").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(Ecosystem.allCases) { eco in
                            Button { route = .ecosystem(eco) } label: { EcosystemTile(ecosystem: eco, result: result) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("Overview")
    }
}

struct TierCard: View {
    @Environment(AppModel.self) private var model
    let tier: Tier
    let result: ScanResult

    var body: some View {
        let items = result.items.filter { $0.tier == tier }
        let protected = items.filter(\.isProtected)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TierBadge(tier: tier)
                Spacer()
                if tier == .rebuilds { Text("Selected by default").font(.caption).foregroundStyle(.secondary) }
                else if tier == .hasData { Text("Review one by one").font(.caption).foregroundStyle(.secondary) }
            }
            Text(ByteFormat.string(result.total(tier: tier))).font(.system(size: 26, weight: .bold)).monospacedDigit()
            Text(tier.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !protected.isEmpty {
                Label("\(protected.count) protected · \(ByteFormat.string(protected.reduce(0) { $0 + $1.size }))",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 20, tint: tier == .rebuilds ? tier.color : nil, emphasized: tier == .rebuilds)
    }
}

struct EcosystemTile: View {
    let ecosystem: Ecosystem
    let result: ScanResult

    var body: some View {
        let items = result.items.filter { $0.ecosystem == ecosystem }
        let total = max(Double(result.total(ecosystem: ecosystem)), 1)
        let top = items.max { $0.size < $1.size }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(ecosystem.title, systemImage: ecosystem.symbol).font(.headline)
                Spacer()
                Text(items.isEmpty ? "Nothing found" : ByteFormat.string(result.total(ecosystem: ecosystem)))
                    .font(.headline).monospacedDigit()
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Tier.allCases, id: \.self) { t in
                        let s = Double(items.filter { $0.tier == t }.reduce(0) { $0 + $1.size })
                        Rectangle().fill(t.color).frame(width: geo.size.width * s / total)
                    }
                }
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
            }
            .frame(height: 6)
            Text(top.map { "Largest: \($0.name) · \(ByteFormat.string($0.size))" } ?? " ")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentCard(cornerRadius: 18)
    }
}
