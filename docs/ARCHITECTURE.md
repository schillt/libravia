# LibraVia architecture

The current development candidate is a shared native SwiftUI app with a Jellyfin adapter and separate EPUB, PDF, and comic surfaces, including a dedicated Mac reader window. The 1.0 roadmap expands that foundation to multiple sources and capability-aware server and private iCloud sync. Planned components below are contracts for future work, not claims of implemented support.

## Current implementation

| Layer | Responsibility |
| --- | --- |
| `App/Core` | Models/provider protocols, app state, credentials, reading persistence, managed cache, archive validation, and catalog presentation. |
| `App/Jellyfin` | Official Jellyfin SDK requests and mapping server DTOs into core models. |
| `App/Readers` | Reader controls/controller, EPUB WebKit bridge, PDFKit, and comic image decoding/navigation. |
| `App/UI` | Login, Home/Library/Search, details, discovery, and settings. |
| `App/Resources/Reader` | Bundled EPUB.js renderer and local resource bridge; no runtime CDN. |

`AppModel` coordinates a single active Jellyfin account, book preparation, cache snapshots, local reading records, and coalesced progress writes. `ReadingStore` persists positions, bookmarks and annotations in account-scoped application support. Reader preferences are currently device-local. `BookCache` is an evictable, account-scoped 1 GB cache. Explicitly saved books and imported books use separate durable storage, and the account-scoped download queue survives restart.

EPUB stores an exact local CFI plus fraction. Jellyfin progress uses the adapter's numeric units, which do not preserve the exact CFI. PDF/comic records use page positions. The controller/renderer bridge handles commands, readiness, search, and location updates. Experimental private iCloud transport is connected for standalone originals and reading data, with separate Jellyfin reading-data recovery. Live recovery acceptance remains pending; see [the implementation audit](RELEASE_IMPLEMENTATION_AUDIT.md).

## Target boundaries

Core domain and storage depend on provider-neutral contracts. Provider adapters translate authentication, catalogs, acquisition, progress, and annotation operations into those contracts. They own server-specific DTOs, paging, errors, permissions, and location mapping. Views consume core models and capability snapshots rather than interpreting raw server responses.

Each saved connection has stable source/account identity. Book identity includes that namespace and provider item identity. Imported books receive local identity. Equal titles, paths, or ISBNs alone must not collapse distinct editions or sources. A migration preserves the current Jellyfin namespace and records; a reviewed rematch can reconnect unavailable items without silently overwriting another book's data.

Expose catalog, acquisition, progress, bookmark, and annotation capabilities independently. A provider can support reading while some reading data remains local. Advertised capability must reflect verified APIs and permissions for supported named versions; UI labels must not promise unavailable sync.

## Content and reading data

Keep validated content, essential metadata/cover, and reading data independently recoverable. Durable offline saves live outside disposable cache and remain until deliberate removal. Temporary/partial downloads cannot appear complete. Source/account checks apply before publishing any asynchronous result into the current session.

Local import uses security-scoped access to copy/validate a file into managed storage. The implemented user-selected home folder remains user-owned and must never be modified or deleted by device-copy management or Jellyfin sign-out. Server deletion is not part of device storage management. Bookmarks, positions, and annotations survive device-copy removal. See ADR 0006 for sign-out and iCloud requirements.

Annotations need stable IDs, source/account/book identity, format-specific anchors, selected text/context when available, note/color, modification state, and deletion records. EPUB anchors must survive reflow; PDF selections are page-based; comics and scanned PDFs use page notes. Changed editions or invalid anchors remain visible for recovery rather than attaching automatically to the wrong passage.

## Synchronization

Persist reading changes locally first, then queue supported writes. Each adapter owns conversion between local and server locations. Generic OPDS is catalog/acquisition access unless a verified extension supplies more. Exact CFI, percentages, page indices, and another reader's location string are not interchangeable.

Persist retry/acknowledgement state. Preserve conflicting note edits for resolution. Deletion records must prevent resurrection after delayed retries or another device reconnects. Authentication failure, unavailable items, disconnected servers, and unsupported operations have distinct states and actionable recovery. Private iCloud transport implements recovery for reading data Jellyfin cannot sync and standalone book files. It uses durable outboxes, conditional revisions, account/source/edition guards and explicit conflict review; Production/two-device/reinstall acceptance remains pending. See ADR 0006 and the implementation audit.

## Reader location contract

The accepted reader direction is [ADRs 0007–0010](adr/README.md), using Apple Books as the observable experience reference. These decisions include work not yet implemented or accepted: uniform typography with per-book Original Formatting, a complete annotation lifecycle, fast ordered turns and coherent reflow. The implementation details below describe the current reader; ADR acceptance is not runtime verification.

EPUB page numbers describe visible screens/spreads in the current viewport and typography, rather than printed-edition pages or rounded character percentages. Count a separate sanitized rendition, match the live layout, cancel obsolete counts, and publish only a complete current map. Wide paginated chapters start on complete spreads. Recount after viewport or typography changes; show counting/unavailable status until a valid map exists. Continuous scrolling reports percentage progress.

Persist exact EPUB CFIs and the existing provider-compatible progress fraction independently of the disposable page map. A page recount must never reset reading data or navigate the live reader. Scrubber destinations use chapter plus spread offsets after destination layout settles. Chapter labels come from publication navigation, not spine ordinals. Chapter decorations stay outside publication frames to preserve CFI node paths.

Verify compact and two-column pagination, exact scrubbing, reflow and isolated counting with native WebKit fixtures. Fixed-layout and vertical-writing count support, unusual publications, asset timing and large-book counting performance need explicit acceptance; never substitute character estimates for exact page numbers.

## Page-turn interaction contract

On iPhone/iPad, both the live and adjacent-preview WebKit views disable automatic UIKit content-inset adjustment: the trusted shell reserves hardware safe areas exactly once. The preview is non-scrolling and non-bouncing; the live view permits native scroll/bounce only in vertical mode. Keep the full-page preview and live viewport identical when hosted under native curl controllers.

On iPhone/iPad, card dragging uses an isolated sanitized WebKit rendition to prepare genuine adjacent-page images. Keep only the current/next/previous images, keyed by CFI, viewport and appearance. Invalidate obsolete work after navigation or reflow. The preview renderer cannot publish reading positions or provider progress. Peeking/cancelling leaves the live reader unchanged; release intent combines distance, velocity and reversal before committing one turn.

Accept rapid input while decoration settles. Interrupt card settling on new input and serialize live rendering, preserving ordered inputs with request IDs. Completed card gestures reserve FIFO entries while their native eligibility checks resolve; rejected selection/link gestures remove their entries. Preserve accepted entries and in-flight acknowledgement through visual/layout interruption. Queued card and fade turns use genuine warmed current-page images where available. Navigation no longer waits for a cold snapshot; card slides keep the outgoing image opaque instead of fading it. Non-card swipe eligibility also reserves FIFO entries. Cold-image fallback and physical animation still require acceptance. Bound paint waits because WebKit can suspend animation frames under native surfaces; renderer failure must release snapshots and report recovery rather than leave an input lock or silently retry an uncertain turn.

[ADR 0010](adr/0010-navigation-and-reflow.md) requires every completed, committed swipe to be honored quickly, exactly once and in arrival order, including direction changes. Valid pending turns cannot be replaced, dropped or capped merely because rendering is behind. Layout changes retain pending navigation; cancelled gestures and boundary attempts do not advance a page. Shortened or interrupted decoration must preserve all logical input. Compare and measure candidate behavior; the isolated rapid-card branch and its cold-capture delay are not accepted performance evidence.

Page curl is a separate iPhone/iPad option using UIKit's native page-curl controller. Its current page contains live WebKit content; adjacent pages use the same disposable preview cache. Native completion commits the live turn, cancellation preserves position, and central interaction/selection/link regions remain available. UIKit owns its gesture delegates. Mac exposes Fade as the fallback for a stored curl preference; Reduce Motion skips decoration. Physical edge/corner feel, rapid interaction, themes and accessibility require acceptance independently of builds and bridge tests.

Horizontal EPUB pages own their quiet chapter and progress labels inside the trusted page shell. Full-window preview images include those labels; the inset publication viewport remains the pagination/selection coordinate space. Book titles appear when controls are revealed. Chrome visibility is separate from typography preferences and does not itself redisplay a CFI. Horizontal mobile page surfaces span the full window, with physical window insets applied to content/control reservations once; curl content edges use a subtle fade unless increased contrast or Reduce Transparency requests hard boundaries; text and controls remain inset from hardware cutouts and the home indicator. Quiet mobile reading hides the system status bar, which cannot participate in a content transition. Search dismissal restores the publication insets and explicitly signals native preview preparation after layout and paint. Pause preview capture while search covers the document and bound keyboard-dismissal waiting so missing notifications cannot leave it frozen.

Install the bounded animation-frame scheduler before EPUB.js captures its frame callbacks: native delivery and a timeout race with single completion and cancellation. This allows layout queues to progress when WebKit is occluded. On Mac, serialize rendering updates rather than decorative transition completion, and coalesce resize bursts before recounting. Inspector resize waits for preceding page turns and EPUB.js's internal CFI redisplay queue; later turns wait for that reflow using captured preceding operations to avoid circular waits. Verify these contracts with `test_reader.js`, `test_reader_frame.js`, and the native pagination probe.

Direct viewport resizing now keeps EPUB layout live. An explicit native sidebar-transition command opens a bounded 450 ms eligibility window for one painted-page dissolve; intermediate inspector widths cannot repeatedly restart snapshots, and later direct resizing stays live. Sidebar/typography transitions dissolve without scaling glyphs. Reduce Motion bypasses these snapshots. This implementation still needs real-book, input-latency and visual comparison with Apple Books.

## Native UI and concurrency

Share models and reader commands while tailoring presentation to touch, keyboard, pointer, available space, and accessibility settings. Use compact sheets and sufficiently wide side panels. Keep controls outside reading content and avoid viewport changes merely to hide chrome. Respect VoiceOver, larger interface text, contrast, and Reduce Motion.

On Mac, the active book opens in one separate resizable reader window sharing the app-owned reading model. The library remains interactive; opening another book replaces the active reader rather than creating competing position writers. Window close, Command-W, cancellation and reader exit converge on `AppModel.closeReader()` to flush progress and release cache protection. A reader is not restored without an active book.

Search, contents/bookmarks/notes and appearance share a system SwiftUI inspector attached to the trailing window edge. The native inspector owns its material, column reservation and presentation rather than a custom rounded floating panel. Search, Appearance and Contents toggle the same inspector; tab switches preserve its width. Native Reader commands and keyboard shortcuts remain available. An explicit sidebar marker coordinates bounded EPUB reflow decoration with inspector changes. Visual transition, transparent-background cleanup and real-book reflow acceptance remain required; a native accessibility split group or compile does not prove the visual result.

A reader-region AppKit monitor follows deliberate EPUB trackpad displacement with a native snapshot over a provisional real destination. Release commits; reversal/cancellation restores the exact CFI without saving provisional progress. Resize and typography invalidate peeks. Momentum cannot advance another page. Scope input to the active reader window/content region, preserve sidebar scrolling and text/slider editing, and remove the monitor on teardown. Quiet reading hides chrome while configured chapter/progress information stays visible.

Native EPUB selection menus expose Highlight, Add Note and, for one linguistic word, Define through the system dictionary. Highlight saves directly; Add Note opens an editor and saves only when confirmed. Saved passages can open their editor from a click/tap; note-bearing annotations also have trusted-shell margin buttons. Colors and underline style are stored compatibly with legacy annotations, and a note can be removed without deleting its highlight. Publication structure remains untouched, and selected links/active selections retain their normal behavior. Full physical, accessibility and cross-format interaction acceptance remains open.

The Mac EPUB toolbar can arm a persistent highlighter in one of the supported colors. A selected toggle background, border and color bar indicate armed state; the adjacent popover shows only accessible color bubbles and a selected ring. A local AppKit monitor observes completed drags/double-clicks only in the active reader's actual WebKit hit target and returns events unchanged. After mouse-up, the trusted reader captures the final selection and echoes its mode generation; disarming or changing color invalidates older responses. Ordinary selection polling never saves a tool highlight. Escape/toggle disarms; teardown removes the monitor and restores cursor ownership. Normal reader click/annotation activation is suppressed while armed. The cursor is an outlined text I-beam with a small highlighter badge and an insertion-point hotspot. Actual pointer appearance and full keyboard/accessibility behavior require physical Mac acceptance; the owner has confirmed repeated drag highlighting saves.

UI state updates stay on the main actor. File validation, image decoding, and network operations must not block interactions. Cancel obsolete work and check source/session generation before publishing results. Do not allow a cancelled decode, search, or download to overwrite current content or reading state.

## Evolution and verification

Use additive migrations with meaningful restore/failure tests. Keep the existing archive/resource security boundaries. New dependencies need an accepted provenance/necessity decision. Changes to identity, storage lifetime, sync authority, supported platforms, or provider commitments require an ADR.

Test persistence, namespace isolation, retry/conflict handling, and provider contracts with synthetic fixtures. Measure representative performance separately from automated pass/fail checks. Physical interaction, two-device sync, real-server compatibility, and distribution acceptance remain distinct gates in `VALIDATION.md` and the milestone issues.

The persisted reader theme is the shared app color (Light, Sepia, Dark). Browsing canvases and EPUB paper use the same palette; native controls follow its light/dark scheme. Changing App color in reader Appearance updates browsing without a second preference or migration. Document artwork and PDF/comic page pixels retain their original colors.
