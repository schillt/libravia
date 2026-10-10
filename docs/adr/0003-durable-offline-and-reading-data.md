# ADR 0003 Durable offline content and reading data

Status: Accepted. Date: 2026-10-08. Implementation: reading data/cache exist; durable downloads/import planned for 0.3.

## Context

The current 1 GB managed cache may evict downloaded books. Version 1.0 promises deliberate offline access, local import, and preservation of reading data when a device copy is removed.

## Decision

Separate durable user-selected content from disposable cache and reading data. Copy/validate imports into managed storage. Persist essential offline metadata. Treat partial downloads as incomplete and retain saved books until deliberate removal. Device-copy removal preserves reading data and never deletes server content.

## Alternatives and consequences

Reusing the cache as an offline promise is simpler but cannot guarantee retention. Pinning every opened book without consent obscures storage use. Separate durable saves require storage management, recovery, and an explicit migration; existing cache entries must not silently become permanent saves. Account forgetting is a separate operation with defined data semantics.

## Verification

Restart without network access; open saved/imported books; exercise low storage, interruption, cancellation, account switching, and corrupt files. Verify removal retains positions/bookmarks/annotations and leaves server files intact.
