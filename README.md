# ComicArc

**A native comic library and reader for macOS and iPadOS, with no accounts, no cloud, and no subscriptions.**

Your comics stay exactly where they are, in the folders you already organized them into. ComicArc reads that structure directly, builds a fast local library around it, and gets out of the way. No server, no sign-in, no background uploads, no monthly fee, just a genuinely native app on top of files you own.

[![Build & Release](https://github.com/ComicArc/ComicArc/actions/workflows/release.yml/badge.svg)](https://github.com/ComicArc/ComicArc/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**[Download the latest macOS release](https://github.com/ComicArc/ComicArc/releases/latest)**

---

## Why ComicArc

Most comic readers ask you to import your library into *their* format, hand your files to a background daemon, or nag you toward a subscription. ComicArc doesn't do any of that.

- **Your folders are the database.** Publisher / Character / Series / Issue, read straight from the file system you already built. Nothing gets renamed, moved, or rewritten without you asking for it.
- **Genuinely native, not a wrapper.** 100% SwiftUI, built directly against AppKit/UIKit: full VoiceOver support (40+ explicit accessibility labels across the app), real keyboard shortcuts, Magic Keyboard support on iPad, native drag-and-drop, and the platform's actual navigation idioms instead of a web view pretending to be an app.
- **Fast because it's simple.** SQLite accessed directly through the C API, no ORM, no API layer, no network round-trip standing between you and your library. Indexed queries, chunked batch imports, and an on-disk thumbnail cache keep even large libraries snappy.
- **Zero network dependency, by design.** No account, no telemetry, no metadata service phoning home. The one optional download (the offline comics database, below) is a single one-time file; after that, everything runs offline forever.
- **Built for two screens, not compromised for either.** macOS and iPadOS are separate native targets sharing one core, not a single UI stretched awkwardly across both.

---

## Getting Started

### macOS

Requires macOS 14 Sonoma or later. Apple Silicon native.

1. Download and unzip `ComicArc-macOS.zip` from [the latest release](https://github.com/ComicArc/ComicArc/releases/latest)
2. Move **ComicArc.app** to `/Applications`
3. **Right-click, then Open** on first launch to clear the Gatekeeper prompt
4. Point the setup wizard at your comics folder, that's it

No Homebrew, no Terminal, no configuration files. CBR support is bundled.

#### "ComicArc is damaged and can't be opened"

This is a macOS quarantine attribute, not actual damage (the app isn't notarized yet). Run once and relaunch:

```sh
xattr -cr /Applications/ComicArc.app
```

### iPadOS

The iPad app (`ComicArcPad`, requires iPadOS 17+) lives in this repository and builds directly from Xcode; it isn't on the App Store yet. If you're comfortable with a free Apple Developer account and Xcode, open `ComicArc.xcodeproj`, select the **ComicArcPad** scheme, and run it on your device. App Store availability is on the roadmap.

---

## What It Does

### Library

Your comics folder is the source of truth on both platforms. ComicArc scans it automatically on macOS, picking up new files and removing deleted ones, and on iPad you choose a folder once and it's rescanned every time you bring the app to the foreground.

- **Grouped hierarchy**: Publisher / Character / Series / Issues, navigated from a native sidebar
- Cover thumbnails with inline progress bars and star ratings
- **Continue Reading** surfaces in-progress issues on the home screen
- Browse by publisher or tag directly from the sidebar; search from the toolbar
- Favorites, Reading List, and custom Shelves for tagging issues however you like
- Bulk select: mark read/unread, add to list, delete, or **reassign series/publisher** across multiple issues at once
- **Issue detail page**: edit metadata, manage tags and shelves, write a review, rate inline
- **Series Manager**: reorder issues within a series, rename it, or set a custom cover
- **Library Check**: a lightweight health scan after every library scan, flagging possible duplicates, series with more than one "#1" issue, and annuals/specials that may be sitting in the wrong spot, each with a one-tap fix or a direct link to the right screen
- **Possible Duplicates**: automatically flags comics sharing the same publisher, series, and issue number (the usual result of a rescan or a re-rip under a different filename), so cleanup takes seconds instead of scrolling
- **Rename Files**: previews and applies a batch rename for files whose names don't match their series or issue number, reachable instantly from the Library menu (`⇧⌘F` on both platforms). When a comic has a verified match in the offline comics database, the suggested name is marked with a checkmark, it isn't a guess.

### Reader

The macOS reader opens inside the main window, no floating windows, no chrome, just the page. The iPad reader is a full-screen, touch-first experience built around swipe and pinch.

**macOS**
- **Page mode** and **continuous scroll** mode
- **Double-page spread** with automatic spread detection (landscape pages are never paired)
- Trackpad pinch/zoom up to 5x; drag to pan; double-click to reset
- **Page scrubber**, **autoplay** with a live countdown bar, bookmarks (`B`), color filters (Normal/Night/Sepia/Grayscale), RTL mode for manga
- Auto-hiding controls, keyboard-driven from end to end

**iPadOS**
- Swipe between pages or switch to continuous scroll
- Pinch to zoom, drag to pan, tap zones for page turns, tap center to toggle chrome
- **Slideshow/autoplay** with a live countdown bar, speed configurable in Settings
- Auto-hiding controls that respect the status bar and Home indicator

### Intelligent Reading Order

Annuals, specials, and giant-size issues rarely belong at the very end of a series, but their filenames often sort them there. ComicArc's Reading Order Engine places them where they actually belong.

- Signals are combined in priority order: legacy numbering, cover date, story arc, then a proportional fallback, so a special with a known date lands next to the issues it was published alongside
- **Smart Reading Order** can be toggled off entirely in Settings if you'd rather keep plain filename order, with an **Advanced** picker for other explicit bases (legacy number, publication date, or the number embedded in ComicInfo.xml)
- **Recheck My Library** re-runs placement without touching anything you've fixed by hand; **Undo My Manual Fixes** clears your manual corrections and lets automatic placement decide again
- Manual corrections you make in Series Manager always win over the automatic placement, and survive future rescans
- **Series continuations**: when one series is the direct continuation of another (Tales of Suspense into Captain America, for example), linking them makes the whole run sort as one continuous sequence instead of two separate piles

### Offline Comics Database

A free, one-time download (a few hundred KB per genre you read) that lets ComicArc place annuals and specials using their real publication date instead of a guess, entirely offline forever afterward.

- Built from a public snapshot of the [Grand Comics Database](https://www.comics.org/) (GCD), licensed CC BY-SA 4.0, attribution included in Settings
- Matches your folders even when they use fan abbreviations instead of a series' full official name (`ASM` for The Amazing Spider-Man, for example)
- Recognizes annuals and specials as their own catalog line and searches it specifically, and understands relaunch numbering where a reset issue number carries the true continuing number alongside it
- No account, no ongoing internet connection required, and no server dependency: download once, and it works forever
- Download, update, or delete it any time from Settings, on either platform

### Reading Orders (Custom Cross-Series Lists)

When a story spans multiple series and you want a reading path across all of them, Reading Orders let you build one, identical feature set on macOS and iPad.

- Add issues from any series or publisher into an ordered list
- Drag-and-drop to reorder; per-issue notes for context
- Resume picks up exactly where you left off and auto-advances to the next issue

### Stats & History

Also shared across both platforms:

- Totals: issues, pages read, time in-app, favorites, completed runs
- Publisher breakdown chart
- Reading history timeline

### Appearance

Six built-in themes (Dark, Pure Black for OLED, Graphite, Midnight Blue, Forest, and Sepia), plus a custom accent color if none of them fit exactly.

---

## macOS vs. iPad, Feature Parity

Both apps share the same core (navigation, database, scanner, reading-order/stats/creator views), so most of what you can do on one, you can do on the other. The differences come down to two real platform constraints: iOS sandboxing (no shell-out tools) and touch vs. pointer input.

| Feature | macOS | iPad |
|---|---|---|
| Folder-based library scanning | Yes (FSEvents, live) | Yes (rescans on foreground) |
| Per-file import | Yes | Yes |
| CBZ / PDF / JPG / PNG | Yes | Yes |
| CBR | Yes (bundled `unar`) | No *(no shell access in the iOS sandbox)* |
| Search, publisher & tag browsing | Yes | Yes |
| Bulk select, reassign, duplicates | Yes | Yes |
| Intelligent Reading Order, offline comics database | Yes | Yes |
| Rename Files tool | Yes | Yes |
| Reading Orders, Stats, History | Yes | Yes |
| Backup export/import | Yes | Yes |
| Double-page spread, RTL, color filters, in-reader bookmarks | Yes | Not yet *(touch reader is swipe/zoom/autoplay for now)* |
| Keyboard shortcuts | Yes (full) | Yes (Magic Keyboard: scan, navigate, back, rename) |
| VoiceOver | Yes | Yes |

---

## Folder Structure

ComicArc reads publisher, character, and series directly from your folder layout:

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

ComicInfo.xml is used as a fallback when folder structure alone isn't enough. Once you've corrected a title, series, publisher, or character by hand, ComicArc remembers, automatic re-scans never silently overwrite a manual edit.

---

## Supported Formats

| Format | macOS | iPad |
|---|---|---|
| `.cbz` | Yes | Yes |
| `.cbr` | Yes (bundled `unar`, no Homebrew required) | No |
| `.pdf` | Yes | Yes |
| `.jpg` / `.jpeg` / `.png` | Yes | Yes (folder scan only) |

---

## Keyboard Shortcuts

### macOS reader

Press `?` inside the reader at any time to see the full list.

| Key | Action |
|---|---|
| `←` `→` / `↑` `↓` | Previous / next page |
| `Home` / `End` | First / last page |
| `+` `-` / `0` | Zoom in / out / reset |
| `F` | Toggle fullscreen |
| `A` | Toggle autoplay |
| `B` | Bookmark current page |
| `D` | Toggle double-page spread |
| `R` | Toggle RTL direction |
| `Esc` | Stop autoplay, or close reader |

The main window also supports ⌘1 through ⌘8 to jump to any sidebar section, ⌘[ to go back, ⌘G to toggle grouped view, ⌘E to toggle bulk-select, ⇧⌘R to rescan your library, and ⇧⌘F to open the Rename Files tool.

### iPad (Magic Keyboard)

| Shortcut | Action |
|---|---|
| ⇧⌘R | Scan library |
| ⇧⌘F | Rename Files tool |
| ⌘1 through ⌘8 | Jump to sidebar section |
| ⌘[ | Go back |

---

## Your Data

Everything lives on your device. Nothing leaves it.

| Data | Location |
|---|---|
| Library database | `~/Library/Application Support/ComicArc/comics.db` (macOS) |
| Cover thumbnails | `~/Library/Application Support/ComicArc/covers/` (macOS) |
| Offline comics database (optional) | `~/Library/Application Support/ComicArc/gcd_lookup.sqlite` (macOS) |

Your comic files are **never moved, renamed, or modified** unless you explicitly use the Rename Files tool.

macOS and iPad each keep their own independent local library, there's no sync between them. You can export a full JSON backup on either platform (comics, progress, ratings, reviews, tags, bookmarks, and reading orders) and restore it on the same device, or use it to move state between devices manually.

---

## Where to Get Comics

ComicArc is a reader, not a store. You bring your own files. Some legal sources:

- [DriveThruComics](https://www.drivethrucomics.com/): DRM-free CBZ and PDF, frequent sales
- [Humble Bundle](https://www.humblebundle.com/): occasional comic bundles as DRM-free files
- [Amazon Kindle / ComiXology](https://www.comixology.com/): purchase and download issues
- [Hoopla](https://www.hoopladigital.com/) / [Libby](https://libbyapp.com/): free digital comics through your local library card
- [Internet Archive](https://archive.org/details/comics): public domain comics, free to download

Only import files you own or have the right to use.

---

## Building From Source

Requires Xcode 16+.

```sh
git clone https://github.com/ComicArc/ComicArc.git
cd ComicArc
open ComicArc.xcodeproj
```

Select the **ComicArc** scheme for macOS or **ComicArcPad** for iPad, and run. There are no external dependencies to install: ZIPFoundation is vendored as a local Swift package and CBR support ships a bundled `unar`.

```sh
# Run the test suite
xcodebuild -project ComicArc.xcodeproj -scheme ComicArc -destination 'platform=macOS' test
```

The offline comics database itself isn't part of the repository (it's a generated SQLite file hosted as a GitHub release asset); `Tools/gcd_extract.py` documents how it's built from a public GCD data dump if you want to regenerate or update it.

---

## Acknowledgements

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation): CBZ archive extraction
- [unar / The Unarchiver](https://theunarchiver.com/command-line): CBR extraction, bundled
- [Grand Comics Database](https://www.comics.org/) (GCD): source data for the offline comics database, licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)

---

## License

MIT. See [LICENSE](LICENSE). The license covers the application code only, not any content you import, and not the GCD-derived comics database data (CC BY-SA 4.0, see above).
