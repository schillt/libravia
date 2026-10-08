# LibraVia architecture decisions

ADRs preserve why a consequential decision was made, its constraints, and its effects. Accepted decisions govern future implementation; they do not imply the described capability already exists. See `docs/ARCHITECTURE.md` for current implementation status.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-native-apple-platforms.md) | Native OS 27 app with tailored iPhone/iPad/Mac experiences. | Accepted |
| [0002](0002-source-identity-and-capabilities.md) | Separate source libraries and explicit provider capabilities. | Accepted; expansion planned |
| [0003](0003-durable-offline-and-reading-data.md) | Durable offline content separate from disposable cache and reading data. | Accepted; durable downloads planned |
| [0004](0004-existing-server-sync.md) | Local-first reading changes with supported existing-server sync. | Accepted; annotation sync planned |
| [0005](0005-release-branches-and-acceptance.md) | alpha → beta → preview → main with independent acceptance gates. | Accepted |

Add the next numbered ADR for changes to source identity, storage lifetime, sync authority, platform support, dependencies, or provider commitments. State context, decision, alternatives, consequences, migration, and verification. Mark proposals **Proposed** until the owner accepts them. Supersede earlier ADRs explicitly rather than silently rewriting their rationale. Routine implementation choices do not need separate ADRs.
