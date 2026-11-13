# ADR 0009: Native selection and durable annotations

Status: Accepted by the owner, 2026-11-01; implementation and acceptance ongoing. Replaces the selection/persistence concerns of the [withdrawn broad draft](0008-epub-reader-boundary.md). Complements [ADR 0007](0007-native-reader-and-epub-rendering.md); [ADR 0006](0006-icloud-and-user-book-folder.md) governs synchronization and sign-out.

## Context

Visible EPUB selection previously failed to produce a location because callbacks inside the script-disabled publication frame were unreliable. The owner confirmed native menu actions work on iPhone and Mac after capture was repaired. This does not establish the complete annotation lifecycle, accessibility, reflow, persistence or cross-device acceptance.

## Decision

Capture selection as a transaction containing its location, selected text, available surrounding context, edition fingerprint and source/account/book identity. Define its lifetime across menus, navigation and reflow; validate it when executing an action and reject stale or unavailable selections. Keep publication scripts disabled.

Expose **Highlight** and **Add Note** through the native text-selection menu, preserving system actions. Interacting with an existing highlight must allow editing its note, changing color or underline style, removing only the note, or removing the entire annotation. Removing a note alone preserves its highlight. Provide a searchable collection with jump-to-passage and explicit export.

Save changes locally before acknowledging success or synchronizing. Persistence failure preserves recoverable input and reports the error rather than implying success. Preserve exact EPUB locations separately from provider progress and disposable page numbers. Scope reading data to source, account, book and edition; keep unavailable or changed-edition anchors visible for recovery rather than silently attaching them elsewhere.

Measure selection-observation reliability, latency and energy cost before choosing a long-term mechanism. The current 200 ms trusted-reader poll is an interim workaround, not a validated permanent design. Suppress unchanged events, respect reader lifecycle and prevent obsolete selections from affecting another book.

## Alternatives and consequences

A toolbar-only action fails the chosen direct-selection experience. Enabling publication scripts weakens isolation. Relying solely on the EPUB library selection callback reproduced a failure in a sandboxed fixture. A validated transaction supports native menus and recovery but requires explicit lifecycle handling and format-specific anchors.

## Migration and verification

Preserve existing annotations, bookmarks and positions. Add style/context data compatibly; legacy annotations remain readable/editable and absent context does not prove an invalid location. Test selection, menu actions, save/reopen, edit, color/underline changes, note-only/full removal, search, jump and export. Include cancelled editing, write failures, account/source switches, reflow and changed editions. Exercise actual selection capture without artificially emitting the library event.

Compare the annotation lifecycle with Apple Books. Record physical iPhone/iPad, native Mac, accessibility and persistence results separately. Local annotations are not currently synchronized through Jellyfin or iCloud; do not describe the existing local implementation as synced.
