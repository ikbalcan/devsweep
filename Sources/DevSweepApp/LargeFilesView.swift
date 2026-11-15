import DevSweepCore
import SwiftUI

/// The user's own big files. Unlike the developer areas, nothing here is "safe": nothing is
/// selected for you, and everything you remove goes to the Trash first.
struct LargeFilesView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case size = "Largest first", oldest = "Not opened longest"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("largeFilesMinMB") private var minMB = 100
    @State private var kind: LargeFileKind?
    @State private var sort: Sort = .size
    @State private var focused: Item.ID?
    @State private var showInspector = true

    private static let thresholds: [(label: String, mb: Int)] = [("100 MB", 100), ("250 MB", 250), ("500 MB", 500), ("1 GB", 1024)]

    var body: some View {
        let all = model.items(in: .largeFiles)
        let shown = filtered(all)

        VStack(spacing: 0) {
            notice
            HStack(spacing: 12) {
                Picker("Type", selection: $kind) {
                    Text("All types").tag(LargeFileKind?.none)
                    ForEach(LargeFileKind.allCases) { Label($0.title, systemImage: $0.symbol).tag(LargeFileKind?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Bigger than", selection: $minMB) {
                    ForEach(Self.thresholds, id: \.mb) { Text("Over \($0.label)").tag($0.mb) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                Button("Clear selection") { model.clearSelection(in: .largeFiles) }
                    .lineLimit(1)
                    .fixedSize()
                    .disabled(!all.contains { model.isSelected($0) })
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            if all.isEmpty {
                ContentUnavailableView("No large files found", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Nothing over 100 MB in your own folders. Developer folders, ~/Library, synced folders and git repositories are not searched."))
            } else if shown.isEmpty {
                ContentUnavailableView("Nothing matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Try another type or a lower size."))
            } else {
                List(selection: $focused) {
                    ForEach(shown) { item in LargeFileRow(item: item).tag(item.id) }
                }
                .listStyle(.inset)
                .frame(minHeight: 120, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Large files")
        .navigationSubtitle("\(shown.count) \(shown.count == 1 ? "file" : "files"), \(ByteFormat.string(shown.reduce(0) { $0 + $1.size }))")
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = focused, let item = all.first(where: { $0.id == id }) {
                    ItemInspector(item: item)
                } else {
                    ContentUnavailableView("Select a file", systemImage: "sidebar.right",
                                           description: Text("See where it is and when you last opened it."))
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

    private func filtered(_ all: [Item]) -> [Item] {
        let minBytes = Int64(minMB) * 1_048_576
        return all
            .filter { $0.size >= minBytes && (kind == nil || LargeFileKind.kind(of: $0.paths[0]) == kind) }
            .sorted { a, b in
                sort == .size ? a.size > b.size : (a.lastUsed ?? .distantPast) < (b.lastUsed ?? .distantPast)
            }
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("These are your own files").font(.callout.bold())
                Text("DevSweep cannot know if you still need them, so nothing is selected for you and they are never part of a safe clean, a rule or an agent's clean. Removed files go to the Trash first.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

struct LargeFileRow: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            if item.isProtected {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 18).help(item.protection ?? "")
            } else {
                Toggle(isOn: Binding(get: { model.isSelected(item) }, set: { model.setSelected(item, $0) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 18)
                    .accessibilityLabel("Select \(item.name)")
            }
            Image(systemName: LargeFileKind.kind(of: item.paths[0]).symbol)
                .foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.protection ?? item.detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(item.lastUsed.map { "Opened \(RelativeDate.string($0))" } ?? "")
                .font(.caption).foregroundStyle(.secondary)
            Text(ByteFormat.string(item.size))
                .monospacedDigit().fontWeight(.semibold).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(item.isProtected ? 0.7 : 1)
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder(item.paths) }
        }
    }
}
