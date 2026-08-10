# ComicArc Reader: Clean-Sheet Rebuild Design

Status: design proposal, not yet implemented. Written 2026-08-07 after a full audit of the
existing `Views/Reader/ReaderView.swift` (Mac) and `iPad/iPadReaderView.swift` (iPad)
implementations, `Scanner/LibraryScanner.swift`, `Caches/PageCache.swift` /
`Caches/PageThumbnailCache.swift`, and the `DatabaseManager` persistence layer.

This document answers one question: **if the comic reader were rebuilt from scratch today, what
would it look like?** It is not a patch list. Sections 1-10 diagnose the current implementation;
sections 11+ design the replacement; the final section is a phased plan to get there.

---

## 1. Diagnosis: the current reader's real problems

These are architectural, not cosmetic. Each maps to a specific consequence.

1. **No `ReaderViewModel` at all.** `ReaderView` (~1300 lines) and `iPadReaderView` (~900 lines)
   are plain SwiftUI `View` structs, each holding 30-40 `@State` properties directly: navigation,
   zoom/pan, chrome visibility, autoplay, bookmarks, hero-transition animation, next/prev-issue
   lookups. There is no separation between *reading session state* (what page, what zoom),
   *UI presentation state* (is the toolbar showing), and *document identity* (what file, how many
   pages). Consequence: the view layer is untestable, and every piece of logic that should be
   shared (fit-mode/color-filter enums, next-issue lookup, progress-save debounce, zoom-clamp
   math, completion-gating) has been hand-duplicated between the two platform files — and drifted
   apart in the duplication (Mac has spread mode, a shortcuts sheet, zoom keys; iPad has none of
   those).

2. **Page decoding lives inside the library scanner.** `LibraryScanner.page(path:index:)` sits in
   a 932-line class whose primary job is metadata scanning, cover extraction, and CBR→CBZ
   conversion — the reader's actual hot path (decode page N) is a minor method on a class built
   for something else. This is a layering inversion: the reader depends on the scanner, when
   "decode page N of this open document" is a narrower concern the scanner should be able to
   depend on too, not the reverse.

3. **No document abstraction.** There is no type representing "this comic, opened, with N pages."
   Every page load re-derives the format from the file extension and re-opens the container
   (`Archive(url:accessMode:)` for CBZ, `CGPDFDocument(provider:)` for PDF) from scratch, every
   single call — for every prefetch, every scrub, every page turn. A comic that's actively being
   read is never represented as a live, open thing; it's re-discovered from disk every time.

4. **The page cache has no concept of memory pressure.** `PageCache` (`Caches/PageCache.swift`) is
   a hand-rolled `NSLock` + `Dictionary` + LRU array, capped at a *global* 30 entries — not
   `NSCache`. There is zero `DispatchSource.makeMemoryPressureSource` / memory-warning handling
   anywhere in this codebase (confirmed by search). On a 40MB-per-page oversized scanned CBZ, 30
   cached pages can exceed a gigabyte with no fallback when the system needs memory back.
   `PageThumbnailCache` correctly uses `NSCache`; the cache holding the *large* images does not —
   backwards from where the protection is needed most.

5. **No in-flight request deduplication.** Two requests for the same uncached page (a direct
   navigation racing a prefetch, or two fast taps) decode twice.

6. **Decoding is full-resolution CPU/ImageIO with no target-size awareness.** A 6000×9000
   scanned page decodes to its full pixel size (capped at 8000px) even when displayed at
   `fitPage` in a 1300×900 window — the full bitmap is decoded, then SwiftUI/AppKit throws away
   ~90% of those pixels scaling down for display. This is the single biggest lever on both decode
   latency and peak memory for large pages.

7. **Progress writes are synchronous on the main thread through a serial DB queue.**
   `DatabaseManager.queue` is one serial `DispatchQueue`; every reader progress write goes through
   `queue.sync` from the calling thread — for the reader, always main (gesture handlers,
   `onChange`). If that queue is busy (a concurrent library scan also serializes through it), a
   page turn can visibly stall waiting on SQLite.

8. **Two independently-maintained reader implementations, not one core + platform shells.** Not
   because Mac and iPad genuinely need different reading logic, but because there was never a
   shared layer to put the identical logic in.

9. **iPhone doesn't exist.** `TARGETED_DEVICE_FAMILY = 2` on the `ComicArcPad` target — this app
   is Mac + iPad only today. Any iPhone reader design below is new product surface, not a refactor
   of something that exists.

10. **Zero automated test coverage for anything reading-related.** 23 test files exist, all
    library/metadata/scanning-focused. No tests for cache eviction, navigation edge cases,
    progress persistence, or zoom math. The reader has been entirely hand-verified.

**Calibration**: after a prior fix pass (2026-08-07), the current reader's *behavior* is
reasonably solid for a single platform at a time — reliable progress persistence, correct
completion semantics, clamped zoom, decent CBR performance. The case for a full rebuild is the
*architecture underneath that behavior* (duplication, no shared core, no memory-pressure
awareness, no tests) and the ambition to add iPhone and close iPad's feature gaps without
duplicating logic a third time — not that today's reader is broken for existing users.

---

## 2. Guiding principles for the rebuild

1. **Instant page turns** — the reader must never visibly wait once a comic is open, on any
   format, on any device.
2. **One reading engine, three thin platform shells** — all reading logic (document model, page
   pipeline, cache, navigation state machine, progress rules) lives in a platform-agnostic core;
   Mac/iPad/iPhone are UI-only translators of platform input into calls on that core.
3. **Bounded, predictable memory** — the cache has a memory *budget*, not just an entry-count cap,
   and responds to system pressure automatically.
4. **The document is a first-class object** with a lifecycle (open → serve pages → close), not
   re-derived per call.
5. **Persistent state and ephemeral UI state are explicitly separate types** — the category error
   the current implementation makes (cramming both into `@State`) is the root cause of most of the
   duplication above.

---

## 3. Core architecture

Six layers, each with one owner and a narrow public surface:

```
┌──────────────────────────────────────────────────────────────┐
│  Platform UI (SwiftUI Views)          Mac / iPad / iPhone      │
│  — layout, gestures, chrome, platform affordances only          │
└───────────────────────────┬─────────────────────────────────┘
                             │ observes / calls
┌───────────────────────────▼─────────────────────────────────┐
│  ReaderSession (@Observable, platform-agnostic)                │
│  — the ONE view model; navigation + reading-mode + zoom state  │
└───────┬──────────────────────────────────────────┬────────────┘
        │                                          │
┌───────▼────────────────┐              ┌──────────▼───────────┐
│  ComicDocument           │              │  ReadingProgressStore │
│  (protocol + 4 impls)    │              │  (persistence rules)   │
│  — open, page N, count   │              │  — position/finish     │
└───────┬───────────────────┘              └──────────┬─────────────┘
        │ used by                                     │ backed by
┌───────▼────────────────┐              ┌─────────────▼──────────┐
│  PageStore (cache)        │              │  DatabaseManager          │
│  — decode, cache,          │              │  (existing, reused as-is) │
│    prefetch, evict          │              └────────────────────────────┘
└─────────────────────────────┘
```

### Ownership, explicit — what each component owns and does NOT own

- **`ComicDocument`** (protocol; `CBZDocument`, `CBRDocument`, `PDFDocument`,
  `ImageSetDocument`). Owns: format identification, page count, extracting one page's raw bytes,
  a cheap open-time validity check. Does **not** own: decoding to a displayable image (that's
  `PageDecoder`), caching, or reading position. Opened once per session (`ComicDocument.open(url:)
  async throws`), kept alive until eviction, explicitly `close()`d. Directly replaces
  `LibraryScanner`'s per-call re-opening.

- **`PageDecoder`**. Owns: turning a document's raw page bytes into a displayable, correctly
  oriented, resolution-appropriate `CGImage` — including the target-size-aware decode described
  in §8. Does **not** own caching or "which page is current."

- **`PageStore`**. Owns: the decoded-page cache (§8), prefetch scheduling, in-flight
  deduplication, memory-budget enforcement, pressure response. Talks to `ComicDocument` +
  `PageDecoder`. Does **not** own reading position or any UI state.

- **`ReaderSession`** (the one `@Observable`, shared verbatim by all three platforms). Owns:
  current page, reading mode (single/spread/scroll/RTL), zoom level + anchor (values, not raw
  gesture plumbing — §7), fit mode, chrome-visibility intent, autoplay state, the open comic's
  bookmark list, and the navigation state machine (`advance`, `jump`, issue boundaries). Talks to
  `PageStore` for images, `ReadingProgressStore` for persistence. Does **not** own gesture
  recognizers, view layout, animation curves, or anything AppKit/UIKit-specific — those live in
  platform shells, which translate raw input into calls on `ReaderSession`
  (`session.advance(by:)`, `session.setZoom(_:anchor:)`).

- **`ReadingProgressStore`**. Owns: the rules for what counts as genuine progress vs. a jump (the
  `suppressCompletionCheck` logic from the 2026-08-07 fix pass, formalized as a real, tested type
  instead of a `@State` flag threaded through six call sites per platform), debouncing, the
  `finished_at` sticky-completion semantics, and the async write path to `DatabaseManager`. This
  is the one piece of the current implementation that, after the last fix pass, is already
  structurally close to correct — the rebuild's job is to give it a proper home, not rewrite its
  rules.

- **`DatabaseManager`**: reused as-is underneath `ReadingProgressStore`. Already well-isolated
  behind a reasonable surface (`updateProgress`, `markFinished`, `nextComic`/`previousComic`,
  `seriesReaderPrefs`). No reason to touch it.

### Self-critique: risks in this shape

- **`ReaderSession` could become a new God object** if platform-specific translation logic (e.g.
  Mac keyboard-shortcut handling) leaks into it. Discipline required: `ReaderSession`'s public
  surface should be entirely "what," never "how a gesture produced it."
- **`@Published`/`@Observable` granularity matters.** If `ReaderSession` is one flat object, a
  zoom-level change could invalidate chrome that didn't change. Split into a couple of focused
  sub-structs (`NavigationState`, `ZoomState`, `ChromeState`) or lean on `@Observable`'s
  property-level access tracking (Swift 5.9+, available given `MACOSX_DEPLOYMENT_TARGET = 14.0`)
  instead of coarse-grained `ObservableObject`.
- **Migrating `LibraryScanner`'s format logic into `ComicDocument` is real work, not a rename.**
  The CBZ/CBR/PDF handling itself (ZIPFoundation, bundled `unar`, `CGPDFDocument`) is sound and
  should be *moved*, not rewritten from scratch — but moving it correctly, with the same edge-case
  handling (50MB per-entry cap, CBR archive-size cap, corrupt-page fallback), is a multi-day task
  on its own, not an afternoon's refactor.

---

## 4. Data flow: comic file → pixels on screen

```
1. User opens issue in library
     LibraryViewModel resolves Comic (existing, unchanged)
     → ReaderSession.start(comic:, initialPage:, runId:)

2. ReaderSession.start()
     → ComicDocument.open(comic.filePath)                 [async, off main]
         validates format, cheap header/listing check — does NOT decode any page yet
     → session.pageCount = document.pageCount
     → session.currentPage = ReadingProgressStore.resumePage(for: comic)   [clamped]
     → PageStore.request(document, page: currentPage, priority: .now)

3. PageStore.request(...)
     cache hit  → deliver immediately, same runloop turn if possible
     cache miss → dedup against in-flight requests for this key
         → decode queue: ComicDocument.pageData(index:) → raw bytes
                          PageDecoder.decode(bytes, targetSize: session.viewportSize) → CGImage
         → insert under memory budget → deliver on main actor

4. ReaderSession receives image → publishes → view renders
     → PageStore.prefetch(document, around: currentPage, mode: session.readingMode)

5. User navigates (any input) → platform shell calls session.advance()/session.jump(to:)
     → currentPage updates synchronously (UI must never wait on this)
     → PageStore.request() for the new page (already-prefetched ⇒ instant)
     → ReadingProgressStore.recordPosition(page:, isSequential:)     [async, debounced]

6. Sequential advance past the last page
     → ReadingProgressStore.markFinished(comic:)                    [sticky, async]
     → NextIssueResolver.next(after: comic, runId:) → advance or surface boundary

7. Session teardown (dismiss / background / crash-adjacent lifecycle event)
     → ReadingProgressStore.flush()   [synchronous best-effort]
     → PageStore.evict(document); ComicDocument.close()
```

Discipline: nothing downstream of step 2 blocks on step 2 being slow. Opening the document is the
only step allowed visible latency, and even that should show a page skeleton within ~16ms, never a
blank screen.

---

## 5. Caching & prefetching, designed from scratch

Two caches, kept deliberately separate — the current codebase's instinct here (`PageCache` vs.
`PageThumbnailCache`) is correct and carries forward, just re-homed and fixed.

### `PageStore` — decoded reading pages

- **Budget by bytes, not entry count.** A "30 pages" cap is meaningless when pages range 200KB to
  40MB. Track each entry's memory footprint (`width * height * 4`) as its `NSCache` cost; target
  ~150MB total, scaled down under memory pressure — a starting number to validate empirically
  against real device profiles (iPad base vs. Pro), not to treat as final.
- **Backed by `NSCache`, not a hand-rolled dict+lock.** Free automatic memory-pressure eviction,
  plus `totalCostLimit` maps directly onto the byte-budget idea. The current code reinvented
  `NSCache` badly for exactly the cache that most needed real `NSCache` behavior.
- **Prefetch window** depends on reading mode: paged single-page → 3 ahead / 1 behind (readers go
  forward far more than back, but "1 behind" covers the common accidental-overswipe); spread mode
  → same radius counted in spreads (2 images per step); continuous scroll → wider forward window
  (5-6 ahead, since scroll velocity can outrun a 3-page radius) and a tighter behind-window (1).
- **Prefetch triggers on navigation, not a timer** — request the new window, let cache-hit/dedup
  skip anything already warm.
- **Cancel in-flight prefetches on a far jump** (scrubber drag, page-number entry, filmstrip tap
  far from current page) before requesting the new window. The current implementation has no
  cancellation at all — a fast scrub queues decodes for pages already scrubbed past.
- **In-flight dedup**: a `[PageKey: [Completion]]` map; a second request for a key already being
  decoded attaches its completion instead of starting a new decode.
- **Eviction**: per-comic bulk evict on session end (as today), *plus* `NSCache`'s own
  automatic pressure-driven eviction running continuously — complementary, not redundant.
- **PDF**: prefetch stays disabled (renders are comparatively expensive, as today), but rendered
  pages *are* cached under the same budget rules — no reason PDF should be exempt from caching
  once rendered.

### `ThumbnailStore` — filmstrip/scrubber thumbnails

- Genuinely separate cache from `PageStore` (unchanged instinct from today's
  `PageThumbnailCache`) — prevents scrubbing from evicting actively-read pages.
- `NSCache`-backed, 300-entry cap (entry-count capping is fine here — thumbnails are small and
  uniform, unlike full pages where size variance is too big to ignore).
- Decode via the same target-size-aware `PageDecoder` path (ImageIO thumbnail generation), not
  today's decode-full-then-resize (`PlatformImage.resized` applied to a full decode) — wasteful.

**Not cached beyond these two**: no separate reader-owned cover cache — the reader borrows one
cover load from the existing library-grid `ThumbnailCache` for the hero-transition; that cache
stays a library concern, untouched.

---

## 6. Navigation & gesture model

**Core rule**: every input method reduces to the same small set of `ReaderSession` calls —
`advance(by: Int)`, `jump(to page: Int)`, `advanceIssue(_:)`. Platforms differ only in *which raw
gesture maps to which call*, never in what the call does. This directly removes the "two
independently-written page-turn implementations" problem.

- **Mac**: arrow keys / spacebar → `advance(by: 1)` (RTL-aware); trackpad two-finger swipe in
  paged mode → same, via a threshold `DragGesture` (kept — it's a reasonable primitive for a
  mouse+keyboard-primary platform); scroll/trackpad-vertical in scroll mode → native `ScrollView`,
  position observed via page visibility (kept); page-number popover / slider / filmstrip tap /
  bookmark "Go" → `jump(to:)`.
- **iPad**: native `TabView(.page)` swipe → `advance`/`jump` via selection binding (kept — native
  paging beats a hand-rolled drag gesture); tap-zones (left 25% / right 25% / center 50%) →
  `advance` / `advance` / toggle chrome (kept — a good, Kindle/Marvel-proven pattern);
  slider/filmstrip/bookmark → `jump(to:)`.
- **iPhone (new)**: same tap-zone + swipe model as iPad, tuned for one-handed use — proportionally
  *larger* tap zones than iPad (smaller screen rewards unambiguous hit targets more), chrome
  defaults to bottom-anchored/thumb-reachable rather than Mac/iPad's title-bar-adjacent top bar,
  scrubber becomes a compact bottom sheet rather than a persistent bar.
- **Universal, new**: every jump-style navigation marks the resulting position "non-sequential"
  for `ReadingProgressStore` — formalizing the 2026-08-07 `suppressCompletionCheck` fix as part of
  the navigation model itself, not a bolt-on flag. Completion is earned only by `advance()`-driven
  forward motion.
- **Reaching the end**: `advance()` past the last page is the one call with a different outcome —
  it asks a shared `NextIssueResolver` (series order, or run order if opened from a run) and
  either advances (current, deliberately-kept behavior) or reports a boundary. Decided once in
  `ReaderSession`, not duplicated per platform.

---

## 7. Reading modes — which ones earn their keep

**Keep**: single-page (default), two-page spread with automatic spread-detection (the existing
aspect-ratio heuristic, `width > height * 1.15`, is correct — keep it), fit width / height / page,
continuous vertical scroll, RTL/manga toggle. Each maps to a real, distinct behavior people
actually use.

**Don't build**: "actual size" as a distinct *mode* — it's one end of the zoom range (100%), not a
separate mode; today's `FitMode.original` (a mini scroll-view-within-a-page) is a confusing
hybrid better folded into zoom. Continuous *horizontal* scroll (rare; paged+swipe already covers
the need better on touch). A separate "webtoon mode" beyond what continuous vertical scroll
already provides — same thing, don't build two names for one behavior.

**Change from today**: bring two-page spread to iPad in landscape + `horizontalSizeClass ==
.regular` (the one deferred item from the last fix pass) — gated automatically, not a manual
toggle, since in the new architecture spread mode is just a `ReaderSession.readingMode` case with
a layout consequence in the platform shell, not new logic to port.

---

## 8. Zoom, redesigned

The prior fix pass patched the existing gesture-driven zoom (clamped pan bounds, removed an
animation/gesture fight). A rebuild changes the *shape* of the state, not just its bounds-checking:

- `ReaderSession` owns zoom as **two committed values**: `zoomLevel: CGFloat` and `zoomAnchor:
  UnitPoint` (0...1 normalized within the image) — not raw pixel offsets accumulated across
  gestures. A normalized anchor trivially survives a fit-mode change, window resize, or page
  change (reset to `.center` on page change, as today) without the pixel-offset math that made the
  last pass's clamp fix necessary in the first place.
- Platform shells translate raw gestures (`MagnifyGesture`, pinch, modifier+scroll) into
  `session.setZoom(level:, anchorInViewport: CGPoint)`; `ReaderSession` converts the viewport
  point to a normalized anchor and clamps `level` to `[1.0, 5.0]` — once, shared by all platforms,
  instead of the Mac/iPad each carrying their own copy of the clamp math (exactly what the last
  pass had to fix twice).
- Panning while zoomed is "the anchor moved" — a `DragGesture` calls `session.pan(by:translation,
  viewportSize:)`, converted to an anchor delta and clamped against image bounds in one place.
- Double-tap/double-click zooms to 2× anchored at the tap point — kept, now one shared call
  instead of separate hand-written math per platform.
- **New**: mouse/trackpad scroll-wheel zoom on Mac (⌘+scroll) — trackpad pinch already exists via
  `MagnifyGesture`, but a mouse user has no zoom gesture today. Same `setZoom` entry point.
- Changing fit mode or scroll-mode always resets zoom to `1.0`/`.center` — falls out naturally as
  one rule in `ReaderSession` rather than duplicated `.onChange` handlers per platform.

---

## 9. Reader UI — chrome vs. permanent

**Permanent**: nothing but the page itself.

**Auto-hiding chrome** (idle-timeout + tap/hover to reveal, both patterns already exist and are
kept): top bar (title, prev/next-issue chevrons, close), bottom bar (page position + scrubber,
page count). Reduced from today's Mac bottom bar, which crams prev/next buttons, a slider, a
page-jump popover trigger, *and* a star-rating control into one row — star-rating moves out of the
reader chrome entirely. Rating a comic is a library concern, not a reading concern, and the
original brief is explicit that the reader shouldn't feel like a library-management surface.
Reader settings (fit mode, RTL, color filter, autoplay speed) live in one overflow menu/sheet, not
scattered toolbar icons — today's implementation already trends this way; tighten it, don't add to
it.

**Fullscreen**: Mac enters true `NSWindow` fullscreen (kept). iPad/iPhone *are* fullscreen by
construction — no separate "enter fullscreen" affordance needed, immersion is the default state
(as today).

**Cursor**: hide-until-moved on Mac while chrome is hidden (kept, already correct).

**Platform differences, explicit**: Mac's chrome is title-bar-adjacent, hover-aware (chrome
reappears near top/bottom edges — kept); iPad/iPhone's chrome is tap-toggle only (no hover
concept), with iPhone's controls thumb-reachable per §6.

---

## 10. Reading progress & end-of-issue

The *rules* landed in the 2026-08-07 fix pass are correct; the rebuild's job is giving them a
proper home (`ReadingProgressStore`) instead of `@State` flags duplicated per platform.

- **Position saves are async and debounced by default** (250ms, matching today's slider debounce,
  now applied universally — the "synchronous on main thread except for the slider path"
  inconsistency in the current code is removed, not preserved). A crash loses at most ~250ms of
  position — an explicit, acceptable tradeoff, not an accident.
- **Session end always does a synchronous best-effort flush** (dismiss, background, scenePhase
  change) — the Mac scenePhase-save fix from the last pass, now expressed once in
  `ReaderSession.teardown()` shared by all platforms instead of per-platform lifecycle hooks.
- **Completion (`finished_at`) is earned only by sequential `advance()` reaching the last page** —
  the last pass's fix, now a first-class rule in `ReadingProgressStore.recordPosition(page:,
  isSequential:)` instead of a `suppressCompletionCheck` flag threaded through six call sites per
  platform.
- **Next-issue resolution** is one shared `NextIssueResolver`, called once by `ReaderSession`
  regardless of platform — given a `Comic` and optional `runId`, returns next/previous (run order
  or series order, exactly today's logic), prefetched (cover + first 2 pages) the moment a session
  starts.
- **Custom reading orders / runs**: already correctly modeled today (`runItems`, `runId`
  threading) — kept as-is, lookup relocated into `NextIssueResolver`.
- **Missing next issue**: boundary toast (kept — a good, low-friction pattern), no next-issue
  affordance shown.
- **File changed underneath the reader** (rescan changes page count, file's gone):
  `ComicDocument.open()` failing, or a saved position beyond a new smaller page count, shows the
  existing graceful per-page error state ("Couldn't load page N, Retry" — already reasonable) and
  clamps the resume position, centralizing the clamp logic already present in both readers' `init`
  into `ReadingProgressStore.resumePage(for:)`.

---

## 11. Performance & memory strategy

- **Decode at target size, not full-then-downscale** — the single biggest win. For
  `fitPage`/`fitWidth`/`fitHeight`, request an ImageIO thumbnail-decode sized to `viewportSize *
  screenScale`, not the full 8000px-capped original; only actual-size zoom needs full-resolution
  decode. Cuts peak decode time and peak memory dramatically for the common case (reading at fit,
  which is most reading), especially on oversized scanned pages.
- **DB writes off the main thread by default** — `ReadingProgressStore` dispatches async onto
  `DatabaseManager`'s existing serial queue for routine saves (removing today's `queue.sync` called
  from the main thread on every page turn); only the teardown flush blocks, briefly.
- **`NSCache`-backed `PageStore`** — the single highest-value memory fix, bigger than any budget
  tuning around it, since it's the difference between "responds to system pressure" and "doesn't
  at all."
- **Prefetch cancellation on fast scrub** — removes the current implementation's only real
  "wasted work" pattern.
- **In-flight dedup** — removes double-decode races.
- **CBR**: the 2026-08-07 fix (extract once per comic-open into a bounded temp-dir cache, instead
  of shelling `unar` per page) already solves the worst of CBR's performance profile. A rebuild
  keeps that approach, relocated behind `CBRDocument: ComicDocument` instead of a free function in
  the scanner.
- **Large/slow external storage**: `ComicDocument.open()` and page reads need an explicit timeout
  + a "this drive might be disconnected" error surface — not present today, where a stalled
  external volume can hang a page read indefinitely.
- **View-update efficiency**: with `ReaderSession` as one observable object, care is needed that a
  zoom change doesn't republish/re-render chrome that didn't change — split `@Published`/
  `@Observable` state into focused sub-structs, or lean on `@Observable`'s per-property tracking
  (available at `MACOSX_DEPLOYMENT_TARGET = 14.0`) instead of coarse `ObservableObject`.

---

## 12. Platform-specific designs

### macOS
Keyboard-first power-user surface — every navigation/zoom/mode action has a shortcut (kept, it's
genuinely good today), mouse-hover-aware chrome, true fullscreen, large-canvas two-page spread as
a first-class mode, filmstrip as a toggleable strip.

### iPad
Touch-first but keyboard-capable — external keyboards are common on iPad, and the shortcut set
should work here too (today it mostly doesn't: no zoom keys, no shortcuts sheet). Tap-zone
navigation, native paging, spread mode added in landscape+regular-width automatically (§7). Apple
Pencil/annotation is explicitly out of scope — not requested, doesn't serve "read comics better."

### iPhone (new)
Single-page only by default (spread mode doesn't make sense at this width). Tap-zones with larger
proportional targets than iPad. Bottom-anchored, thumb-reachable chrome rather than a top bar.
Scrubber as a compact bottom sheet. One-handed-first — this is the platform where "the UI gets out
of the way" matters most, given the smallest canvas-to-chrome ratio of the three.

**What's shared architecturally vs. platform-specific**: everything in §3's `ReaderSession` layer
and below is 100% shared. Platform-specific: gesture recognizers, chrome layout/placement,
fullscreen mechanics, keyboard shortcut tables, and the exact tap-zone/hover affordances.

---

## 13. Testing strategy

Because the core (`ReaderSession`, `ComicDocument`, `PageStore`, `ReadingProgressStore`) is
platform-agnostic and gesture-free, it becomes unit-testable without SwiftUI or XCUITest at all —
the single biggest practical win of this redesign, given today's zero reading-related test
coverage.

- **Unit**: `ReadingProgressStore` rules (sequential vs. jump, sticky completion, resume
  clamping — exactly the edge cases fixed 2026-08-07, now expressible as fast `@Test` functions
  with no UI); `PageStore` cache eviction/budget/dedup against a fake `ComicDocument`;
  `NextIssueResolver` series/run-order resolution; `ReaderSession`'s zoom clamp math.
- **Integration**: `ComicDocument` implementations against real fixture files (malformed CBZ,
  corrupt CBR, truncated PDF, oversized page) — extending the existing fixture-CBZ pattern already
  used by `ComicInfoWriteBackTests.swift`/`DatabaseTestFixture.swift`.
- **Performance**: decode-time and peak-memory benchmarks across representative files (small CBZ,
  huge scanned CBZ near the 8000px cap, large CBR, large PDF) via `measure {}` or Swift Testing's
  equivalent, run in CI to catch regressions.
- **UI**: a thin `XCUITest`/manual layer for gesture-wiring only (does a swipe call the right
  session method) — deliberately thin, since the logic it'd otherwise test is covered at the unit
  level already.
- **Cross-platform**: one `ReaderSessionTests` suite runs against all three platform targets,
  since the core has no platform-conditional code — impossible today, with two independent,
  untested implementations.

---

## 14. What to delete / replace / keep

**Delete outright**: duplicated `FitMode`/`ColorFilter` enum definitions (one shared definition);
per-platform zoom/pan `@State` clusters, replaced by `ReaderSession`'s zoom model; the
`suppressCompletionCheck` `@State`-flag pattern, replaced by `ReadingProgressStore`.

**Replace**: `LibraryScanner.page(path:index:)`'s inline format dispatch → `ComicDocument`
implementations; `PageCache` → `PageStore` (`NSCache`-backed, byte-budgeted); per-platform
next-issue lookup → shared `NextIssueResolver`.

**Evaluate, don't assume**: Mac paged mode's hand-rolled `DragGesture` page-turn — worth
evaluating whether it can also move to a `TabView`-like construct like iPad's, though Mac's
mouse+keyboard-primary usage makes the custom gesture more defensible there than it would be on
iPad. Route its output through `session.advance()` either way.

**Keep as-is**: `DatabaseManager`'s schema/query surface (already reasonable, including the
`finished_at` addition); `ThumbnailCache` (library-grid cover cache, correctly out of scope);
`PageThumbnailCache`'s `NSCache`-backed design (correct pattern — relocate under `ThumbnailStore`
for naming consistency, don't rewrite); the CBR-extraction-once and PDF screen-scale fixes from
2026-08-07 (both slot directly into `CBRDocument`/`PDFDocument`); the iPad tap-zone navigation
pattern; the boundary-toast pattern; the hero cover-morph transition (a genuinely good, already-
working piece of polish, purely a platform-shell concern, untouched by any of this).

---

## 15. Phased implementation plan

Ordered so each phase is independently shippable/testable, and later phases depend only on earlier
ones existing.

1. **`ComicDocument` protocol + 4 implementations**, tested against real fixture files. Ports
   `LibraryScanner`'s existing format-dispatch logic (sound as-is: ZIPFoundation for CBZ, bundled
   `unar` for CBR, `CGPDFDocument` for PDF) into real types — not a rewrite of the format handling,
   a relocation of it. *This alone is a multi-day task, not an afternoon refactor.*
2. **`PageDecoder`** (target-size-aware decode) + **`PageStore`** (`NSCache`-backed, byte-budgeted,
   deduped, cancelable prefetch) — unit-tested against a fake `ComicDocument`, no UI yet.
3. **`ReadingProgressStore`** — port the 2026-08-07 rules in as a real, tested type;
   `NextIssueResolver` alongside it.
4. **`ReaderSession`** — the `@Observable` core composing 1-3 plus navigation/zoom/mode state.
   Fully unit-testable at this point; no SwiftUI reader UI exists yet.
5. **Mac platform shell**, rebuilt on `ReaderSession` — highest-risk platform to get right first
   (most existing features to preserve: spread mode, full keyboard set, filmstrip, shortcuts
   sheet). Ship, verify feature-for-feature parity with today's Mac reader.
6. **iPad platform shell**, rebuilt on the same `ReaderSession` — closes today's feature gaps
   (spread mode, zoom keys, shortcuts sheet) essentially for free, since the logic already exists
   in the shared core.
7. **iPhone platform shell** — genuinely new, built last since it has no existing implementation
   to match parity against, and benefits most from 1-4 already being solid.
8. **Delete dead code** in `ReaderView.swift`/`iPadReaderView.swift` once 5-7 are verified at
   parity — not before.

Do not start any phase's implementation without this document being reviewed first; it's a
proposal, not yet an approved plan.
