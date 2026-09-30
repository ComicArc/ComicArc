# ComicArc

**A native comic library, reader, and tracker for macOS, iPadOS, and visionOS. No account, no cloud, no subscription.**

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
- **Three real native targets.** macOS, iPadOS, and visionOS share one core (database, scanner, reader engine) but are each built for their own platform, not one UI awkwardly stretched over three.
- **Library and reader first.** Plus Reading Paths: build your own run from the comics you own — mix and match across series like a personal playlist.

---

## Getting started

### macOS

Requires macOS 14 (Sonoma) or later. Apple Silicon native.

1. Download and unzip `ComicArc-macOS.zip` from [the latest release](https://github.com/ComicArc/ComicArc/releases/latest).
2. Move **ComicArc.app** to `/Applications`.
3. **Right-click → Open** the first time, to get past Gatekeeper (see below for why).
4. Point the setup wizard at your comics folder — that's the whole install.

No Homebrew, no Terminal, no config files. CBR support is bundled. ComicArc checks for updates in the background (via [Sparkle](https://sparkle-project.org/)), and **ComicArc → Check for Updates…** is always there if you want to check yourself.

#### "ComicArc is damaged and can't be opened"

This is Gatekeeper reacting to an unnotarized app, not actual damage. Run this once and relaunch:

```sh
xattr -cr /Applications/ComicArc.app
```

### iPadOS

The iPad app (`ComicArcPad`, iPadOS 17+) isn't on the App Store yet — it lives in this same repository and builds directly from Xcode. If you have a free Apple Developer account and Xcode installed, open `ComicArc.xcodeproj`, pick the **ComicArcPad** scheme, and run it on your device.

---

## What it does

### Library

- **Multiple library folders.** Point ComicArc at more than one folder — a NAS share and a local drive, say — and it treats them as one combined library. Add or remove folders any time from Settings.
- **Publisher / Character / Series / Issue**, read from your folder structure and browsable from the sidebar.
- Cover thumbnails with inline progress bars; **Continue Reading** surfaces whatever you're mid-issue on.
- Bulk select: mark read/unread, add to a Reading Path (or the Reading List), delete, or reassign series/publisher across many issues at once.
- **Issue detail**: edit metadata, tag it, or add it to a Reading Path.
- **Series Manager**: reorder issues in a series (your order survives rescans), rename it, or set a custom cover. Otherwise issues sort by issue number, with annuals and specials after the regular issues.
- **Library Health** — one screen for maintenance:
  - a health report (issue-number gaps, duplicate #1s, mixed volumes, unreadable files),
  - **Duplicates**: comics with the exact same file name or the exact same cover thumbnail (byte-identical copies included); matching title, series, or issue number alone never counts,
  - **Needs Review**: ComicInfo.xml values that disagree with how a comic is filed, never silently overwritten,
  - tools to clean up filenames, convert CBR to CBZ (macOS), and resync the library.
- **Clean Up Filenames**: tidies messy filenames in bulk — underscores become spaces, repeated spaces collapse to one — with a one-tap per-file fix available from the issue detail view too. It only tidies up what's already there; it doesn't rename files based on their metadata.

### Reader

macOS opens the reader right inside the main window — no separate floating window, no chrome, just the page. iPad's reader is full-screen and built around touch.

**macOS** — page or continuous-scroll mode, pages fit the window by default, pinch/double-click zoom to 5x with normal trackpad/mouse scrolling around a zoomed page, controls that appear only when you hover near the top or bottom edge, double-page spread with automatic landscape detection, page scrubber, autoplay with a countdown, bookmarks, four color filters, RTL mode for manga, fully keyboard-driven.

**iPadOS** — swipe or continuous scroll, pinch/zoom, tap zones for page turns, autoplay, auto-hiding chrome that respects the notch and Home indicator.

### Reading Paths

An ordered, curated collection of comics that can span any number of series — a crossover event, a character's entire history, a "best of" you're building yourself. Drag-and-drop to reorder, per-issue notes, a custom cover, and a Resume button that always knows the next unfinished issue.

- **Add from anywhere**: a single issue (context menu or issue detail), a bulk selection (**Add to Path** in the selection bar, keeping the grid's order), or a whole series (**Add Series to Reading Path** on a series card). Each menu can also start a new path on the spot.
- **Reading List** is simply a built-in path named "Reading List" — the Reading List toggle on any comic adds it there, and you can reorder or annotate it like any other path.
- Reading Paths sit in the sidebar's main Library section, and sync between your Mac and iPad (see below).

### Highlights

- **Highlights** — star a bookmarked page in the reader, and it's saved to a standalone gallery of real page thumbnails; tap one to jump straight back into the reader at that page.

### Stats

One screen: totals for issues and pages read, a publisher breakdown, a reading goal, a **History** tab with your reading timeline, and an annual **Year in Review** recap — top series and publisher, longest reading streak, busiest month.

### Appearance

Six built-in themes (Dark, Pure Black for OLED, Graphite, Midnight Blue, Forest, Sepia) plus a custom accent color if none of them are quite right.

### Sync & Sharing

- **Peer sync (macOS ↔ iPad)** — over the local network via MultipeerConnectivity, no account or server involved. Syncs reading progress (current page, last-read time, and finished status) and Reading Paths, matched by file hash so it works even though each platform keeps its own independently-scanned library. Paths are merged by title and never deleted: a path, or a comic added to one, on either device shows up on both. Tags and manual issue orders aren't synced.
- **Share cards** — export a shareable image card for a Reading Path or your Year in Review recap, to post or send outside the app.

---

## macOS, iPad & Vision

All three targets share the same core — database, scanner, every screen above — so almost everything you can do on one, you can do on the others. The visionOS app reuses the iPad interface as-is. The remaining gaps come down to two real platform constraints: iOS/visionOS sandboxing has no shell-out access, and touch/gaze input isn't pointer input.

| Feature | macOS | iPad / Vision |
|---|---|---|
| Folder scanning | Yes (FSEvents, live) | Yes (rescans on foreground) |
| Multiple library folders | Yes | Yes |
| CBZ / PDF / JPG / PNG | Yes | Yes |
| CBR | Yes (bundled `unar`) | No — no shell access in the sandbox |
| Library Health, Clean Up Filenames | Yes | Yes |
| Reading Paths, Highlights | Yes | Yes |
| Stats (with History and Year in Review) | Yes | Yes |
| Share cards | Yes | Yes |
| Peer sync (progress + Reading Paths) | Yes | Yes (iPad only) |
| Backup export/import | Yes | Yes |
| Double-page spread, RTL, color filters, in-reader bookmarks | Yes | Not yet — touch/gaze reader is swipe/zoom/autoplay for now |
| Keyboard shortcuts | Full | Magic Keyboard (iPad): scan, navigate, back, rename |
| VoiceOver | Yes | Yes |

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

See [FILE_NAMING.md](FILE_NAMING.md) for the full folder and filename naming guide.

---

## Supported formats

| Format | macOS | iPad |
|---|---|---|
| `.cbz` | Yes | Yes |
| `.cbr` | Yes (bundled `unar`, no Homebrew needed) | No |
| `.pdf` | Yes | Yes |
| `.jpg` / `.jpeg` / `.png` | Yes | Yes (folder scan only) |

---

## Keyboard shortcuts

### macOS reader

Press `?` inside the reader any time for the full list.

| Key | Action |
|---|---|
| `←` `→` / `↑` `↓` | Previous / next page |
| `Space` / `⇧Space`, `Page Down` / `Page Up` | Next / previous page |
| `Home` / `End` | First / last page |
| `+` `-` / `0` | Zoom in / out / reset |
| `F` | Toggle fullscreen |
| `A` | Toggle autoplay |
| `B` | Bookmark current page |
| `D` | Toggle double-page spread |
| `R` | Toggle RTL direction |
| `Esc` | Stop autoplay, close the filmstrip, or close the reader |

The main window also supports `⌘1`–`⌘6` (Library, Continue Reading, Favorites, Reading Paths, Stats, Highlights) to jump to any sidebar section, `⌘[` to go back, `⌘E` to toggle bulk-select, `⇧⌘R` to rescan, and `⇧⌘F` to open Clean Up Filenames.

### iPad (Magic Keyboard)

| Shortcut | Action |
|---|---|
| `⇧⌘R` | Scan library |
| `⇧⌘F` | Clean Up Filenames |
| `⌘1`–`⌘6` | Jump to sidebar section |
| `⌘[` | Go back |

---

## Your data

Everything lives on your device. Nothing leaves it.

| Data | Location |
|---|---|
| Library database | `~/Library/Application Support/ComicArc/comics.db` (macOS) |
| Cover thumbnails | `~/Library/Application Support/ComicArc/covers/` (macOS) |

Your comic files themselves are **never moved, renamed, or modified** unless you use the Clean Up Filenames tool.

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

## Building from source

Requires Xcode 16+.

```sh
git clone https://github.com/ComicArc/ComicArc.git
cd ComicArc
open ComicArc.xcodeproj
```

Pick the **ComicArc** scheme for macOS, **ComicArcPad** for iPad, or **ComicArcVision** for visionOS, and run. No external dependencies to install — ZIPFoundation ships as a vendored local Swift package, and CBR support bundles its own `unar`.

---

## Acknowledgements

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — CBZ archive extraction
- [unar / The Unarchiver](https://theunarchiver.com/command-line) — CBR extraction, bundled
- [Sparkle](https://sparkle-project.org/) — macOS auto-updates

---

## License

MIT. See [LICENSE](LICENSE). The license covers the application code only — not any content you import.
