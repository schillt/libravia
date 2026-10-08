# ADR 0004 Existing server reading data sync

Status: Accepted. Date: 2026-10-08. Implementation: Jellyfin progress exists; multi-provider and annotation sync planned.

## Context

The owner requires synced everyday highlights/annotations through existing servers, accepts capability differences, and excludes a required iCloud backend or LibraVia companion service. Generic OPDS access does not imply writable annotation support.

## Decision

Persist changes locally first and synchronize only verified supported operations through provider adapters. Preserve local unsupported data, precise anchors, pending changes, and conflicts. Keep imported-book data local in 1.0. Begin annotation-sync feasibility with Kavita; verify named server versions and location interoperability before promising support.

## Alternatives and consequences

iCloud or a companion server could unify sync but conflicts with the chosen hosting boundary. Universal server sync would require unsupported APIs. Capability-aware sync means some sources only synchronize progress while notes remain local. Queues, acknowledgements, deletions, and conflicts need durable state and meaningful tests.

## Verification

Test two-device/server round trips, simultaneous offline note edits, retries, partial failures, expired credentials, missing/replaced books, duplicate avoidance, invalid anchors, and deletion resurrection. Do not equate percentages, CFI, or another renderer's location strings without a validated mapping.
