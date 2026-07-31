# File & Folder Naming Guide

ComicArc reads your library structure directly from your file system —
there's no separate catalog to maintain. Two things determine how a
comic gets organized: **where the file sits** (folders) and **what the
file is called** (the filename).

## Folders → Publisher / Character / Series

Nest your comics up to three folders deep under your library folder:

```
Library/
  DC/                          ← Publisher
    Batman/                    ← Character (optional)
      Batman (2016)/           ← Series
        Batman (2016) #001.cbz
        Batman (2016) #002.cbz
```

- **1 folder deep** → treated as the Series name only (no publisher).
- **2 folders deep** → `Publisher/Series`.
- **3 folders deep** → `Publisher/Character/Series`. Only the first,
  second, and *last* folder are used — anything nested deeper than
  that still counts as the series' folder, so you can freely add a
  volume/year subfolder without breaking this.

There's nothing to fix here if you're not using the Character level —
`Publisher/Series/` is a completely normal 2-level layout.

**One volume per folder.** If a series has more than one volume — a
legacy relaunch, a new #1, a different creative run — give each volume
its own folder instead of merging them into one, e.g. `Batman (2016)/`
and `Batman (2011)/` as siblings, not both inside a single `Batman/`
folder. A lot of what ComicArc infers (series identity, edition,
issue ordering) comes from the folder a file sits in, so two unrelated
volumes sharing one folder is the most common cause of issues sorting
strangely or a rename producing an unexpected name. `Series (Year)` is
a well-supported convention for this.

## Filenames → Series name + issue number

Inside a series folder, name each file:

```
Series Name #123.cbz
```

- The **`#123`** is what ComicArc looks for first to figure out the
  issue number — it's the most reliable pattern. A bare number
  (`Series Name 123.cbz`) also works, but `#` is unambiguous.
- Decimals work too: `#12.1`.
- **Annuals, specials, one-shots**: include the word right in the name
  — `Series Name Annual #1.cbz`, `Series Name Special #1.cbz`. This is
  also what tells ComicArc to place it as a special in the reading
  order rather than a regular numbered issue.
- The **title** shown in the app is just the filename (minus the
  extension), so a clean filename directly means a clean title too.

### Supported extensions

`.cbz` and `.pdf` work on both Mac and iPad. `.cbr` works on **Mac
only** — CBR extraction needs a command-line tool (`unar`) that isn't
available inside the iOS sandbox. `.jpg`/`.png` also work, for
single-page files.

## Messy filenames? There's a cleanup tool

**Settings → Fix Filenames → Clean Up Filenames…**

This scans your whole library and shows you exactly what would change
(old name → new name) for every file that has underscores or repeated
spaces, letting you deselect anything you don't want touched before
applying anything. It only ever renames the file *within its existing
folder* — it never moves anything between folders, so your
Publisher/Character/Series structure is untouched. Two files that would
end up with the same name are automatically skipped and flagged, rather
than risking one silently overwriting the other.

This is a plain text cleanup of the filename that's already there —
underscores become spaces, repeated spaces collapse to one — nothing
more. It doesn't rename files based on series/issue metadata, so it
can't fix a genuinely wrong filename; it can only tidy up the one you
already have.

## Already have ComicInfo.xml metadata embedded in your CBZs?

ComicArc reads it as a fallback when the filename/folder structure
above doesn't give a clean answer — `Series`, `Publisher`, `Writer`,
`Penciller`, `Year`, `Month`, `StoryArc`, `LanguageISO`. **Folder and
filename always win when they disagree** — the assumption throughout
is that how you've organized your files on disk is more trustworthy
than whatever an old scrape wrote into an XML file years ago. If you
want ComicInfo.xml's `Year`/`Month` to also power chronological
placement of annuals in the reading order, no extra step is needed —
that already happens automatically wherever the data exists.
