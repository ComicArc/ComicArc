# ComicArc

A native macOS comic library and reader. No accounts, no cloud, no subscriptions — just your files, organized and readable, entirely on your machine.

**[→ Download the latest release](https://github.com/ComicArc/ComicArc/releases/latest)**

Requires macOS 14 Sonoma or later. Apple Silicon native.

---

## Getting Started

1. Download and unzip `ComicArc.zip`
2. Move **ComicArc.app** to `/Applications`
3. **Right-click → Open** on first launch to clear the Gatekeeper prompt
4. Point the setup wizard at your comics folder — that's it

No Homebrew, no Terminal, no configuration files. CBR support is bundled.

### "ComicArc is damaged and can't be opened"

This is a macOS quarantine attribute, not actual damage. Run once and relaunch:

```sh
xattr -cr /Applications/ComicArc.app
```

---

## What It Does

### Library

Your comics folder is the source of truth. ComicArc scans it automatically — picking up new files, removing deleted ones, and organizing everything by the folder structure you already have.

- **Grouped hierarchy** — Publisher → Character → Series → Issues, navigated from a native sidebar
- Cover thumbnails with inline progress bars and star ratings
- **Continue Reading** surfaces in-progress issues on the home screen
- Filter by publisher or tag directly from the sidebar; search from the toolbar
- Favorites and Reading List for issues you want to flag or queue
- Bulk select — mark read/unread, add to list, or delete across multiple issues at once
- **Issue detail page** — edit metadata, manage tags, write a review, rate inline
- **Series Manager** — reorder issues within a series, rename it, or set a custom cover

### Reader

The reader opens inside the main window. No floating windows, no chrome — just the page.

- **Page mode** and **continuous scroll** mode
- **Double-page spread** with automatic spread detection (landscape pages are never paired)
- Pinch or trackpad to zoom up to 5×; drag to pan; double-click to reset
- **Page scrubber** — drag the slider in the bottom bar to jump anywhere instantly
- **Autoplay** — advances on a configurable timer with a live countdown bar
- Auto-hiding controls — appear near the top and bottom edges, fade after five seconds
- Bookmarks — press `B` on any page and jump back from the bookmarks list
- Color filters: Normal, Night, Sepia, Grayscale
- RTL mode for manga
- Progress is saved on every page turn

### Reading Orders

When a story spans multiple series, Reading Orders let you build a single reading path across all of them.

- Add issues from any series or publisher into an ordered list
- Drag-and-drop to reorder; per-issue notes for context
- Resume picks up exactly where you left off and auto-advances to the next issue

### Stats & History

- Totals: issues, pages read, time in-app, favorites, completed runs
- Publisher breakdown chart
- Reading history timeline
- Creator browser — explore your library by writer or artist

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

ComicInfo.xml is used as a fallback when folder structure alone isn't enough.

---

## Supported Formats

`.cbz` · `.cbr` · `.pdf` · `.jpg` · `.jpeg` · `.png`

All formats are handled natively. CBR support uses a bundled copy of `unar` — no Homebrew required.

---

## Keyboard Shortcuts

Press `?` inside the reader at any time to see the full list.

| Key | Action |
|---|---|
| `←` `→` | Previous / next page |
| `↑` `↓` | Previous / next page |
| `Home` | First page |
| `End` | Last page |
| `+` `-` | Zoom in / out |
| `0` | Reset zoom |
| `F` | Toggle fullscreen |
| `A` | Toggle autoplay |
| `B` | Bookmark current page |
| `D` | Toggle double-page spread |
| `R` | Toggle RTL direction |
| `Esc` | Stop autoplay, or close reader |
| `?` | Show shortcuts |

The main window also supports ⌘1–⌘8 to jump to any sidebar section, ⌘[ to go back, ⌘G to toggle grouped view, and ⇧⌘R to rescan your library.

---

## Your Data

Everything lives on your Mac. Nothing leaves it.

| Data | Location |
|---|---|
| Library database | `~/Library/Application Support/ComicArc/comics.db` |
| Cover thumbnails | `~/Library/Application Support/ComicArc/covers/` |

Your comic files are **never moved, renamed, or modified.**

You can export a full JSON backup — comics, progress, ratings, tags, and runs — and restore it at any time from Settings.

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

## Acknowledgements

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — CBZ archive extraction
- [unar / The Unarchiver](https://theunarchiver.com/command-line) — CBR extraction, bundled

---

## License

MIT. See [LICENSE](LICENSE). The license covers the application code only — not any content you import.
