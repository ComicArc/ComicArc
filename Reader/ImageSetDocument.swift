import Foundation

/// A single standalone image file treated as a one-page comic -- matches the existing behavior
/// for loose .jpg/.jpeg/.png files dropped directly into a library folder.
final class ImageSetDocument: ComicDocument {
    private let path: String

    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw ComicDocumentError.fileUnavailable }
        self.path = path
    }

    var pageCount: Int { 1 }

    func pageSource(index: Int) throws -> PageSource {
        guard index == 0 else { throw ComicDocumentError.pageOutOfRange }
        guard let data = FileManager.default.contents(atPath: path) else { throw ComicDocumentError.openFailed }
        return .imageData(data)
    }

    func close() {}
}
