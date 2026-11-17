import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showAllTags = false

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.sidebar }, set: { if let s = $0 { model.sidebar = s } })) {
            Section("Library") {
                row(.home, "books.vertical.fill")
                row(.continueReading, "book.fill", badge: model.inProgressCount)
                row(.favorites, "heart.fill")
                row(.paths, "point.topleft.down.to.point.bottomright.curvepath.fill")
                row(.highlights, "star.fill")
            }
            if !model.publishers.isEmpty {
                Section("Publishers") {
                    ForEach(model.publishers, id: \.self) { p in
                        Label {
                            Text(p)
                        } icon: {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.publisherColor(p)).frame(width: 12, height: 12)
                        }
                        .tag(SidebarItem.publisher(p))
                    }
                    .onMove { from, to in
                        var list = model.publishers
                        list.move(fromOffsets: from, toOffset: to)
                        model.perform { try await $0.reorderPublishers(list) }
                    }
                }
            }
            if !model.tags.isEmpty || !model.eras.isEmpty {
                Section("Tags") {
                    ForEach(model.eras, id: \.name) { e in
                        Label("#\(e.name)", systemImage: "tag.fill").badge(e.count).tag(SidebarItem.era(e.name))
                            .help("Every comic in a “\(e.name)” folder")
                    }
                    ForEach(model.tags.prefix(12)) { t in
                        Label("#\(t.name)", systemImage: "tag").badge(t.count).tag(SidebarItem.tag(t.name))
                    }
                    if !model.tags.isEmpty {
                        Button("Manage Tags…") { showAllTags = true }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.caption)
                    }
                }
            }
            Section("Insights") {
                row(.stats, "chart.bar.fill")
                row(.health, "stethoscope", badge: model.healthAlerts)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom) { ScanFooter() }
        .sheet(isPresented: $showAllTags) { TagManagerView() }
    }

    private func row(_ item: SidebarItem, _ icon: String, badge: Int = 0) -> some View {
        Label(item.title, systemImage: icon).badge(badge).tag(item)
    }
}

/// Scan progress and results at the bottom of the sidebar.
private struct ScanFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.scan.running {
                ProgressView(value: Double(model.scan.done), total: Double(max(1, model.scan.total)))
                    .tint(Theme.accent)
                Text(model.scan.total > 0 ? "Scanning \(model.scan.done) of \(model.scan.total)" : "Scanning…")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            } else if let warning = model.scan.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(4)
                Button("Try Again") { model.rescan() }.controlSize(.small)
            } else if let message = model.scan.message {
                Label("Library updated: \(message)", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, model.scan.running || model.scan.warning != nil || model.scan.message != nil ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
