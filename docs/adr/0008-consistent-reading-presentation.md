# ADR 0008: Consistent reading presentation

Status: Accepted by the owner, 2026-11-01; implementation and acceptance pending. Replaces the presentation concerns of the [withdrawn broad draft](0008-epub-reader-boundary.md) and complements [ADR 0007](0007-native-reader-and-epub-rendering.md).

## Context

The owner wants consistent reading presentation with Apple Books as the reference for raw reading quality. Reflowable EPUB styling varies across publishers. Normalization must preserve meaning and allow recovery when it harms a particular publication.

## Decision

Apply LibraVia typography, spacing, margins and colors by default to reflowable EPUBs. Preserve headings, emphasis, lists, illustrations, captions, links and reading order. Apply presentation through styling without rewriting document structure or invalidating saved locations and annotations.

Offer **Original Formatting**, remembered per book in its source/account namespace. It uses authored typography and layout; reader theme and accessibility controls remain available. Clearly indicate which typography controls apply in this mode. Store preferences separately and never modify the source book.

Identify fixed-layout EPUBs and preserve their authored composition instead of applying reflowable typography normalization. PDF and comic page pixels retain their composition as well.

## Alternatives and consequences

Publisher-first styling does not deliver the chosen consistent default. Uniform styling without an escape hatch makes unusual books difficult to recover. A per-book fallback adds compatibility work while supporting consistent prose reading and authored presentation where needed.

## Migration and verification

Existing books use LibraVia styling unless explicitly switched; adding the preference preserves positions, bookmarks and annotations. Recompute disposable page counts after styling changes while preserving the current passage. Test prose, headings, emphasis, lists, captions, illustrations, links, embedded fonts, complex styling and fixed-layout books. Verify both modes, reopening, unchanged source files and anchors after reflow.

Compare representative books with Apple Books on the same device with comparable typography and theme. This accepted policy is not evidence that Original Formatting or fixed-layout handling is complete.
