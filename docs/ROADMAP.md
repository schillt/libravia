# LibraVia roadmap to version 1.0

LibraVia will be a beautiful native reading hub for iPhone, iPad, and Mac on Apple OS 27. Everyday readers can connect self-hosted libraries or import their own books, read offline, highlight passages, take notes, and synchronize the reading data their existing servers support. Version 1.0 is quality-led; milestones have acceptance gates rather than calendar deadlines.

## Product promises

- Read comfortably with immersive, responsive, platform-tailored readers.
- Bring your library through Jellyfin, OPDS, native Kavita/Komga access, and local import.
- Deliberately save books for reliable offline access.
- Keep highlights, notes, bookmarks, and exports.
- Understand each source's progress and annotation sync capabilities.

Libraries remain separate by source. **On My Device** is a separate local library whose reading data remains local for 1.0. Provider-specific capabilities are visible during setup and in settings.

## Milestones and gates

| Version | Outcome | Key work | Acceptance gate |
| --- | --- | --- | --- |
| 0.2 | Native reading experience | Consistent visual foundation; quiet controls; optional persistent reading information; adaptive contents/appearance panels; EPUB/PDF/comic navigation; performance baselines. | Sustained physical iPhone/iPad and native Mac reading with unobscured content, stable positions, and responsive interactions. |
| 0.3 | Dependable offline library | Durable downloads separate from disposable cache; download queue/retry/cancellation; storage management; local EPUB/PDF/CBZ import; offline metadata. | Restart without a network connection and open saved/imported books; device-copy removal preserves reading data and server files. |
| 0.4 | Multiple sources | Saved connections; separate source libraries; OPDS; native Kavita/Komga; BookLore/Storyteller feasibility. | Named real-server releases pass authentication, catalog/pagination, acquisition, download, and account-isolation checks. |
| 0.5 | Highlights and annotations | EPUB/text-PDF highlights and attached notes; editable bookmarks; comic/scanned-PDF page notes; annotation lists/search/jump; Markdown/JSON export. | Reading data survives relaunch, layout changes, and device-copy removal; locations and exports retain meaningful context. |
| 0.6 | Supported-server sync | Native progress/annotation adapters; offline queues; retry; conflict preservation; deletion recovery; capability/status disclosure. | Two-device/server round trips without silent loss, duplicate notes, or deleted annotations reappearing. |
| 0.7 | Library organization | Series order/next-book navigation; favorites; source-scoped reading queues; reading-status controls. | Predictable organization despite absent metadata, disconnected servers, and different provider capabilities. |
| 0.8 | Platform polish and accessibility | Complete iPhone/iPad/Mac tailoring; VoiceOver; larger interface text; Reduce Motion; keyboard/pointer flows; onboarding/recovery; performance targets. | Complete accessible reading journeys on each platform, measured against the 0.2 baselines. |
| 0.9 | Release candidate beta | Freeze feature scope; exercise provider/format/platform compatibility; triage beta defects. | Complete daily-use journeys and no unresolved release-blocking defects. |
| 1.0 | Trusted release | Freeze the exact candidate; validate distribution artifacts, privacy, licenses, documentation, and support. | Every product promise has acceptance evidence; no known reading-data-loss defect or broken core journey remains. |

Small patches can ship within milestones. UI and interaction improvements are ongoing release work, including releases without a dedicated design milestone. Track specific feedback as issues and validate accessibility, platform behavior, and reading-location stability alongside each change. Version numbers indicate accepted outcomes, not merely merged feature lists. Each milestone has separate implementation issues and an acceptance gate issue in GitHub.

## Native reading standards

In paginated readers, tap the left edge for the previous page, the right edge for the next page, and the center to toggle controls. Share a persistent edge-width setting across EPUB, PDF, and CBZ; preserve selection, links, and zoom gestures. Vertical EPUB scrolling keeps taps for controls. Track this in issue #43.

Default to quiet, content-first reading. Reveal controls predictably on demand and optionally keep title/progress visible. Persist appearance settings and prevent controls from covering content or repaginating the book on every visibility change.

| Platform | Tailoring |
| --- | --- |
| iPhone | Reachable controls, compact sheets, reliable touch gestures, and uncluttered reading. |
| iPad | Comfortable portrait/landscape layouts, adaptive side panels, annotation space, and keyboard support. |
| Mac | Native menus/shortcuts, pointer-friendly selection, resizable windows, sidebars, and reliable focus. |

Stable cover geometry, readable typography, coherent spacing, accessible contrast, and restrained motion apply throughout the roadmap. Catalog grid/shelf cards reserve two title lines and one metadata line in equal-width columns. Covers use a 2:3 container with fitted artwork, preserving source proportions; mixed artwork may have space around it. Full titles remain available in details and accessibility labels. Compact list covers scale together with interface text. Establish representative opening, page-turn, search, and selection baselines in 0.2; track regressions and set measured performance targets for 0.8.

## Provider commitment

Jellyfin, generic OPDS, Kavita, and Komga are committed source targets. Generic OPDS supplies catalog/acquisition access; sync requires a verified provider API or extension. [OPDS specification](https://specs.opds.io/opds-1.2)

Kavita is the initial annotation-sync candidate; location interoperability requires testing. Komga documents progress APIs, while annotation capability remains unverified. [Kavita API](https://www.kavitareader.com/docs/api/), [Komga progression documentation](https://komga.org/docs/openapi/web-pub-manifest/)

BookLore and Storyteller remain investigation targets. Record named versions, authentication, supported acquisition, location compatibility, writable reading-data capabilities, and maintenance cost before recommending native adapters. The owner accepts any additional native-provider scope. [BookLore repository](https://github.com/booklore-app/booklore), [Storyteller library data documentation](https://storyteller-platform.dev/docs/managing/organizing/)

## Acceptance and boundaries

Exercise connect/import → find → save offline → read → annotate → close/reopen → synchronize where supported → export. Include large/unusual EPUBs, text/scanned PDFs, large comics, missing metadata, expired credentials, interrupted downloads, low storage, simultaneous offline edits, and changed server items.

Version 1.0 supports DRM-free EPUB, PDF, and CBZ. Sync uses existing servers only. Audiobooks, immersive narration, DRM, OCR, advanced drawing tools, social features, automatic cross-source merging, a required iCloud backend, and a LibraVia companion service are deferred.

Implementation starts with 0.2. Provider feasibility work can proceed independently. Design, accessibility, and reliability are requirements in every milestone; 0.8 completes their cross-platform acceptance.
