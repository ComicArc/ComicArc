# Changelog

All notable changes to ComicArc are documented here.

---

## [2.1.0] — 2026-07-17

### Library
- Possible Duplicates view flags comics sharing the same publisher, series, and issue number (a common result of a rescan or re-rip under a different filename), with a one-click delete per duplicate
- Bulk-select mode gains Reassign…, correcting series/publisher across multiple selected issues at once instead of one at a time
- Renaming a series to a name that already exists now asks for confirmation instead of silently merging the two series' issues
- Manual title/series/publisher/character edits are no longer overwritten by folder-derived metadata reparsing
- Backup export/import now actually covers everything it claims to: tags, reviews, bookmarks, and reading orders, not just ratings/favorites/progress

### iPad
- Real folder-based library scanning: choose a library folder from Settings and ComicArc scans it (including subfolders) instead of importing one file at a time
- The app rescans automatically whenever it returns to the foreground, the closest practical approximation of auto-detecting new files without a Files-app-level file-watching API
- Settings now has library folder management and the same backup export/import as macOS
- CBR files are no longer offered for import on iPad — CBR extraction depends on a command-line tool unavailable in the iOS sandbox, so an imported CBR would previously show 0 pages with no explanation

---

## [2.0.0] — 2026-07-17

### Native Rewrite
ComicArc has been completely rebuilt from the ground up as a native SwiftUI application. The previous Flask + PyWebView implementation (see the 1.x entries below) has been fully replaced.

- Native SwiftUI app for macOS 14+ (Apple Silicon), replacing the Python/PyWebView build — no more bundled Python runtime, no Windows build
- New iPad app with a 3-column navigation layout, touch-optimized reader, and document-picker based import
- SQLite accessed directly via the C API instead of through a Flask API layer
- Native file-system watching (FSEvents) for automatic library updates on macOS
- Full VoiceOver accessibility pass and macOS keyboard shortcut coverage
- Local unit test suite covering navigation state and core view-model logic

### Compatibility note
Windows is no longer supported. The 1.x Windows/macOS Python builds are superseded by this native rewrite; there is no migration path for 1.x library data.

---

## [1.1.0] — 2026-05-12

### Series View
- Library now defaults to a series card view — one card per series, grouped by character and run
- Each card shows the cover of the first issue, character name, series name, issue count, and a Done/Reading badge
- Click any series card to see all issues inside
- Breadcrumb navigation to jump back to the series grid
- Toggle between series view and flat all-comics view

### Bug Fixes
- Fixed comics getting lost when a character's books span both 2-level and 3-level folder layouts (e.g. Robin issues filed directly in `DC/Robin/` were invisible after clicking the Robin card)
- Same fix covers Manga series and any character with no sub-series folders — all books now appear
- Fixed the publisher filter locking to a single publisher after clicking a character card from the All view — back button now returns to the full library
- Breadcrumb now shows the full 3-level path (Characters → Batman → New 52) when drilling to issues, with each level clickable

### Library Improvements
- Series names now reflect the actual run name only (e.g. "New 52" instead of "Superman — New 52") — character context is shown separately on the card
- Character field extracted from folder structure and stored per comic for accurate grouping

---

## [1.0.0] — 2026-05-08

First public release for macOS and Windows.

### App
- Native app bundle — no Python or Terminal required
- Built with PyWebView + PyInstaller; runs fully offline
- Native folder-picker dialog for choosing library location
- All data stored locally (database, covers, config)
- Auto-scans library folder on every launch

### Onboarding
- First-launch wizard: choose folder → live scan progress → pick default reading mode
- Reset Setup in Settings re-runs the wizard without losing library data

### Library
- Drag-and-drop and folder import for CBZ, CBR, PDF, JPG, JPEG, PNG
- Grid view with cover thumbnails, reading progress bars, and star ratings
- Publisher tabs, tag chips, and free-text search filtering
- Continue Reading shelf on the library home page
- Favorites and Want to Read reading queue
- Metadata editor — title, series, publisher, issue number, tags
- Bulk select — shift-click range select; mark read/unread, add to list, delete
- Manual drag-and-drop reordering
- Delete with confirmation (original file stays on disk)

### Reader
- Page-by-page, vertical scroll, and double-page spread modes
- Zoom up to 5× with click-and-drag panning
- Autoplay — auto-advances every 10 seconds
- Auto-hiding toolbar, keyboard shortcuts, touch swipe
- Progress saves automatically on every page turn and on close

### Narrative Runs
- Build ordered reading lists spanning multiple series and publishers
- Drag-and-drop reordering, per-issue notes and ratings
- Resume button finds the first unfinished issue automatically
- Auto-advances to the next comic at end of each issue

### Stats
- Total comics, pages read, favorites, in-progress count, run count
- Publisher breakdown, top series, recently read history

### Settings
- Change library folder, switch reader mode, CBR support (unar/7-Zip), JSON backup export

### App
- Native macOS app bundle (.app) — no Python or Terminal required
- Built with PyWebView + PyInstaller; runs fully offline
- Native folder-picker dialog for choosing library location
- All data stored in `~/Library/Application Support/ComicArc/` (database, covers, config)
- Auto-scans library folder on every launch to pick up newly added files

### Onboarding
- First-launch wizard: choose folder → live scan progress → pick default reading mode
- Config persisted to `config.json` (library path, reader mode, onboarding flag)
- Reset Setup in Settings re-runs the wizard without losing any library data

### Library
- Drag-and-drop and folder import for CBZ, CBR, PDF, JPG, JPEG, PNG
- Grid view with cover thumbnails, reading progress bars, and star ratings
- Publisher tabs, tag chips, and free-text search (title / series) filtering
- **Continue Reading** shelf on the library home page
- Favorites and **Want to Read** reading queue
- Metadata editor — edit title, series, publisher, issue number, tags per comic
- Bulk select mode — shift-click range select; mark read/unread, add to reading list, delete
- Manual drag-and-drop reordering (sort: Manual Order)
- Mark Unread button on comic detail page
- Delete with confirmation (removes from library; original file stays on disk)

### Reader
- Page-by-page navigation — keyboard (`←` `→` `Space` `Home` `End`) and touch swipe
- Vertical scroll mode for manga-style reading
- Double-page spread mode
- Zoom up to 5× with click-and-drag panning
- Autoplay — auto-advances every 10 seconds with a visible countdown bar (`A`)
- Auto-hiding toolbar — fades after 3 seconds of inactivity, returns on mouse move
- Press `M` to manually show/hide toolbar at any time
- In-reader keyboard shortcut reference (`?` button or `?` key)
- Default reader mode preference (page / scroll) saved from onboarding and settings
- Progress saves automatically on each page turn and immediately on window close
- Rating modal pre-fills existing rating when reopened
- Ratings from the detail page preserve any review written in the reader

### Narrative Runs
- Create ordered reading lists spanning multiple series and publishers
- Add any library comic to a run
- Drag-and-drop reordering within a run
- Per-issue notes, ratings, and favorites
- Resume button finds the first unfinished issue automatically
- Auto-advances to next comic at end of each issue

### Stats
- Total comics, pages read, favorites, in-progress count, and run count
- Completion tracking (finished / in-progress / unread)
- Publisher breakdown with visual bar chart
- Top series by issue count
- Recently read history

### Settings
- Change library folder and trigger rescan from within the app
- Switch default reader mode (page / scroll)
- CBR support: one-click "Install via Homebrew" with live install log
- Export full library as JSON backup (comics, progress, ratings, tags, runs, reading list)
- Reset Setup — re-run onboarding without losing data
- Clear Library — remove all app data (files stay on disk)

### Technical
- Flask + SQLite backend wrapped in a PyWebView native window
- Background scanner thread with file-signature deduplication (filename + size)
- Scanner never overwrites user-edited metadata on re-scan
- `ON DELETE CASCADE` foreign keys for clean data removal
- Bulk API endpoints for delete, mark-read, mark-unread, reading-list
- Cover thumbnails cached to disk; served with 24-hour cache headers
- PyInstaller bundle excludes personal dev-cache files — clean 70 MB distribution
- No accounts, no cloud, no external network requests
