# Changelog

All notable changes to ComicArc are documented here, starting from the 1.0 launch.

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
