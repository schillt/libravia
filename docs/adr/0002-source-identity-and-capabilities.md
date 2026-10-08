# ADR 0002 Source identity and capabilities

Status: Accepted. Date: 2026-10-08. Implementation: existing Jellyfin isolation; multi-source expansion planned.

## Context

LibraVia will read Jellyfin, OPDS, Kavita, Komga, and local files. The owner chose separate source libraries. Server APIs differ in catalog, download, progress, bookmark, and annotation behavior.

## Decision

Scope book/reading identity by source, account, and provider item. Keep On My Device separate and local. Expose provider capabilities independently and translate provider DTOs/locations inside adapters. Keep unsupported reading-data operations local with clear disclosure. Preserve existing Jellyfin records during migrations.

## Alternatives and consequences

A unified catalog with automatic title matching risks collapsing editions, account boundaries, and annotations. Universal sync claims exceed available APIs. Separate namespaces and explicit capabilities cost adapter/UI work but provide predictable ownership and truthful behavior. BookLore/Storyteller native support requires named-version feasibility and owner scope acceptance.

## Verification

Test equal titles across sources, multiple accounts on one server, server base paths, missing/replaced items, credential expiry, asynchronous source switching, and migration of existing positions/bookmarks.
