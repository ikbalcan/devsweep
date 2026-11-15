import DevSweepCore
import SwiftUI

struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var modes: [Tier: RemovalMode] = [:]
    @State private var acknowledgedData = false
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isCleaning {
                cleaning
            } else if finished, let s = model.lastSummary {
                summary(s)
            } else {
                review
            }
        }
        .frame(width: 620)
        .frame(minHeight: 420)
        .onAppear {
            for t in Tier.allCases { modes[t] = t.defaultRemovalMode }
        }
    }

    // MARK: Review

    private var review: some View {
        let items = model.selectedItems
        let byTier = Dictionary(grouping: items, by: \.tier)
        let hasData = byTier[.hasData] ?? []
        let freedNow = items.filter { $0.ecosystem != .largeFiles && (modes[$0.tier] ?? $0.tier.defaultRemovalMode) == .delete }.reduce(0) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clean \(ByteFormat.string(model.selectedSize))?").font(.title2.bold())
                Text(hasData.isEmpty
                     ? "\(items.count) items. Nothing here holds your own data."
                     : "\(items.count) items, \(hasData.count) of them may hold your data.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Tier.allCases, id: \.self) { tier in
                        if let list = byTier[tier], !list.isEmpty {
                            tierSection(tier, list)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SAFETY").font(.caption.bold()).foregroundStyle(.secondary)
                        check("Protected items (running, active projects, in-use versions) are never included")
                        check("Running Gradle, emulators and tools are checked again right before removal")
                        if items.contains(where: { $0.ecosystem == .largeFiles }) {
                            check("Your own large files are moved to the Trash, never deleted outright")
                        }
                        if items.contains(where: { $0.ecosystem != .largeFiles }) {
                            check("Only build output and caches are touched, never source code")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 24)
            }

            Divider().padding(.top, 12)
            HStack {
                if !hasData.isEmpty {
                    Toggle("I understand \(hasData.count) item(s) may hold my data", isOn: $acknowledgedData)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(freedNow > 0 ? "Free \(ByteFormat.string(freedNow))" : "Move to Trash") {
                    finished = true
                    Task { await model.clean(modes: modes) }
                }
                .primaryGlassButton()
                .tint(hasData.isEmpty ? .green : .orange)
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty || (!hasData.isEmpty && !acknowledgedData))
            }
            .padding(16)
        }
    }

    private func tierSection(_ tier: Tier, _ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TierBadge(tier: tier)
                Text(ByteFormat.string(list.reduce(0) { $0 + $1.size })).bold().monospacedDigit()
                Spacer()
                if !list.allSatisfy({ $0.ecosystem == .largeFiles }),
                   list.contains(where: { if case .removePaths = $0.action { return true } else { return false } }) {
                    Picker("Mode", selection: Binding(get: { modes[tier] ?? tier.defaultRemovalMode },
                                                      set: { modes[tier] = $0 })) {
                        Text("Delete now").tag(RemovalMode.delete)
                        Text("Move to Trash").tag(RemovalMode.trash)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Text(list.allSatisfy({ $0.ecosystem == .largeFiles })
                 ? "Your own files. They go to the Trash, so you can put them back until you empty it."
                 : (modes[tier] ?? tier.defaultRemovalMode) == .delete
                 ? "Space is freed immediately. Large files are the exception: they always go to the Trash."
                 : "Undoable, but space is only freed when you empty the Trash.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(list) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        Text(tier == .hasData ? "You will lose: \(item.lossNote)" : item.lossNote)
                            .font(.caption)
                            .foregroundStyle(tier == .hasData ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(ByteFormat.string(item.size)).monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func check(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").font(.callout).foregroundStyle(.primary)
    }

    // MARK: Progress and result

    private var cleaning: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Cleaning…").font(.headline)
            Text(model.cleaningStatus).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func summary(_ s: CleanSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(s.failures.isEmpty ? "Done" : "Done, with \(s.failures.count) problem(s)",
                  systemImage: s.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(s.failures.isEmpty ? Color.green : Color.orange)
            Text("Free space \(ByteFormat.string(s.before)) → \(ByteFormat.string(s.after))")
                .font(.title3)
            if s.trashed > 0 {
                Text("\(ByteFormat.string(s.trashed)) is in the Trash. Empty the Trash to get that space back.")
                    .foregroundStyle(.secondary)
            }
            if !s.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(s.failures.enumerated()), id: \.offset) { _, f in
                            Text("\(f.name): \(f.error)").font(.callout).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
