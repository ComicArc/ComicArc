import SwiftUI

struct ReadingOrderManagerView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var rows: [DatabaseManager.SeriesTriageRow] = []
    @State private var isLoading = true
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Design.borderColor).frame(height: 1)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Design.appBackground)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Order Health").font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(Design.textPrimary)
                    Text("Which series have issues placed with low confidence, worst first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Picker("Reading Order Mode", selection: $vm.readingOrderMode) {
                    ForEach(DatabaseManager.ReadingOrderMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu).frame(maxWidth: 260)

                Spacer()

                Button(isWorking ? "Working…" : "Recompute All") { recomputeAll() }
                    .buttonStyle(.bordered).disabled(isWorking)

                Button(isWorking ? "Working…" : "Clear All Overrides") { clearAllOverrides() }
                    .buttonStyle(.bordered).foregroundStyle(.red).disabled(isWorking)
            }
        }
        .padding(20)
        .background(Design.navBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Everything's placed with full confidence").font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.triageKey) { row in
                    SeriesTriageRowView(row: row)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        rows = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.readingOrderTriageSummary().filter { $0.minConfidence < 100 || $0.overrideCount > 0 }
        }.value
        isLoading = false
    }

    private func recomputeAll() {
        isWorking = true
        Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
            await MainActor.run { isWorking = false; vm.reload() }
            await load()
        }
    }

    private func clearAllOverrides() {
        isWorking = true
        Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.clearAllReadingOrderOverrides()
            DatabaseManager.shared.recomputeReadingOrder(mode: DatabaseManager.ReadingOrderMode.current)
            await MainActor.run { isWorking = false; vm.reload() }
            await load()
        }
    }
}

private extension DatabaseManager.SeriesTriageRow {
    var triageKey: String { "\(publisher):\(series)" }
}

private struct SeriesTriageRowView: View {
    let row: DatabaseManager.SeriesTriageRow
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Button {
            vm.destination = .publisher(row.publisher)
            vm.selectedSeries = row.series
            vm.showSeriesManager = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.series).font(.system(size: 13, weight: .semibold)).foregroundStyle(Design.textPrimary)
                    Text("\(row.publisher) · \(row.issueCount) issues").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if row.overrideCount > 0 {
                    Label("\(row.overrideCount)", systemImage: "pin.fill")
                        .font(.caption2.bold()).foregroundStyle(Design.brandGold)
                }
                if row.flaggedCount > 0 {
                    Label("\(row.flaggedCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold()).foregroundStyle(.orange)
                }
                Text("\(row.minConfidence)%")
                    .font(.caption.bold())
                    .foregroundStyle(row.minConfidence < 70 ? .red : (row.minConfidence < 85 ? .orange : .secondary))
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        Divider().padding(.leading, 20)
    }
}
