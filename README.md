# ComicArc

**A native comic library, reader, and tracker for macOS and iPadOS. No account, no cloud, no subscription.**

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
- **Offline by default, forever.** No account, no telemetry, nothing phoning home. The one optional download — an offline comics database for better metadata matching — is a single file you grab once; after that it works forever with no connection.
- **Two real native targets.** macOS and iPadOS share one core (database, scanner, reading-order engine) but are each built for their own platform, not one UI awkwardly stretched over both.
- **More than a reader.** A Diary that logs every read and reread, Tier Lists, Favorite Moments, Reading Paths that span multiple series, and a Year in Review recap — the parts of tracking what you've read that most comic readers skip entirely.

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
- Cover thumbnails with inline progress bars and star ratings; **Continue Reading** surfaces whatever you're mid-issue on.
- Bulk select: mark read/unread, add to a Reading Path, delete, or reassign series/publisher across many issues at once.
- **Issue detail**: edit metadata, tag it, write a review, rate it inline, or fix its comics-database match by hand.
- **Series Manager**: reorder issues in a series, rename it, or set a custom cover.
- **Possible Duplicates** flags comics sharing a publisher/series/issue number — the usual sign of a rescan or a re-download under a different filename.
- **Metadata Conflicts**: if a rescan finds a ComicInfo.xml value that disagrees with what you already have on file, it's flagged for your review, never silently overwritten.
- **Rename Files**: batch-renames anything that doesn't match a single, consistent filename standard (`Series (Edition) #Issue`), with a one-tap per-file fix available from the issue detail view too.

### Reader

macOS opens the reader right inside the main window — no separate floating window, no chrome, just the page. iPad's reader is full-screen and built around touch.

**macOS** — page or continuous-scroll mode, double-page spread with automatic landscape detection, pinch/zoom to 5x, page scrubber, autoplay with a countdown, bookmarks, four color filters, RTL mode for manga, fully keyboard-driven.

**iPadOS** — swipe or continuous scroll, pinch/zoom, tap zones for page turns, autoplay, auto-hiding chrome that respects the notch and Home indicator.

### Intelligent reading order

Annuals, specials, and giant-size issues almost never belong at the very end of a series, even though their filenames usually sort them there. ComicArc's reading-order engine places them where they were actually published relative to everything else — using legacy numbering, cover date, and story-arc adjacency, in that priority order, with a proportional fallback when nothing else is available.

You can turn this off entirely and use plain filename order instead, or pick a specific basis (legacy number, publication date, ComicInfo.xml's own number) from an advanced picker. Manual corrections you make in Series Manager always win over the automatic placement and survive future rescans. When one series is a direct continuation of another — a legacy renumbering, a line-wide relaunch — linking them makes the whole run sort as one sequence instead of two separate piles.

### Offline comics database

A free one-time download (a few hundred KB per genre) built from a public [Grand Comics Database](https://www.comics.org/) snapshot (CC BY-SA 4.0, attribution in Settings). It matches your files even when your folders use fan abbreviations, understands legacy-numbering relaunches, and needs no ongoing connection once downloaded. If it ever gets a match wrong — or finds nothing — the **Fix Match** picker lets you search and set the correct one by hand, and your pick is protected from ever being silently overwritten by a later rescan.

### Reading Paths

An ordered, curated collection of comics that can span any number of series — a crossover event, a character's entire history, a "best of" you're building yourself. Drag-and-drop to reorder, per-issue notes, an overall rating and review, a custom cover, and a Resume button that always knows the next unfinished issue.

### Diary, Tier Lists & Favorite Moments

- **Diary** — every rating and reread gets logged as its own dated entry, so your reading history reads as an actual timeline, not one number that keeps getting overwritten.
- **Tier Lists** — rank comics into S/A/B/C/D/F tiers by dragging between rows, with the same rating/review/cover treatment as Reading Paths.
- **Favorite Moments** — star a bookmarked page in the reader, and it's saved to a standalone gallery of real page thumbnails; tap one to jump straight back into the reader at that page.

### Stats, History & Year in Review

Totals for issues and pages read, time in-app, a publisher breakdown, a reading history timeline, and an annual **Year in Review** recap — top series and publisher, longest reading streak, your top-rated comics of the year.

### Appearance

Six built-in themes (Dark, Pure Black for OLED, Graphite, Midnight Blue, Forest, Sepia) plus a custom accent color if none of them are quite right.

---

## macOS vs. iPad

Both apps share the same core — database, scanner, reading-order engine, every screen above — so almost everything you can do on one, you can do on the other. The gaps come down to two real platform constraints: iOS sandboxing has no shell-out access, and touch input isn't pointer input.

| Feature | macOS | iPad |
|---|---|---|
| Folder scanning | Yes (FSEvents, live) | Yes (rescans on foreground) |
| Multiple library folders | Yes | Yes |
| CBZ / PDF / JPG / PNG | Yes | Yes |
| CBR | Yes (bundled `unar`) | No — no shell access in the iOS sandbox |
| Reading order, offline database, Fix Match | Yes | Yes |
| Rename Files | Yes | Yes |
| Reading Paths, Diary, Tier Lists, Favorite Moments | Yes | Yes |
| Stats, History, Year in Review | Yes | Yes |
| Backup export/import | Yes | Yes |
| Double-page spread, RTL, color filters, in-reader bookmarks | Yes | Not yet — touch reader is swipe/zoom/autoplay for now |
| Keyboard shortcuts | Full | Magic Keyboard: scan, navigate, back, rename |
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
| `Home` / `End` | First / last page |
| `+` `-` / `0` | Zoom in / out / reset |
| `F` | Toggle fullscreen |
| `A` | Toggle autoplay |
| `B` | Bookmark current page |
| `D` | Toggle double-page spread |
| `R` | Toggle RTL direction |
| `Esc` | Stop autoplay, or close reader |

The main window also supports `⌘1`–`⌘9` to jump to any sidebar section, `⌘[` to go back, `⌘E` to toggle bulk-select, `⇧⌘R` to rescan, and `⇧⌘F` to open Rename Files.

### iPad (Magic Keyboard)

| Shortcut | Action |
|---|---|
| `⇧⌘R` | Scan library |
| `⇧⌘F` | Rename Files |
| `⌘1`–`⌘9` | Jump to sidebar section |
| `⌘[` | Go back |

---

## Your data

Everything lives on your device. Nothing leaves it.

| Data | Location |
|---|---|
| Library database | `~/Library/Application Support/ComicArc/comics.db` (macOS) |
| Cover thumbnails | `~/Library/Application Support/ComicArc/covers/` (macOS) |
| Offline comics database (optional) | `~/Library/Application Support/ComicArc/gcd_lookup.sqlite` (macOS) |

Your comic files themselves are **never moved, renamed, or modified** unless you use the Rename Files tool.

macOS and iPad each keep their own independent local library — there's no sync between them. Either platform can export a full JSON backup (comics, progress, ratings, reviews, tags, bookmarks, Reading Paths, Tier Lists, Diary entries, series links, reading-order overrides) and restore it on the same device, or use it to move state to another device by hand.

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

Pick the **ComicArc** scheme for macOS or **ComicArcPad** for iPad, and run. No external dependencies to install — ZIPFoundation ships as a vendored local Swift package, and CBR support bundles its own `unar`.

```sh
# Run the test suite
xcodebuild -project ComicArc.xcodeproj -scheme ComicArc -destination 'platform=macOS' test
```

The offline comics database itself isn't in this repository — it's a generated SQLite file published as a GitHub release asset. `Tools/gcd_extract.py` documents how it's built from a public GCD data dump, if you want to regenerate or update it.

---

## Acknowledgements

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — CBZ archive extraction
- [unar / The Unarchiver](https://theunarchiver.com/command-line) — CBR extraction, bundled
- [Sparkle](https://sparkle-project.org/) — macOS auto-updates
- [Grand Comics Database](https://www.comics.org/) (GCD) — source data for the offline comics database, [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)

---

## License

MIT. See [LICENSE](LICENSE). The license covers the application code only — not any content you import, and not the GCD-derived comics database data (CC BY-SA 4.0, see above).
