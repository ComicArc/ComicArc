# ComicArc

**A native comic library and reader for macOS and iPadOS — no accounts, no cloud, no subscriptions.**

Your comics stay exactly where they are, in the folders you already organized them into. ComicArc reads that structure directly, builds a fast local library around it, and gets out of the way. No server, no sign-in, no background uploads, no monthly fee — just a genuinely native app on top of files you own.

[![Build & Release](https://github.com/ComicArc/ComicArc/actions/workflows/release.yml/badge.svg)](https://github.com/ComicArc/ComicArc/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**[→ Download the latest macOS release](https://github.com/ComicArc/ComicArc/releases/latest)**

---

## Why ComicArc

Most comic readers ask you to import your library into *their* format, hand your files to a background daemon, or nag you toward a subscription. ComicArc doesn't do any of that.

- **Your folders are the database.** Publisher → Character → Series → Issue, read straight from the file system you already built. Nothing gets renamed, moved, or rewritten.
- **Genuinely native, not a wrapper.** 100% SwiftUI, built directly against AppKit/UIKit — full VoiceOver support (40+ explicit accessibility labels across the app), real keyboard shortcuts, Magic Keyboard support on iPad, native drag-and-drop, and the platform's actual navigation idioms instead of a web view pretending to be an app.
- **Fast because it's simple.** SQLite accessed directly through the C API, no ORM, no API layer, no network round-trip standing between you and your library. Indexed queries, chunked batch imports, and an on-disk thumbnail cache keep even large libraries snappy.
- **Zero network dependency, by design.** No account, no telemetry, no metadata service phoning home. Everything ComicArc knows about your library, it learned from your folder structure and your own edits — nothing else.
- **Built for two screens, not compromised for either.** macOS and iPadOS are separate native targets sharing one core, not a single UI stretched awkwardly across both.

---

## Getting Started

### macOS

Requires macOS 14 Sonoma or later. Apple Silicon native.

1. Download and unzip `ComicArc-macOS.zip` from [the latest release](https://github.com/ComicArc/ComicArc/releases/latest)
2. Move **ComicArc.app** to `/Applications`
3. **Right-click → Open** on first launch to clear the Gatekeeper prompt
4. Point the setup wizard at your comics folder — that's it

No Homebrew, no Terminal, no configuration files. CBR support is bundled.

#### "ComicArc is damaged and can't be opened"

This is a macOS quarantine attribute, not actual damage — the app isn't notarized (yet). Run once and relaunch:

```sh
xattr -cr /Applications/ComicArc.app
```

### iPadOS

The iPad app (`ComicArcPad`, requires iPadOS 17+) lives in this repository and builds directly from Xcode — it isn't on the App Store yet. If you're comfortable with a free Apple Developer account and Xcode, open `ComicArc.xcodeproj`, select the **ComicArcPad** scheme, and run it on your device. App Store availability is on the roadmap.

---

## What It Does

### Library

Your comics folder is the source of truth on both platforms. ComicArc scans it automatically on macOS — picking up new files, removing deleted ones — and on iPad you choose a folder once and it's rescanned every time you bring the app to the foreground.

- **Grouped hierarchy** — Publisher → Character → Series → Issues, navigated from a native sidebar
- Cover thumbnails with inline progress bars and star ratings
- **Continue Reading** surfaces in-progress issues on the home screen
- Browse by publisher or tag directly from the sidebar; search from the toolbar
- Favorites and Reading List for issues you want to flag or queue
- Bulk select — mark read/unread, add to list, delete, or **reassign series/publisher** across multiple issues at once
- **Issue detail page** — edit metadata, manage tags, write a review, rate inline
- **Series Manager** — reorder issues within a series, rename it, or set a custom cover
- **Possible Duplicates** — automatically flags comics sharing the same publisher, series, and issue number (the usual result of a rescan or a re-rip under a different filename), so cleanup takes seconds instead of scrolling

### Reader

The macOS reader opens inside the main window — no floating windows, no chrome, just the page. The iPad reader is a full-screen, touch-first experience built around swipe and pinch.

**macOS**
- **Page mode** and **continuous scroll** mode
- **Double-page spread** with automatic spread detection (landscape pages are never paired)
- Trackpad pinch/zoom up to 5×; drag to pan; double-click to reset
- **Page scrubber**, **autoplay** with a live countdown bar, bookmarks (`B`), color filters (Normal/Night/Sepia/Grayscale), RTL mode for manga
- Auto-hiding controls, keyboard-driven from end to end

**iPadOS**
- Swipe between pages or switch to continuous scroll
- Pinch to zoom, drag to pan, tap zones for page turns, tap center to toggle chrome
- **Slideshow/autoplay** with a live countdown bar, speed configurable in Settings
- Auto-hiding controls that respect the status bar and Home indicator

### Reading Orders

When a story spans multiple series, Reading Orders let you build a single reading path across all of them — identical feature set on macOS and iPad.

- Add issues from any series or publisher into an ordered list
- Drag-and-drop to reorder; per-issue notes for context
- Resume picks up exactly where you left off and auto-advances to the next issue

### Stats, History & Creators

Also shared across both platforms:

- Totals: issues, pages read, time in-app, favorites, completed runs
- Publisher breakdown chart
- Reading history timeline
- Creator browser — explore your library by writer or artist

---

## macOS vs. iPad — Feature Parity

Both apps share the same core (navigation, database, scanner, reading-order/stats/creator views), so most of what you can do on one, you can do on the other. The differences come down to two real platform constraints: iOS sandboxing (no shell-out tools) and touch vs. pointer input.

| Feature | macOS | iPad |
|---|---|---|
| Folder-based library scanning | ✅ (FSEvents, live) | ✅ (rescans on foreground) |
| Per-file import | ✅ | ✅ |
| CBZ / PDF / JPG / PNG | ✅ | ✅ |
| CBR | ✅ (bundled `unar`) | ❌ *(no shell access in the iOS sandbox)* |
| Search, publisher & tag browsing | ✅ | ✅ |
| Bulk select, reassign, duplicates | ✅ | ✅ |
| Reading Orders, Stats, History, Creators | ✅ | ✅ |
| Backup export/import | ✅ | ✅ |
| Double-page spread, RTL, color filters, in-reader bookmarks | ✅ | 🚧 *(not yet — touch reader is swipe/zoom/autoplay for now)* |
| Keyboard shortcuts | ✅ (full) | ✅ (Magic Keyboard: scan, navigate, back) |
| VoiceOver | ✅ | ✅ |

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

ComicInfo.xml is used as a fallback when folder structure alone isn't enough. Once you've corrected a title, series, publisher, or character by hand, ComicArc remembers — automatic re-scans never silently overwrite a manual edit.

---

## Supported Formats

| Format | macOS | iPad |
|---|---|---|
| `.cbz` | ✅ | ✅ |
| `.cbr` | ✅ (bundled `unar`, no Homebrew required) | ❌ |
| `.pdf` | ✅ | ✅ |
| `.jpg` / `.jpeg` / `.png` | ✅ | ✅ (folder scan only) |

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

The main window also supports ⌘1–⌘8 to jump to any sidebar section, ⌘[ to go back, ⌘G to toggle grouped view, ⌘E to toggle bulk-select, and ⇧⌘R to rescan your library.

### iPad (Magic Keyboard)

| Shortcut | Action |
|---|---|
| ⇧⌘R | Scan library |
| ⌘1–⌘8 | Jump to sidebar section |
| ⌘[ | Go back |

---

## Your Data

Everything lives on your device. Nothing leaves it.

| Data | Location |
|---|---|
| Library database | `~/Library/Application Support/ComicArc/comics.db` (macOS) |
| Cover thumbnails | `~/Library/Application Support/ComicArc/covers/` (macOS) |

Your comic files are **never moved, renamed, or modified.**

macOS and iPad each keep their own independent local library — there's no sync between them. You can export a full JSON backup on either platform — comics, progress, ratings, reviews, tags, bookmarks, and reading orders — and restore it on the same device, or use it to move state between devices manually.

---

## Where to Get Comics

ComicArc is a reader, not a store. You bring your own files. Some legal sources:

- [DriveThruComics](https://www.drivethrucomics.com/) — DRM-free CBZ and PDF, frequent sales
- [Humble Bundle](https://www.humblebundle.com/) — occasional comic bundles as DRM-free files
- [Amazon Kindle / ComiXology](https://www.comixology.com/) — purchase and download issues
- [Hoopla](https://www.hoopladigital.com/) / [Libby](https://libbyapp.com/) — free digital comics through your local library card
- [Internet Archive](https://archive.org/details/comics) — public domain comics, free to download

Only import files you own or have the right to use.

---

## Building From Source

Requires Xcode 16+.

```sh
git clone https://github.com/ComicArc/ComicArc.git
cd ComicArc
open ComicArc.xcodeproj
```

Select the **ComicArc** scheme for macOS or **ComicArcPad** for iPad, and run. There are no external dependencies to install — ZIPFoundation is vendored as a local Swift package and CBR support ships a bundled `unar`.

```sh
# Run the test suite
xcodebuild -project ComicArc.xcodeproj -scheme ComicArc -destination 'platform=macOS' test
```

---

## Acknowledgements

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — CBZ archive extraction
- [unar / The Unarchiver](https://theunarchiver.com/command-line) — CBR extraction, bundled

---

## License

MIT. See [LICENSE](LICENSE). The license covers the application code only — not any content you import.
