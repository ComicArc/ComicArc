import SwiftUI

struct ComicPageCoverPicker: View {
    let comic: Comic
    let onPick: (PlatformImage) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a Page as Cover").font(.title3.bold())
                    Text(comic.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding(20)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(0..<max(comic.pageCount, 1), id: \.self) { index in
                        CoverPickerPageCell(comic: comic, index: index) { image in
                            onPick(image)
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 600)
        .background(Design.appBackground)
    }
}

private struct CoverPickerPageCell: View {
    let comic: Comic
    let index: Int
    let onSelect: (PlatformImage) -> Void
    @State private var image: PlatformImage?

    var body: some View {
        Button {
            if let image { onSelect(image) }
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let image {
                        Image(platformImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Design.cardBg)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Design.borderColor, lineWidth: 1))

                Text("Page \(index + 1)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .task(id: index) {
            // Same rationale as the reader filmstrip: a grid of every page in the comic would
            // otherwise decode full-resolution pages through the shared reading-page cache,
            // evicting real reading pages for a picker that only needs small thumbnails.
            PageThumbnailCache.shared.thumbnail(comic: comic, page: index) { image = $0 }
        }
    }
}
