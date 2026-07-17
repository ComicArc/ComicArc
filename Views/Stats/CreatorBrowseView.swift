import SwiftUI

struct CreatorBrowseView: View {
    @State private var writers:        [CreatorStat] = []
    @State private var pencillers:     [CreatorStat] = []
    @State private var selectedCreator: CreatorStat?  = nil
    @State private var creatorComics:  [Comic]       = []
    @State private var tab: CreatorTab = .writers
    @State private var isLoading       = true

    enum CreatorTab: String, CaseIterable {
        case writers = "Writers"
        case artists = "Artists"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel: creator list
            VStack(spacing: 0) {
                HStack {
                    Text("CREATORS")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Design.brandGold)
                        .kerning(1)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Design.navBackground)

                Rectangle().fill(Design.borderColor).frame(height: 1)

                // Writer / Artist toggle
                HStack(spacing: 0) {
                    ForEach(CreatorTab.allCases, id: \.self) { t in
                        Button(t.rawValue) { tab = t }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(tab == t ? Design.brandBlue.opacity(0.2) : Color.clear)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Design.navBackground)

                Rectangle().fill(Design.borderColor).frame(height: 1)

                let list = tab == .writers ? writers : pencillers
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if list.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.rectangle").font(.largeTitle).foregroundStyle(.quaternary)
                        Text("No \(tab.rawValue.lowercased()) found").foregroundStyle(.secondary).font(.caption)
                        Text("Add creator credits in the metadata editor to see them here.")
                            .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(list) { creator in
                                CreatorListRow(creator: creator, isSelected: selectedCreator?.id == creator.id) {
                                    selectedCreator = creator
                                    loadComics(creator)
                                }
                                Rectangle().fill(Design.borderColor).frame(height: 1)
                            }
                        }
                    }
                }
            }
            .frame(width: 240)
            .background(Design.navBackground)

            Rectangle().fill(Design.borderColor).frame(width: 1)

            // Right panel: comics for selected creator
            if let creator = selectedCreator {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(creator.name)
                                .font(.system(size: 24, weight: .black))
                                .foregroundStyle(.white)
                            Text("\(creator.role) · \(creator.count) issue\(creator.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .background(Design.navBackground)

                    Rectangle().fill(Design.borderColor).frame(height: 1)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(creatorComics) { comic in
                                HStack(spacing: 12) {
                                    MiniComicCard(comic: comic).frame(width: 40, height: 60)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(comic.title).font(.subheadline.bold()).lineLimit(1)
                                        HStack(spacing: 6) {
                                            PublisherBadge(publisher: comic.publisher)
                                            Text(comic.series).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        if let yr = comic.year { Text("\(yr)").font(.caption2).foregroundStyle(.tertiary) }
                                    }

                                    Spacer()

                                    Button("Read") { LibraryViewModel.shared.openReader(comic) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                Rectangle().fill(Design.borderColor).frame(height: 1).padding(.leading, 20)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Design.appBackground)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 48)).foregroundStyle(.quaternary)
                    Text("Select a creator").foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Design.appBackground)
            }
        }
        .task { await load() }
        .onChange(of: tab) { _, _ in selectedCreator = nil; creatorComics = [] }
    }

    private func load() async {
        isLoading = true
        let (w, p) = await Task.detached(priority: .userInitiated) {
            (DatabaseManager.shared.allWriters(), DatabaseManager.shared.allPencillers())
        }.value
        writers = w; pencillers = p; isLoading = false
    }

    private func loadComics(_ creator: CreatorStat) {
        Task.detached(priority: .userInitiated) {
            let comics = DatabaseManager.shared.comicsByCreator(name: creator.name, role: creator.role)
            await MainActor.run { creatorComics = comics }
        }
    }
}

struct CreatorListRow: View {
    let creator:    CreatorStat
    let isSelected: Bool
    let onSelect:   () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(creator.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(creator.count) issue\(creator.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isSelected ? Design.brandBlue.opacity(0.15) : (isHovered ? Design.surfaceBg : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(creator.name), \(creator.count) issue\(creator.count == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
