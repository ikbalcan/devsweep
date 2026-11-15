import DevSweepCore
import SwiftUI

enum TierFilter: String, CaseIterable, Identifiable {
    case all = "All", rebuilds = "Rebuilds", redownload = "Re-download", hasData = "Has data"
    var id: String { rawValue }
    var tier: Tier? {
        switch self {
        case .all: return nil
        case .rebuilds: return .rebuilds
        case .redownload: return .redownload
        case .hasData: return .hasData
        }
    }
}

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    let ecosystem: Ecosystem
    @State private var filter: TierFilter = .all
    @State private var focused: Item.ID?
    @State private var showInspector = true

    var body: some View {
        let all = model.items(in: ecosystem)
        let shown = all.filter { filter.tier == nil || $0.tier == filter.tier }
        let groups = Dictionary(grouping: shown, by: \.recipeID)
            .sorted { ($0.value.reduce(0) { $0 + $1.size }) > ($1.value.reduce(0) { $0 + $1.size }) }

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Tier", selection: $filter) {
                    ForEach(TierFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer()
                Button("Select safe") { model.selectAllSafe(in: ecosystem) }
                Button("Clear") { model.clearSelection(in: ecosystem) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            if all.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: ecosystem.symbol,
                                       description: Text("DevSweep found nothing to clean in \(ecosystem.title)."))
            } else {
                List(selection: $focused) {
                    ForEach(groups, id: \.key) { key, items in
                        Section {
                            ForEach(items) { item in ItemRow(item: item).tag(item.id) }
                        } header: {
                            HStack {
                                Text(AppModel.recipeTitles[key] ?? key)
                                Spacer()
                                Text(ByteFormat.string(items.reduce(0) { $0 + $1.size })).monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(ecosystem.title)
        .navigationSubtitle(ByteFormat.string(model.result?.total(ecosystem: ecosystem) ?? 0))
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = focused, let item = all.first(where: { $0.id == id }) {
                    ItemInspector(item: item)
                } else {
                    ContentUnavailableView("Select an item", systemImage: "sidebar.right",
                                           description: Text("See what is lost and how it is removed."))
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
            }
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            if item.isProtected {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .help(item.protection ?? "")
                    .accessibilityLabel("Protected: \(item.protection ?? "")")
            } else {
                Toggle(isOn: Binding(get: { model.isSelected(item) }, set: { model.setSelected(item, $0) })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)
                .accessibilityLabel("Select \(item.name)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.protection ?? item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            TierBadge(tier: item.tier)
            Text(ByteFormat.string(item.size))
                .monospacedDigit()
                .fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(item.isProtected ? 0.7 : 1)
    }
}

struct ItemInspector: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TierBadge(tier: item.tier)
                Text(item.name).font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(ByteFormat.string(item.size)).bold() }
                    GridRow { Text("Last used").foregroundStyle(.secondary); Text(RelativeDate.string(item.lastUsed)) }
                    GridRow { Text("Details").foregroundStyle(.secondary); Text(item.detail).fixedSize(horizontal: false, vertical: true) }
                }
                .font(.callout)

                if let why = item.protection {
                    Label(why, systemImage: "lock.fill")
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.tier == .hasData ? "You will lose" : "What happens").font(.callout.bold())
                    Text(item.lossNote).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(item.tier.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text("HOW IT IS REMOVED").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(item.howRemoved)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    if case .removePaths = item.action {
                        Text(item.tier == .rebuilds ? "Deleted right away (it regenerates)." : "Moved to the Trash by default.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !item.paths.isEmpty {
                    Button("Reveal in Finder") { revealInFinder(item.paths) }
                }
            }
            .padding(16)
        }
    }
}
