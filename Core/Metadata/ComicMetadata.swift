import Foundation
import ZIPFoundation

/// Everything the scanner learns about a file before it's stored.
struct ParsedComic: Sendable {
    var title: String
    var publisher: String
    var character: String?
    var series: String
    var issueNumber: String?
    var year: Int?
    var month: Int?
    var day: Int?
    var writer: String?
    var penciller: String?
    var storyArc: String?
    var storyArcNumber: String?
    var alternateNumber: String?
    var seriesGroup: String?
    var languageISO: String?
    var volume: String?
    var format: String?
    var hasComicInfo: Bool
    var comicInfoIssueNumber: String?
    var comicInfoSeries: String?
    var comicInfoPublisher: String?
    var folderSeries: String?
    var folderPublisher: String?
    var folderGroup: String?
}

/// Turns a file's location, name and embedded ComicInfo.xml into library metadata.
///
/// Folder layout under a library root:
/// `Series/`, `Publisher/Series/`, `Publisher/Character/Series/`, and deeper layouts keep the
/// in-between folders as a group (`DC/Batman/Classic/Batman (1940)/` → group "Classic").
/// ComicInfo.xml wins over folders for series and publisher; the filename supplies the issue
/// number when ComicInfo.xml doesn't.
enum ComicMetadata {
    static func parse(url: URL, libraryRoot: String) -> ParsedComic {
        let info = ComicInfo.read(from: url)
        let filename = url.deletingPathExtension().lastPathComponent
        let folders = folderComponents(of: url, root: libraryRoot)
        let ciSeries = info["Series"].map(clean)
        let ciPublisher = info["Publisher"].map(normalizePublisher)

        let character: String?
        if let c = folders.character { character = c }
        else if let c = info["Characters"], isCleanCharacterName(c) { character = c }
        else { character = nil }

        let year = info["Year"].flatMap(Int.init) ?? year(in: filename)
        let month = year == nil ? nil : info["Month"].flatMap(Int.init).flatMap { (1...12).contains($0) ? $0 : nil }
        let day = month == nil ? nil : info["Day"].flatMap(Int.init).flatMap { (1...31).contains($0) ? $0 : nil }

        return ParsedComic(
            title: filename,
            publisher: nonEmpty(ciPublisher) ?? nonEmpty(folders.publisher) ?? "Unknown",
            character: character,
            series: nonEmpty(ciSeries) ?? nonEmpty(folders.series) ?? "General",
            issueNumber: nonEmpty(info["IssueNumber"]) ?? issueNumber(in: filename),
            year: year, month: month, day: day,
            writer: info["Writer"], penciller: info["Penciller"],
            storyArc: info["StoryArc"], storyArcNumber: info["StoryArcNumber"],
            alternateNumber: info["AlternateNumber"], seriesGroup: info["SeriesGroup"].map(clean),
            languageISO: info["LanguageISO"], volume: info["Volume"], format: info["Format"],
            hasComicInfo: !info.isEmpty, comicInfoIssueNumber: info["IssueNumber"],
            comicInfoSeries: ciSeries, comicInfoPublisher: ciPublisher,
            folderSeries: folders.series, folderPublisher: folders.publisher, folderGroup: folders.group
        )
    }

    struct Folders: Sendable { var publisher: String?; var character: String?; var group: String?; var series: String? }

    static func folderComponents(of url: URL, root: String) -> Folders {
        let rootURL = URL(fileURLWithPath: root).standardized
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        var folders: [String] = []
        var dir = url.standardized.deletingLastPathComponent()
        while dir.standardized.path.hasPrefix(prefix) && dir.standardized != rootURL {
            folders.insert(dir.lastPathComponent, at: 0)
            dir = dir.deletingLastPathComponent()
        }
        switch folders.count {
        case 0: return Folders()
        case 1: return Folders(series: folders[0])
        case 2: return Folders(publisher: normalizePublisher(folders[0]), series: folders[1])
        case 3: return Folders(publisher: normalizePublisher(folders[0]), character: folders[1], series: folders[2])
        default:
            return Folders(publisher: normalizePublisher(folders[0]), character: folders[1],
                           group: folders[2..<(folders.count - 1)].joined(separator: " / "),
                           series: folders[folders.count - 1])
        }
    }

    /// Most specific pattern first; the bare-number fallback must come last or a year such as
    /// "2020" would be read as the issue number.
    private static let issuePatterns: [NSRegularExpression] = [
        "#(\\d+(?:\\.\\d+)?)", "(?:issue|iss|no\\.?)\\s*(\\d+)", "v\\d+\\s*#(\\d+)", "(?:^|\\s|_)(\\d{1,4})(?:\\s|_|$)",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static func issueNumber(in filename: String) -> String? {
        let range = NSRange(filename.startIndex..., in: filename)
        for regex in issuePatterns {
            if let m = regex.firstMatch(in: filename, range: range), let r = Range(m.range(at: 1), in: filename) {
                return String(filename[r])
            }
        }
        return nil
    }

    /// A "(YYYY)" or "(YYYY-)" year, e.g. "Amazing Spider-Man (2014) #10".
    private static let yearPattern = try! NSRegularExpression(pattern: #"\((19|20)(\d{2})-?\)"#)

    static func year(in filename: String) -> Int? {
        guard let m = yearPattern.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let a = Range(m.range(at: 1), in: filename), let b = Range(m.range(at: 2), in: filename)
        else { return nil }
        return Int(filename[a] + filename[b])
    }

    static func normalizePublisher(_ raw: String) -> String {
        let known = ["dc": "DC", "marvel": "Marvel", "image": "Image", "dark horse": "Dark Horse",
                     "idw": "IDW", "boom": "BOOM!", "dynamite": "Dynamite"]
        let trimmed = clean(raw)
        return known[trimmed.lowercased()] ?? trimmed
    }

    static func isCleanCharacterName(_ s: String) -> Bool {
        !s.contains(",") && !s.contains("[") && !s.contains("(") && s.count <= 60
    }

    private static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !clean(s).isEmpty else { return nil }
        return s
    }
}

/// Reads and writes the ComicInfo.xml embedded in CBZ files.
enum ComicInfo {
    static let readKeys: Set<String> = [
        "Series", "Title", "IssueNumber", "Publisher", "Writer", "Penciller", "Year", "Month", "Day",
        "StoryArc", "LanguageISO", "Characters", "AlternateNumber", "StoryArcNumber", "SeriesGroup",
        "Volume", "Format", "Number",
    ]
    /// Caps decompression so a malformed entry can't exhaust memory.
    private static let maxSize: UInt64 = 5 * 1024 * 1024

    static func read(from url: URL) -> [String: String] {
        guard url.pathExtension.lowercased() == "cbz",
              let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil),
              let entry = archive.first(where: { $0.path.lowercased().hasSuffix("comicinfo.xml") }),
              entry.uncompressedSize <= maxSize else { return [:] }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        guard let root = try? XMLDocument(data: data).rootElement() else { return [:] }
        var result: [String: String] = [:]
        for key in readKeys {
            if let v = root.elements(forName: key).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !v.isEmpty { result[key] = v }
        }
        // The ComicInfo standard calls the issue number <Number>; some taggers write <IssueNumber>.
        if result["IssueNumber"] == nil, let n = result["Number"] { result["IssueNumber"] = n }
        return result
    }

    /// Writes `fields` into the CBZ's ComicInfo.xml, preserving any fields not being changed.
    static func write(_ fields: [String: String?], to url: URL) throws {
        guard url.pathExtension.lowercased() == "cbz" else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let archive = try Archive(url: url, accessMode: .update, pathEncoding: nil)
        let existing = archive.first(where: { $0.path.lowercased().hasSuffix("comicinfo.xml") })
        var doc = XMLDocument(rootElement: XMLElement(name: "ComicInfo"))
        if let existing {
            var data = Data()
            _ = try archive.extract(existing) { data.append($0) }
            if let parsed = try? XMLDocument(data: data), parsed.rootElement() != nil { doc = parsed }
            try archive.remove(existing)
        }
        guard let root = doc.rootElement() else { return }
        for (key, value) in fields {
            root.elements(forName: key).forEach { $0.detach() }
            if let value, !value.isEmpty { root.addChild(XMLElement(name: key, stringValue: value)) }
        }
        let xml = doc.xmlData(options: [.nodePrettyPrint])
        try archive.addEntry(with: existing?.path ?? "ComicInfo.xml", type: .file,
                             uncompressedSize: Int64(xml.count), compressionMethod: .deflate) { position, size in
            xml.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}

/// Filename cleanup: underscores to spaces, whitespace collapsed, a redundant second year removed.
/// It never rebuilds a name from metadata, so the result can't contradict the file.
enum FilenameCleanup {
    private static let duplicateYear = try! NSRegularExpression(pattern: #"\((\d{4})(?:-\d{0,4})?\)\s+\(\d{4}\)"#)

    static func cleaned(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        var name = (filename as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = duplicateYear.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name),
                                                      withTemplate: "($1)")
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    static func needsCleanup(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return cleaned(name) != name
    }
}
