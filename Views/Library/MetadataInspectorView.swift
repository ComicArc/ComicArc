import SwiftUI

/// Read-only diagnostic panel: exactly why ComicArc placed a comic where it did, and what
/// metadata it actually found. Reachable from a comic's context menu or (in IssueDetailPage)
/// its toolbar, since a right-click surface doesn't exist on that page.
struct MetadataInspectorView: View {
    let comicId: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var info: DatabaseManager.MetadataInspectorInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Metadata Inspector").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)

            if let info {
                Form {
                    Section("What ComicArc Uses") {
                        row("Title", info.comic.title)
                        row("Publisher", info.comic.publisher)
                        row("Series", info.comic.series)
                        row("Character", info.comic.character)
                        row("Issue Number", info.comic.issueNumber)
                    }

                    Section("Reading Order") {
                        row("Comic Type", info.comicType.rawValue)
                        row("Legacy Number", info.legacyNumber.map { formatNumber($0) })
                        row("Position", "\(info.comic.readingOrderPosition ?? info.comic.position)")
                        row("Confidence", info.comic.readingOrderConfidence.map { "\($0)%" })
                        row("Reason", info.comic.readingOrderReason)
                    }

                    Section("ComicInfo.xml") {
                        if info.hasComicInfo == false {
                            Text("No ComicInfo.xml metadata was found for this file.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if info.hasComicInfo == nil {
                            Text("Scanned before ComicArc tracked whether ComicInfo.xml was present — resync to find out.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        row("Writer", info.comic.writer)
                        row("Penciller", info.comic.penciller)
                        row("Story Arc", info.comic.storyArc)
                        row("Story Arc Number", info.storyArcNumber)
                        row("Volume", info.comic.volume)
                        row("Format", info.comic.format)
                        row("Series Group", info.seriesGroup)
                        row("Alternate Number", info.alternateNumber)
                        row("ComicInfo Issue Number", info.comicInfoIssueNumber)
                        row("Publication Date", publicationDate(info))
                    }

                    if info.comic.gcdMatchConfidence != nil {
                        Section("Offline Comics Database Match") {
                            row("Matched Series", info.comic.gcdSeriesName)
                            row("Matched Issue", info.comic.gcdIssueNumber)
                            row("Confidence", info.comic.gcdMatchConfidence.map { "\($0)%" })
                            row("Reason", info.gcdMatchReason)
                        }
                    }

                    Section("Duplicate Matching") {
                        if info.duplicateMatchCount > 0 {
                            row("Other Matching Copies", "\(info.duplicateMatchCount)")
                            Text("Sharing the same publisher, series, issue number, and comic type.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No other comic shares this publisher, series, issue number, and comic type.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Section("File") {
                        row("Path", info.comic.filePath)
                        row("File Hash", info.comic.fileHash)
                        row("Pages", "\(info.comic.pageCount)")
                    }
                }
                .formStyle(.grouped)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 480, height: 600)
        .task { info = DatabaseManager.shared.metadataInspectorInfo(comicId: comicId) }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
            .font(.caption)
        }
    }

    private func publicationDate(_ info: DatabaseManager.MetadataInspectorInfo) -> String? {
        guard let year = info.comic.year else { return nil }
        var parts = ["\(year)"]
        if let month = info.coverMonth { parts.append(String(format: "%02d", month)) }
        if let day = info.coverDay { parts.append(String(format: "%02d", day)) }
        return parts.joined(separator: "-")
    }

    private func formatNumber(_ n: Double) -> String {
        n == n.rounded(.towardZero) ? String(Int(n)) : String(n)
    }
}
