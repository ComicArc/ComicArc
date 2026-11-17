# ComicArc

**A native comic library and reader for the Mac. No account, no cloud, no subscription.**

Point it at the folder where your comics already live, and it builds a fast, local library around the files you already have. Nothing gets uploaded, nothing gets renamed without asking, and nothing needs an internet connection to keep working.

[![Build & Release](https://github.com/ComicArc/ComicArc/actions/workflows/release.yml/badge.svg)](https://github.com/ComicArc/ComicArc/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**[Download the latest macOS release](https://github.com/ComicArc/ComicArc/releases/latest)**

---

## Why ComicArc exists

Most comic readers want you to hand your library over to them — import it into their format, let a background service watch your files, or nag you toward a subscription eventually. ComicArc doesn't do any of that.

- **Your folder is the database.** ComicArc reads Publisher / Character / Series / Issue straight from the folder structure you already built. It never renames, moves, or rewrites a file unless you explicitly ask it to.
- **Genuinely native.** 100% SwiftUI on top of AppKit/UIKit — real keyboard shortcuts, full VoiceOver support, native drag-and-drop, and the platform's own navigation idioms, not a web view wearing a costume.
- **Fast because it's simple.** SQLite through the raw C API, no ORM, no network round-trip between you and your own library.
- **Offline, always.** No account, no telemetry, nothing phoning home, nothing to download.
- **Mac-first.** Built for keyboard, trackpad and large screens. Reading progress and Reading Paths sync with the companion iPad app over your local network.
- **Library and reader first.** Plus Reading Paths: build your own run from the comics you own — mix and match across series like a personal playlist.

---

## Getting started

### macOS

Requires macOS 14 (Sonoma) or later. Apple Silicon native.

1. Download and unzip `ComicArc.app.zip` from [the latest release](https://github.com/ComicArc/ComicArc/releases/latest).
2. Move **ComicArc.app** to `/Applications`.
3. **Right-click → Open** the first time, to get past Gatekeeper (see below for why).
4. The welcome tour walks you through choosing your comics folder, the first scan, picking a theme and a few shortcuts. You can replay it any time from **Help › Welcome Tour**.

No Homebrew, no Terminal, no config files. CBR support is bundled.

#### "ComicArc is damaged and can't be opened"

This is Gatekeeper reacting to an unnotarized app, not actual damage. Run this once and relaunch:

```sh
xattr -cr /Applications/ComicArc.app
```

---

## What it does

### Library

- **Multiple library folders.** Point ComicArc at more than one folder — a NAS share and a local drive, say — and it treats them as one combined library. Add or remove folders any time from Settings.
- **Publisher / Character / Series / Issue**, read from your folder structure and browsable from the sidebar, with Back/Forward (⌘[ ⌘], mouse side buttons) and a clickable breadcrumb trail.
- **Era tags** come from your folders: comics in a `Classic` or `Modern` folder (or any folder between character and series) are tagged automatically and listed under Tags.
- **Quick Open (⌘K)**: type a few letters to jump to any series, comic, Reading Path or screen.
- **Home** shows what you're reading, Up Next, Recently Added, and a Surprise Me pick for a series you haven't started.
- Cover thumbnails with inline progress bars; **Continue Reading** surfaces whatever you're mid-issue on.
- **Search** matches every word you type against the whole folder hierarchy (publisher, character, folder groups such as "Classic" or "Modern", series), plus title, issue number, year, credits, story arc, notes and tags, so "batman classic" narrows to exactly those comics. While the field is empty it suggests recent searches, eras and publishers; as you type it suggests matching series and characters, and results show matching series first. On an issue's page, click its group, year or credits to see everything that shares them.
- Bulk select: mark read/unread, add to a Reading Path (or the Reading List), delete, or reassign series/publisher across many issues at once.
- **Issue detail**: edit metadata, tag it, or add it to a Reading Path.
- **Series Manager**: reorder issues in a series (your order survives rescans), rename it, or set a custom cover. Otherwise issues sort by issue number, with annuals and specials after the regular issues.
- **Library Health** — one screen for maintenance:
  - a health report (issue-number gaps, duplicate #1s, mixed volumes, unreadable files). Large jumps such as legacy renumbering (#441 → #500) aren't reported as missing issues,
  - **Duplicates**: comics with the exact same file name or the exact same cover thumbnail (byte-identical copies included); matching title, series, or issue number alone never counts,
  - **Needs Review**: ComicInfo.xml values that disagree with how a comic is filed, never silently overwritten,
  - tools to clean up filenames, convert CBR to CBZ (macOS), and resync the library.
- **Clean Up Filenames**: tidies messy filenames in bulk — underscores become spaces, repeated spaces collapse to one. You see every change before it happens, and can undo the whole batch.

### Reader

macOS opens the reader right inside the main window — no separate floating window, no chrome, just the page.

**macOS** — page or continuous-scroll mode, pages fit the window by default, pinch/double-click zoom to 5x with normal trackpad/mouse scrolling around a zoomed page, controls that appear only when you hover near the top or bottom edge, double-page spread with automatic landscape detection, page scrubber, autoplay with a countdown, bookmarks, four color filters, RTL mode for manga, fully keyboard-driven.

### Reading Paths

An ordered, curated collection of comics that can span any number of series — a crossover event, a character's entire history, a "best of" you're building yourself. Drag-and-drop to reorder, per-issue notes, a custom cover, and a Resume button that always knows the next unfinished issue.

- **Add from anywhere**: a single issue (context menu or issue detail), a bulk selection (**Add To › Reading Path** in the selection bar, keeping the grid's order), or a whole series (**Add Series to Reading Path** on a series card). Each menu can also start a new path on the spot.
- **Reading List** is simply a built-in path named "Reading List" — the Reading List toggle on any comic adds it there, and you can reorder or annotate it like any other path.
- Reading Paths sit in the sidebar's main Library section, and sync between your Mac and iPad (see below).

### Highlights

- **Highlights** — star a bookmarked page in the reader, and it's saved to a standalone gallery of real page thumbnails; tap one to jump straight back into the reader at that page.

### Stats

One screen: totals for issues and pages read, a publisher breakdown, a reading goal, a **History** tab with your reading timeline, and an annual **Year in Review** recap — top series and publisher, longest reading streak, busiest month.

### Appearance

Five themes — **Dark** (gold accent, the default), **Light**, **Forest**, **Ocean** and **Ember** — chosen in the welcome tour or in **Settings › Appearance**. The reader always stays dark so pages stand out.

### Sync & Sharing

- **Peer sync (macOS ↔ iPad)** — over the local network via MultipeerConnectivity, no account or server involved. Syncs reading progress (current page, last-read time, and finished status) and Reading Paths, matched by file hash so it works even though each platform keeps its own independently-scanned library. Paths are merged by title and never deleted: a path, or a comic added to one, on either device shows up on both. Tags and manual issue orders aren't synced.

---

## Folder structure

ComicArc reads publisher, character, and series straight from how your files are organized:

```
Comics/
  DC/
    Batman/
      The Long Halloween/
        Batman - The Long Halloween 01.cbz
        Batman - The Long Halloween 02.cbz
  Marvel/
    Spider-Man/
      Ultimate Spider-Man/
        Miles Morales v01.cbr
```

| Folder depth | Interpreted as |
|---|---|
| 1 level deep | Series |
| 2 levels deep | Publisher / Series |
| 3+ levels deep | Publisher / Character / Series |

ComicInfo.xml fills in whatever the folder structure alone can't tell it. Once you've corrected a title, series, publisher, or character by hand, ComicArc remembers — a later rescan never silently overwrites a manual edit.

**Give each volume its own folder.** If a series has more than one volume (a legacy relaunch, a new #1, a different creative run), put each volume in its own folder — e.g. `Robin (1993)/` and `Robin (2021)/` side by side, not both dumped into a single `Robin/` folder. ComicArc derives a lot from the folder a file sits in, and two unrelated volumes sharing one folder is the single most common cause of issues sorting strangely or a rename producing an unexpected name. A folder named `Series (Year)` is a great, well-supported convention for this.

---

## Supported formats

| Format | Supported |
|---|---|
| `.cbz` | Yes |
| `.cbr` | Yes (bundled `unar`, no Homebrew needed) |
| `.pdf` | Yes |
| `.jpg` / `.jpeg` / `.png` | Yes |

---

## Keyboard shortcuts

### macOS reader

Press `?` inside the reader any time for the full list.

| Key | Action |
|---|---|
| `←` `→` / `↑` `↓` / click the page's left or right side | Previous / next page |
| `Space` / `⇧Space`, `Page Down` / `Page Up` | Next / previous page |
| `Home` / `End` | First / last page |
| `+` `-` / `0` | Zoom in / out / reset |
| `F` | Toggle fullscreen |
| `A` | Toggle autoplay |
| `B` / `H` | Bookmark the page / add it to Highlights |
| `D` | Toggle double-page spread |
| `R` | Toggle RTL direction |
| `G` | Show / hide the page filmstrip |
| `?` | Show all reader shortcuts |
| `Esc` / `W` | Stop autoplay, close the filmstrip, or close the reader |

The main window supports `⌘1`–`⌘6` (Library, Continue Reading, Favorites, Reading Paths, Highlights, Stats), `⌘[` / `⌘]` to go back and forward, `⌘K` for Quick Open, `⌘O` to import, `⌘E` to select several comics, `⇧⌘R` to scan, `⌥⇧⌘R` to resync, and `⌘,` for Settings. Drop comic files anywhere in the window to add them.

---


## Your data

Everything lives on your device. Nothing leaves it.

| Data | Location |
|---|---|
| Library database | `~/Library/Application Support/ComicArc/comics.db` (macOS) |
| Cover thumbnails | `~/Library/Application Support/ComicArc/covers/` (macOS) |

Your comic files themselves are **never moved, renamed, or modified** unless you ask: Clean Up Filenames renames, Convert CBR to CBZ re-encodes, ComicInfo write-back (off by default) edits metadata inside a CBZ, and Delete moves a file to the system Trash, where Restore can bring it back.

macOS and iPad each keep their own independent local library. Peer sync (see [Sync & Sharing](#sync--sharing)) keeps reading progress and Reading Paths in step between them over the local network; everything else — tags, bookmarks, manual issue orders — stays local to each device unless you move it yourself. Either platform can export a full JSON backup of all of it and restore it on the same device, or use it to move state to another device by hand.

---

## Where to get comics

ComicArc is a reader, not a store. Bring your own files. Some legal sources:

- [DriveThruComics](https://www.drivethrucomics.com/) — DRM-free CBZ/PDF, frequent sales
- [Humble Bundle](https://www.humblebundle.com/) — occasional DRM-free comic bundles
- [Amazon Kindle / ComiXology](https://www.comixology.com/) — purchase and download
- [Hoopla](https://www.hoopladigital.com/) / [Libby](https://libbyapp.com/) — free through your library card
- [Internet Archive](https://archive.org/details/comics) — public domain comics

Only import files you own or otherwise have the right to use.

---

## How it's built

| Layer | Folder | What it does |
|---|---|---|
| Data | `Core/Database`, `Core/Library` | SQLite through the C API, no ORM. Separate read and write connections (WAL), so browsing never waits behind a scan. Integrity-checked at launch with automatic restore from a rolling backup. Queries are grouped by feature (comics, groups, paths, stats, health). |
| Scanning | `Core/Scanner`, `Core/Metadata` | An actor that walks your folders, reads ComicInfo.xml, and identifies files by a content fingerprint, so moved or renamed comics keep their progress. FSEvents triggers a quick rescan when files change. |
| Files | `Core/Documents` | CBZ, CBR (bundled `unar`), PDF and images behind one `ComicDocument` protocol. |
| Images | `Core/Imaging` | Covers and pages decoded with ImageIO at the size they're shown, off the main thread. `CoverStore` merges duplicate requests and limits concurrent extraction; `PageRenderer` keeps a memory-budgeted cache and prefetches ahead in reading direction. |
| State | `App` | `AppModel` (Observation) holds navigation and every library action, with Undo. Screens load their own data and reload when the library changes. |
| UI | `Features`, `Design` | SwiftUI throughout; the reader's page view is an `NSScrollView` for native pinch, zoom and scrolling. |

## Building from source

Requires Xcode 16+.

```sh
git clone https://github.com/ComicArc/ComicArc.git
cd ComicArc
open ComicArc.xcodeproj
```

Pick the **ComicArc** scheme and run. No external dependencies to install — ZIPFoundation ships as a vendored local Swift package, and CBR support bundles its own `unar`.

---

## Acknowledgements

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — CBZ archive extraction
- [unar / The Unarchiver](https://theunarchiver.com/command-line) — CBR extraction, bundled

---

## License

MIT. See [LICENSE](LICENSE). The license covers the application code only — not any content you import.
