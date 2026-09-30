# Changelog

All notable changes to ComicArc are documented here, starting from the 1.0 launch.

---

## [Unreleased]

Work since the 1.0.0 launch, not yet tagged as a new release.

### Scope reduction
ComicArc is refocused on being a library and a reader. Removed:
- Ratings and reviews (comics, Reading Paths, Tier Lists) and the Diary built on them.
- Intelligent reading order (automatic annual/special placement, the order-basis picker, series continuation links, and the Reading Order Suggestions review screen). Series sort by issue number with specials after regular issues; manual Series Manager orders are kept.
- The Recommended For You and On This Day home shelves.
- Character themes, themed backgrounds and hover effects, decorative illustrations and animations, emojis, and the sidebar streak banner.
- The test suite and debug-only developer tools.
- Tier Lists, Saved Views, and the offline comics database (with Fix Match). The 112 MB database download is no longer used.
- The separate tutorial overlay (its essentials are now on the setup wizard's final screen) and the obsolete "install unar" setup step.
- Unused database tables and columns from removed features, dropped by a one-time migration.

### Consolidated
- **Stats**: Statistics, History, and Year in Review are one screen (History is a tab).
- **Library Health**: the health report, Duplicates, Needs Review, Clean Up Filenames, CBR-to-CBZ conversion, and Resync live on one screen instead of a pop-up sheet, two sidebar sections, and Settings buttons.

### Changed
- Duplicate detection only flags exact file-name matches, byte-identical cover thumbnails, or byte-identical files.
- Clicking a character or category always opens its own page, even when it holds a single series.
- The macOS reader fits the page to the window, scrolls naturally when zoomed, and only shows its controls when the pointer is near the top or bottom edge.
- The Reading List is now a built-in Reading Path named "Reading List" (existing entries are moved over once, in the order they were added), so it can be reordered and annotated like any path.
- Add many comics to a Reading Path at once: **Add to Path** in the bulk-select bar, **Add Series to Reading Path** on series cards, and **Add to Reading Path** on iPad comic tiles — each can create a new path on the spot, and the add can be undone.
- The Mac app scans the library once per launch; the live folder watcher covers changes after that.
- Reading Paths moved into the sidebar's main Library section. Navigate menu shortcuts: Reading Paths ⌘4, Stats ⌘5, Highlights ⌘6. Select All in selection mode is ⇧⌘A; Delete Selected (⌘⌫) now always asks first.
- New cover thumbnails decode straight at thumbnail size (much faster first scans) and are saved smaller.
- The health report no longer lists every comic without ComicInfo.xml.
- Sparkle's version is pinned via a tracked Package.resolved.

### Polish
- Reader: Space / ⇧Space and Page Down / Page Up turn pages; Escape closes the page filmstrip before the reader.
- Toolbar: removed the duplicate Settings button and the Resync button (still in Library Health, Settings, and the menu bar); Scan uses a refresh icon so it no longer looks like search.
- Discover shows Stats, Highlights, and Library Health directly instead of hiding two behind "More".
- Issue page: "Add to Path" opens the path menu directly, and "Appears in Reading Paths" entries open that path.
- Read Next suggests the next issue of series you've recently finished an issue of, instead of only series with a favorited issue.
- Reading Paths can be deleted from the list's right-click menu.
- Removed the obsolete "CBR Support (requires unar)" setting — CBR support is bundled and always on.
- Updated outdated wording in Settings (Sync, backup contents) and several tooltips.

### Fixed
- Bulk Mark Read/Unread and Mark All as Read now actually set/clear finished status.
- Reading Path and series/character progress counts use the finished flag, matching the rest of the app.
- The iPad reader no longer flashes its controls when a comic opens or on every page turn; tap the middle of the page to show them.
- The Now Reading comic no longer also appears as the first Continue Reading card right below it.
- Read Next cards no longer show "p. 1" and an empty progress bar for issues you haven't started, and their menu says "Read".
- Marking a comic read/unread updates the home shelves right away.
- The sidebar's Continue Reading count is the real total (it stopped at 8).
- Reading Path rows number continuously after a comic is removed, and open with a double-click.
- Adding a single comic to a Reading Path confirms it (with Undo, or "Already in …"), and updates the path's count and the issue page right away.
- Deleting a Reading Path's undo message says "Reading Path", not "Reading order".
- The iPad and visionOS targets build again (missing BackupService membership, an actor-isolation error in iPad import, and UIScreen use on visionOS).

### Platform
- Added a third native target, **ComicArcVision**, for visionOS — reuses the iPad interface.

### Sync & Sharing
- Peer sync: local, cloud-free sync between a Mac and an iPad on the same network over MultipeerConnectivity, matched by file hash. Syncs reading progress, finished status, and Reading Paths (merged by title, never deleted). Tags and manual issue orders stay local.
- Share cards: export a shareable image card for a Tier List, Reading Path, or Year in Review recap.

### Reader
- Reworked the reader's end-of-issue/end-of-series flow with continue and completion cards.

### Architecture
- Split `DatabaseManager`/`LibraryViewModel` into focused files and hardened concurrency.

### Fixes & polish
- Simplified the file renamer, fixed cover cropping, and stopped Sparkle from downgrading dev builds.
- Reader UX and accessibility fixes from a full deep-audit pass.
- Redesigned per-series library theming as a restrained, performance-conscious atmosphere/interaction system.
- Consolidated several duplicated code paths (CBZ/PDF cover extraction, Reading Path/Tier List row mapping, shared empty-state and star-rating components) found in a codebase audit.

---

## [1.0.0] — 2026-07-28

First public release.

### Library
- Folder-based library scanning, with support for multiple library folders combined into one logical library
- Publisher / Character / Series / Issue browsing, derived from your existing folder structure
- Bulk select: mark read/unread, delete, reassign series/publisher, or add to a Reading Path
- Issue detail view: metadata editing, tags, reviews, inline ratings, manual comics-database match correction
- Series Manager: reorder, rename, or set a custom cover for a series
- Possible Duplicates and Metadata Conflicts review screens
- Rename Files: batch and per-file filename cleanup (underscores to spaces, collapsed whitespace)

### Reader
- macOS: in-window reader, page and continuous-scroll modes, double-page spread, zoom/pan, page scrubber, autoplay, bookmarks, color filters, RTL mode
- iPadOS: full-screen touch reader with swipe, pinch-zoom, tap-to-turn, and autoplay

### Intelligent reading order
- Automatic placement of annuals, specials, and out-of-sequence issues using legacy numbering, cover date, and story-arc adjacency
- Manual overrides that always win and survive rescans
- Series continuation linking for relaunches and legacy renumbering

### Offline comics database
- One-time optional download for accurate annual/special placement, fully offline afterward
- Manual "Fix Match" picker for correcting a wrong or missing match, protected from being overwritten by later automatic rescans

### Reading Paths, Diary, Tier Lists & Favorite Moments
- Reading Paths: ordered, curated comic collections spanning any number of series, with notes, rating/review, and Resume
- Diary: every rating and reread logged as its own dated entry
- Tier Lists: S/A/B/C/D/F ranking via drag-and-drop
- Favorite Moments: bookmarked reader pages saved to a browsable gallery

### Stats & History
- Reading totals, publisher breakdown, reading history timeline, and an annual Year in Review recap

### Platform
- Native macOS and iPadOS apps sharing one core, each built for its own platform
- Full VoiceOver support, native keyboard shortcuts, native drag-and-drop
- Local JSON backup and restore covering the entire library
- No account, no telemetry, no network dependency beyond the one optional database download
