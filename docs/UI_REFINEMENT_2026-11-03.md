# Reader and native UI checkpoint, 2026-11-03

The owner accepted the Mac visual pass as good enough for the 0.2.5 alpha checkpoint. This is scoped feedback, not acceptance of every platform/format or the 0.3 release gate.

The local development work includes native selection actions, annotation editing/color and persistent Mac highlighter controls; independent reader-control/inspector visibility; library/search/book-detail layout refinements; themed window chrome; and the iPhone/iPad screen-awake preference. For resizing, the current owner direction is a blurred frozen page while EPUB reflows behind it, followed by a final painted-layout dissolve. The native inspector retains its outgoing destination, has matching 260 ms smooth entrance/exit timing, and coordinates the fallback paper strip with full-page frozen coverage.

Release-source tests and archive results are recorded in [validation](../VALIDATION.md) and the exact candidate PR/release. Native fixture results establish ownership, ordering and fallback behavior; they do not prove sustained physical frame pacing. The latest physical iPhone/iPad matrix, all-format annotations/export/migrations, offline interruption/relaunch and live-server/iCloud recovery remain open under [0.3](ROADMAP.md). See [ADR 0010](adr/0010-navigation-and-reflow.md) and [0.2.5 release notes](releases/0.2.5.md).
