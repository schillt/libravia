# Reader performance evidence

Issue #5 contributes to acceptance gate #28. Baselines measure specific operations against an exact candidate; they do not establish complete physical reading acceptance. Keep this document and the sanitized JSON report together when comparing future candidates.

## Reproduce isolated measurements

Use Xcode 27 on macOS 27. The harness uses Python's standard library, Apple PDFKit/ImageIO/WebKit, the repository's bundled renderer and original CC0 Harbor fixtures. It downloads nothing and never opens a server account. It does not change app preferences, reading records, versions or signing configuration.

```sh
xcodebuild -version
python3 -m unittest discover -s scripts/performance -p 'test_*.py'
python3 scripts/performance/run.py --output /tmp/libravia-framework-baseline.json
# Native WebKit needs an available desktop session; do not automate unlocking.
python3 scripts/performance/run.py --epub --output /tmp/libravia-renderer-baseline.json
```

Use `--iterations 20` for follow-up comparisons. Output is JSON with full candidate SHA, dirty-tree flag, OS/toolchain, hardware model without device identifiers, original fixture hashes, characteristics, raw samples and summaries. Never substitute a report from a different candidate. A dirty-tree report identifies committed runtime plus local harness changes; record the harness commit separately in the handoff.

Each fixture runs in a fresh probe process. The first metric sample includes initialization; subsequent samples are warm in that process. OS filesystem caches remain uncontrolled: this is **not** a cold-storage/device benchmark. `summary` includes every sample; `warm_summary` excludes the first sample. P95 uses nearest rank, so ten samples' P95 is the maximum. Opening the EPUB renderer supplies one fresh-process sample per fixture per run, not ten open samples. Run three separate reports to compare opening consistently. Timing compilation, fixture generation and archive extraction are excluded.

EPUB startup has a 40-second failure bound and every subprocess has a 45-second bound. Missing, failed or timed-out measurements return `unavailable` and a nonzero runner exit; they never become zero milliseconds. Zero-valued successful DOM-selection samples reflect WebKit timer resolution, not instantaneous user interaction. Reports suppress raw errors and local paths; keep raw diagnostics private if investigating.

## Fixture matrix and metric meaning

| Fixture | Characteristics | Measured operation | Excluded from evidence |
| --- | --- | --- | --- |
| Harbor EPUB | Two text chapters, 60 paragraphs, Georgia 20 pt, 375 × 700 viewport | Renderer document load through `ready`; ten serialized native-turn render acknowledgements; publication search; DOM range/selection construction | Download/extraction, exact page-map completion during opening, UIKit animation, visible-frame/gesture latency |
| Harbor long EPUB | Same original text repeated 20 times: two chapters, 1,200 paragraphs | Same renderer operations, after complete page map for navigation measurements | Images/unusual layout, large spine counts, fixed layout, vertical writing; search result cap remains 200 |
| Harbor PDF | Three text pages | PDFDocument open; first-page 375 × 700 thumbnail render; all-document search; text selection construction | PDFView scrolling/zoom, search UI and pointer/touch selection |
| Harbor long PDF | 180 copies of the original first PDF page | Same PDFKit operations | Independent source complexity, scanned pages, mixed page sizes and PDFView navigation |
| Harbor CBZ | Three 800 × 1,100 PNG pages | Forced ImageIO decode of the first extracted page | CBZ preparation, comic page navigation, image presentation, large comic memory |

The generated stress fixtures live only in disposable output. Source fixture hashes identify the original assets; the long-fixture expansion is deterministic in the harness. Text repetition is a scaling probe, not a substitute for a diverse publication corpus. Reading locations in this isolated process are disposable and never reach app storage or a provider.

## Baseline checkpoint

The dated baseline is in `performance/2026-10-08-baseline.json`. Its candidate and environment are authoritative; all values are isolated framework/renderer evidence. The baseline was captured with locally added harness files and unchanged runtime at candidate `6a59dcd700fdb24f59d25f480867ace77039327f`, on arm64 Mac15,6, macOS 27.2, Xcode 27.0 (27A266a). Initial and warm measurements are separate in the report. Do not use these Mac timings as iPhone/iPad targets.

| Fixture / metric | First sample (ms) | Warm median (ms) | Warm P95 (ms) |
| --- | ---: | ---: | ---: |
| Harbor.pdf / document_open_ms | 59.32 | 0.24 | 0.38 |
| Harbor.pdf / first_page_render_ms | 6.47 | 1.04 | 1.18 |
| Harbor.pdf / search_ms | 1.29 | 0.61 | 0.68 |
| Harbor.pdf / selection_construct_ms | 0.01 | 0.00 | 0.01 |
| Harbor-long.pdf / document_open_ms | 49.30 | 1.51 | 1.70 |
| Harbor-long.pdf / first_page_render_ms | 6.44 | 1.15 | 1.25 |
| Harbor-long.pdf / search_ms | 30.49 | 28.94 | 29.67 |
| Harbor-long.pdf / selection_construct_ms | 0.01 | 0.01 | 0.01 |
| Harbor.cbz / image_decode_ms | 9.31 | 3.40 | 3.69 |
| Harbor.epub / open_renderer_ready_ms | 517.77 | — | — |
| Harbor.epub / search_ms | 5.00 | 4.00 | 4.00 |
| Harbor.epub / selection_construct_ms | 3.00 | 0.00 | 0.00 |
| Harbor.epub / turn_render_ms | 57.00 | 63.00 | 64.00 |
| Harbor-long.epub / open_renderer_ready_ms | 349.51 | — | — |
| Harbor-long.epub / search_ms | 31.00 | 26.00 | 27.00 |
| Harbor-long.epub / selection_construct_ms | 0.00 | 0.00 | 0.00 |
| Harbor-long.epub / turn_render_ms | 41.00 | 40.00 | 43.00 |

For subsequent 0.2–0.8 work, reproduce the same fixture/viewport/appearance on the same hardware with three baseline/candidate paired runs. Preserve opening first samples and warm distributions separately. Start performance review when repeated candidate medians or tail values exceed the corresponding observed baseline range; investigate initialization, reflow, asset loading and background conditions before calling it a regression. The recorded medians/P95 are provisional local reference targets to maintain or improve, not required-check thresholds. Ten samples and one opening per fixture are insufficient to justify universal latency limits. Set numeric physical platform budgets in #28/#5 after the matrix below is measured and the owner accepts them.

## Remaining app and device acceptance

| Measurement | Reproducible acceptance procedure | Evidence still needed |
| --- | --- | --- |
| Cold and warm opening | Original EPUB/text PDF/scanned PDF/large CBZ already locally available; restart app for first run, reopen for warm run; measure invocation through first readable content, then location-ready separately | Physical iPhone/iPad and native Mac, three runs each; cache/storage policy, book size/page/asset characteristics |
| Page navigation | Ten taps, drags, reversed/cancelled peeks, and rapid repeated turns across chapters; capture input-to-readable-frame and dropped/doubled turns; record page mode and refresh rate | Actual app, each platform, card/curl/instant/vertical as supported; main-thread stalls and frame pacing |
| Search and selection | Same original passage/query at beginning/middle/end; measure query through visible results and selection through handles/menu; repeat after type/viewport reflow | EPUB/text PDF UI and input; scanned PDF/comic selection is unsupported |
| Library scrolling | Synthetic account/catalog with 2,000 items, original artwork and mixed title lengths; same cached/warm image policy; scroll for 30 seconds while loading and after load | Native app frame pacing, memory and stalls; no personal-library screenshots or account data |
| Large content | Original/public-domain image-heavy EPUB, many-chapter EPUB, scanned PDF, large varied comic | Fixture licensing/provenance, decoded dimensions and memory, cancellation/recovery; small-fixture success is insufficient |

Record build configuration, format, viewport/orientation, font/line spacing/margins, Reduce Motion, motion mode, thermal/power state and background workload alongside aggregate timings. Hardware model/OS is sufficient; omit serials, device IDs, private URLs and account identifiers. An Instruments trace/video can be local evidence, but sanitize it before any sharing. Store exact SHA and material gaps in the issue/PR. Keep #5/#28 open until their complete criteria pass or the owner records an explicit scoped exception.

## Feasible CI, without invented required checks

The portable bridge and harness-report tests can run without Apple hardware:

```sh
node scripts/test_reader.js
python3 -m unittest discover -s scripts/performance -p 'test_*.py'
```

For Apple checks, GitHub currently documents an **`xcode-27` public-preview image on macOS 27**, not simply `macos-latest`. Check the current [runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) and [GitHub announcement](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/) before adopting it. Hosted availability/toolchain drift and this repository's successful execution remain unverified here. Standard macOS 26 labels cannot run a package whose minimum macOS is 27 merely because an Xcode SDK is installed.

Proposed first hosted job: read-only `contents` permission, PR trigger into `alpha`, pinned compatible runner/toolchain, `xcodebuild -version` and OS context, bridge/report checks, native Swift package tests, sequential unsigned Mac/iOS Simulator builds. Use isolated scratch/DerivedData paths and no secrets/signing, uploads, release workflow or version changes. Native WebKit performance should be diagnostic, with an unavailable session recorded separately; hosted timing is not a physical performance gate.

Current local commands (run proportionately to actual changes):

```sh
swift test --build-system native --scratch-path /tmp/libravia-core-tests
xcodebuild -project JellyfinBooks.xcodeproj -scheme LibraVia -destination 'platform=macOS' -derivedDataPath /tmp/libravia-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project JellyfinBooks.xcodeproj -scheme LibraVia -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/libravia-build CODE_SIGNING_ALLOWED=NO build
swiftc scripts/test_reader_pagination.swift -o /tmp/libravia-pagination
swiftc scripts/test_reader_previews.swift -o /tmp/libravia-previews
# Extract only the original Harbor EPUB to a disposable directory, then:
/tmp/libravia-pagination App/Resources/Reader /tmp/libravia-publication
/tmp/libravia-previews App/Resources/Reader /tmp/libravia-publication
```

This change does not enable workflows or require branch checks. Only configure a required context after the real workflow has successfully run for the exact candidate and its name/toolchain is stable. Core tests/builds, renderer probes, hosted checks, simulator interaction and physical acceptance retain separate results. Documentation/performance-harness changes alone do not justify a release suite.
