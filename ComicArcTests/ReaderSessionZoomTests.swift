import Testing
import Foundation
@testable import ComicArc

/// Exercises `ReaderSession`'s zoom/pan model through its public API. Constructing a session
/// touches `DatabaseManager.shared.seriesReaderPrefs` (a read-only lookup for per-series reader
/// prefs) -- using a random series/publisher per test keeps this from ever matching a real
/// library entry, and none of the zoom/pan methods under test write anything back, so this is
/// safe against the live singleton without needing the isolated-`DatabaseManager` fixture the
/// DB-mutating suites use.
@MainActor
struct ReaderSessionZoomTests {
    private func makeSession() -> ReaderSession {
        let comic = Comic(
            id: 1, title: "Test", filePath: "/tmp/test.cbz", publisher: "Zoom Test Pub \(UUID())",
            character: nil, series: "Zoom Test Series \(UUID())", issueNumber: "1", pageCount: 20,
            writer: nil, penciller: nil, year: nil, volume: nil, format: nil, storyArc: nil,
            languageIso: nil, notes: nil, addedAt: "", deletedAt: nil, position: 0, fileHash: nil
        )
        let session = ReaderSession(comic: comic)
        session.updateViewport(size: CGSize(width: 1000, height: 1000), screenScale: 2.0)
        return session
    }

    @Test func startsUnzoomedAtCenter() {
        let session = makeSession()
        #expect(session.zoomLevel == 1.0)
        #expect(session.zoomAnchor == .center)
        #expect(session.isZoomed == false)
        #expect(session.panOffsetInPoints == .zero)
    }

    @Test func setZoomClampsToUpperBound() {
        let session = makeSession()
        session.setZoom(50.0)
        #expect(session.zoomLevel == 5.0)
    }

    @Test func setZoomBelowThresholdResetsToIdentity() {
        let session = makeSession()
        session.setZoom(2.0)
        session.setZoom(1.02) // below the 1.05 snap-back threshold
        #expect(session.zoomLevel == 1.0)
        #expect(session.zoomAnchor == .center)
        #expect(session.isZoomed == false)
    }

    @Test func setZoomWithCenteredAnchorProducesNoOffset() {
        let session = makeSession()
        session.setZoom(2.0, anchorInViewport: CGPoint(x: 500, y: 500)) // dead center of the 1000x1000 viewport
        #expect(session.zoomLevel == 2.0)
        #expect(session.panOffsetInPoints == .zero)
    }

    @Test func setZoomAnchorFarFromCenterClampsToValidPanRange() {
        let session = makeSession()
        // Tapped at the viewport's far-right edge (x: 1000 of 1000) at 2x zoom -- the raw anchor
        // (1.0) is outside what's actually reachable (maxDelta = (2-1)/(2*2) = 0.25, so the valid
        // range is [0.25, 0.75]) and should clamp to 0.75, not the raw tap location.
        session.setZoom(2.0, anchorInViewport: CGPoint(x: 1000, y: 500))
        #expect(session.zoomAnchor.x == 0.75)
        #expect(session.zoomAnchor.y == 0.5)
        // offset = (0.5 - anchor) * viewportSize * zoomLevel
        #expect(session.panOffsetInPoints.width == -500)
        #expect(session.panOffsetInPoints.height == 0)
    }

    @Test func panDeltaMovesAnchorAndClampsAtEdge() {
        let session = makeSession()
        session.setZoom(2.0) // anchor starts at .center (0.5, 0.5)
        // Drag far enough right that the unclamped anchor would go negative.
        session.pan(anchorDelta: CGSize(width: 2000, height: 0))
        #expect(session.zoomAnchor.x == 0.25) // clamped lower bound at 2x zoom
    }

    @Test func resetZoomReturnsToIdentityAndClearsPan() {
        let session = makeSession()
        session.setZoom(3.0, anchorInViewport: CGPoint(x: 900, y: 900))
        session.resetZoom()
        #expect(session.zoomLevel == 1.0)
        #expect(session.zoomAnchor == .center)
        #expect(session.panOffsetInPoints == .zero)
    }

    @Test func zoomLevelAtExactlyOneIsNeverConsideredZoomed() {
        let session = makeSession()
        session.setZoom(1.0)
        #expect(session.isZoomed == false)
    }
}
