# ADR 0006: iCloud reading data and user-selected book folder

Status: Accepted product direction; local implementation audited, live/platform acceptance pending. See [implementation evidence](../RELEASE_IMPLEMENTATION_AUDIT.md). Date: 2026-10-31. This supersedes the iCloud and imported-data exclusions in ADR 0004 and the local-only imported-data statement in ADR 0002.

## Decision

LibraVia must work without a self-hosted server. Users can select their own books home folder rather than being required to organize a LibraVia-specific folder. The selected source remains user-owned: reading, indexing, account sign-out, and removal of app-managed copies must not alter or delete the original files. App-managed working copies may be used for offline access and iCloud transfer. Access is mediated by platform security-scoped permissions, with clear recovery if access is lost.

Verify every reading capability against the supported Jellyfin API and named server versions. Use Jellyfin for capabilities it actually supports; use the user's private iCloud for unsupported reading data, including precise EPUB positions, bookmarks, highlights and notes. User-selected or imported book files and their reading data must also sync through iCloud so the standalone library can be restored on another device. Sync is local-first; unavailable iCloud must be disclosed and must not prevent local reading.

Jellyfin numeric progress and exact EPUB locations are not interchangeable. Preserve edition identity, conflict alternatives and pending edits; do not silently attach an annotation to a different edition, discard concurrent edits, or resurrect deleted data. iCloud records remain in the user's private account and are not a LibraVia-hosted service.

On Jellyfin sign-out, remove the account's local credentials, cached content, saved copies, queued downloads and local reading data, after disclosing unsynced-data consequences. Do not delete Jellyfin server files, iCloud records, the separate standalone library, or the user-owned book folder. Uninstall and platform Keychain behavior must be verified rather than assumed; never delete source files.

## Evidence and acceptance

Jellyfin 12.4 exposes numeric progress and played status through its standard user-data API; its inspected user-data model does not expose exact EPUB CFIs or annotations. This is source inspection, not live interoperability certification or a claim about third-party plugins. See [Jellyfin user data](https://github.com/jellyfin/jellyfin/blob/v12.4/MediaBrowser.Model/Dto/UserItemDataDto.cs), [playstate API](https://github.com/jellyfin/jellyfin/blob/v12.4/Jellyfin.Api/Controllers/PlaystateController.cs), and [Jellyfin Web EPUB handling](https://github.com/jellyfin/jellyfin-web/blob/v12.4/src/plugins/bookPlayer/plugin.js).

Before release, verify named Jellyfin versions and iCloud account transitions; import and folder access on iPhone, iPad and Mac; offline edits, retries, concurrent edits and deletions; edition changes; quota and interrupted uploads; two-device and reinstall restoration; sign-out with pending work; and unchanged user-owned source files. Establish actual CloudKit entitlements, privacy and distribution behavior separately. This decision is not evidence that sync or folder selection has shipped.
