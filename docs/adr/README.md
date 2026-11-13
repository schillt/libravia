# LibraVia architecture decisions

ADRs preserve why a consequential decision was made, its constraints, and its effects. Accepted decisions govern future implementation; they do not imply the described capability already exists. See `docs/ARCHITECTURE.md` for current implementation status.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-native-apple-platforms.md) | Native OS 27 app with tailored iPhone/iPad/Mac experiences. | Accepted |
| [0002](0002-source-identity-and-capabilities.md) | Separate source libraries and explicit provider capabilities. | Accepted; expansion planned |
| [0003](0003-durable-offline-and-reading-data.md) | Durable offline content separate from disposable cache and reading data. | Accepted; durable downloads planned |
| [0004](0004-existing-server-sync.md) | Local-first reading changes with supported existing-server sync. | Accepted; annotation sync planned |
| [0005](0005-release-branches-and-acceptance.md) | alpha → beta → preview → main with independent acceptance gates. | Accepted |
| [0006](0006-icloud-and-user-book-folder.md) | Private iCloud sync and a user-selected books folder, including standalone reading. | Accepted direction; implementation pending |
| [0007](0007-native-reader-and-epub-rendering.md) | Local WebKit EPUB rendering, native ownership and Apple Books experience reference. | Accepted; implementation/acceptance ongoing |
| [0008](0008-consistent-reading-presentation.md) | Uniform reflowable typography with per-book Original Formatting. | Accepted; implementation/acceptance pending |
| [0009](0009-native-selection-and-annotations.md) | Native selection menus and durable, recoverable annotation lifecycle. | Accepted; implementation/acceptance ongoing |
| [0010](0010-navigation-and-reflow.md) | Honor every committed swipe quickly and in order; coherent reflow. | Accepted; implementation/acceptance ongoing |

The [former broad ADR 0008 draft](0008-epub-reader-boundary.md) is withdrawn and retained only for link/history continuity. Its concerns are distributed across ADRs 0007–0010. The one-active-plus-one-replaceable-pending-turn planning suggestion is withdrawn; ADR 0010 requires every committed swipe to be honored.

Add the next numbered ADR for changes to source identity, storage lifetime, sync authority, platform support, dependencies, or provider commitments. State context, decision, alternatives, consequences, migration, and verification. Mark proposals **Proposed** until the owner accepts them. Supersede earlier ADRs explicitly rather than silently rewriting their rationale. Routine implementation choices do not need separate ADRs.
