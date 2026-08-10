import Foundation
import CoreGraphics

final class PDFDocument: ComicDocument, @unchecked Sendable {
    private let document: CGPDFDocument

    init(path: String) throws {
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let doc = CGPDFDocument(provider) else {
            throw ComicDocumentError.openFailed
        }
        self.document = doc
    }

    var pageCount: Int { document.numberOfPages }

    func pageSource(index: Int) throws -> PageSource {
        guard index >= 0, index < document.numberOfPages,
              let page = document.page(at: index + 1) else { throw ComicDocumentError.pageOutOfRange }
        return .pdfPage(page)
    }

    func close() {}
}
