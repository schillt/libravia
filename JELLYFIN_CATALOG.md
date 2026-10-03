# Jellyfin catalog capabilities review

Reviewed against the project's official Jellyfin Swift SDK 3.1.0 request/enum definitions. Availability of useful values still depends on each server's book metadata. SDK support alone is not proof that a particular collection or book has populated metadata.

| Capability | Server representation | App treatment |
| --- | --- | --- |
| Continue Reading | GetResumeItems, user-scoped, Book item type | Home uses all accessible book libraries; first result is featured and remaining results appear in Also in Progress. Pagination is retained. |
| Similar books | Items/{id}/Similar, user, fields, limit | One bounded request for the featured book. Keep only Book items, exclude the seed and current resume list. Hide empty recommendations; offer retry on failure. No local recommendation index or invented matches. |
| Finished / Not finished | UserData.Played / GetItems.isPlayed | Existing filters retain the server's semantics. Mark as Read uses the official markPlayedItem endpoint; Mark as Unread uses markUnplayedItem. Both update visible local status without invalidating loaded catalog results. Not finished does not necessarily mean never started. |
| In progress | GetItems Filters=IsResumable | Existing contextual filter; Home uses the dedicated resume endpoint. |
| Author / writer, genre, tag | PersonIds + PersonTypes, Genres, Tags | Existing scoped metadata selectors remain. Different categories combine with AND. |
| Favorites | isFavorite / favorite user-data endpoints | Supported by SDK; candidate for a later filter/action, not automatically conflated with downloaded or finished. |
| Collections | Folder items in the selected Books library's mixed Book+Folder listing | The app calls these folders Collections. Some Jellyfin book listings omit these entries from a Folder-only query, so the app pages the same mixed listing used by All Books and keeps items with `IsFolder`. Their primary artwork is fetched through the regular item-image endpoint. Opening one keeps ordinary nested-folder/book navigation. This is distinct from Jellyfin BoxSets. |
| Sort | ItemSortBy and SortOrder | App retains Title A–Z, Title Z–A, Recently Added. Home uses server-side Random for a bounded session-held book selection, refreshed on startup or manual refresh, with a bounded recently-added fallback when no supported random books are returned. Author/Writer is not an ItemSortBy value; Artist is a music concept and should not be relabeled Author. |
| Format | No direct ebook-format selector on GetItems | Continue to omit format filtering rather than filtering individual downloaded pages. |
| Device availability | Local managed cache, not server metadata | Snapshot of complete cache entries, isolated by account. Viewing an indicator does not touch LRU timestamps. Device removal never calls a server deletion API and preserves reading state. |

New device-download actions use the existing validated, bounded cache. They do not pin a permanent offline library; copies remain subject to the 1 GB LRU budget or system cache reclamation. The active book cannot be removed. Completion marking is blocked while a reader/download is active and requires unsent local progress to be synchronized or resolved first.

First-party references:

- [Official Swift SDK 3.1.0](https://github.com/jellyfin/jellyfin-sdk-swift/tree/3.1.0/Sources)
- [Jellyfin GetItems SDK request](https://github.com/jellyfin/jellyfin-sdk-swift/blob/3.1.0/Sources/Paths/GetItemsAPI.swift) — parent scope, included item types, paging, and image metadata used for book folders.
