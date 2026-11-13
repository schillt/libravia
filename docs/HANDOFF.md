# LibraVia 0.2.5 alpha handoff

Owner scope: publish the reader/native UI checkpoint as a 0.2.5 GitHub alpha prerelease and leave unfinished features/acceptance in 0.3. Marketing version 0.2.5; repository build 56. The exact release is identified by `v0.2.5`, not a moving branch tip. Gates #28 and #29 remain open.

Read [release scope](releases/0.2.5.md), [validation](../VALIDATION.md), [roadmap](ROADMAP.md), [privacy](../PRIVACY.md), [ADRs](adr/README.md) and the [release workflow](RELEASE.md). The original development checkout and its unrelated staged/workflow changes are preserved. This regular release checkout is based on GitHub alpha plus the verified runtime snapshot and explicitly copied tests/design references; no old branch was reset or discarded.

Delivered alpha scope includes native reader/catalog/details/inspector polish, frozen blurred EPUB resize presentation with a final dissolve, persistent Mac highlighter and native text-selection actions, local bookmarks/notes/highlights/export, screen-awake preference, and early offline/import/queue/folder functions. It does not establish dependable offline or cross-installation sync acceptance. iCloud foundations are not connected to working upload/restore; Jellyfin progress remains separate from local annotations.

Next 0.3 work: complete private iCloud book/reading-data synchronization and recovery, offline storage/import/queue/account failure testing, full format/tool/export/migration acceptance and physical/accessibility/performance checks. Reconcile #6–#9 and #15–#17 with #29; keep unsupported-server annotation adapters in 0.6. Reassess 0.5 around demonstrated remaining tool gaps.

Before release, finish exact-candidate automated checks, both platform builds and security diff review, then preserve candidate identity through alpha integration and the prerelease tag. TestFlight is a separate Cloud archive/upload/processing/availability checkpoint; the owner will trigger the intended workflow after source publication. No beta/preview/main promotion is part of this release.
