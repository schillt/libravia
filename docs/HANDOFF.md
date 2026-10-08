# Current development handoff

## Release checkpoint

Owner authorized v0.2.0 on alpha, 2026-10-08. Feature PR #59 reviewed `f62951a6e67778f2ababb641a74c0ab7fbf9e2ea`; alpha squash commit is `86b3fd02fb95cfc8f85d02246b61e82e85c1167a`. Resolve tag `v0.2.0` for the final version/documentation commit and inspect its release PR for exact checks. App/project generator version: 0.2.0/build 54.

Owned integrated scope: reader core/preferences/trackpad helpers; EPUB/PDF/comic surfaces, controller/chrome and Mac window; trusted renderer/frame scheduler; catalog layout; scene commands/project registration; tests and performance tooling; architecture/roadmap/agent guidance. Superseded drafts #42/#44/#45/#46/#47/#51/#52/#56 remain closed with retained-change references. Preserve their branches/worktrees and unrelated dirty main files until explicitly reconciled. Begin new work from refreshed alpha, not a stale draft branch.

## Evidence

70 core tests, reader/frame checks, three report tests, trackpad checks, production Mac build and native WebKit stress probe passed for the feature candidate. Security scan `95fd6ec3-b117-4aca-936b-eb2400a336a1` completed with no reportable vulnerabilities across31 changed files. This is static diff evidence, not runtime/distribution certification. See [VALIDATION.md](../VALIDATION.md), [release notes](releases/0.2.0.md) and [performance evidence](PERFORMANCE.md).

## Outstanding acceptance

Gate #28 remains open. Retest the reported real Mac book with sustained slider drags, repeated inspector toggles, navigation/search and close/reopen. Verify no lockup/quitting, blank gutters, stale locations or text flicker. Test physical trackpad direction/reversal/cancellation and Reduce Motion separately from fixtures.

On physical iPhone, check curl behind visible controls, safe-area edges, title/chapter duplication, search-dismiss navigation and chapter scrub haptics; retain exact installation SHA. Complete physical iPad, VoiceOver/larger-text/keyboard/contrast, PDF selection/links/resize and comic zoom/pan/navigation coverage. Existing live-server, signed archive/privacy and cross-installation sync checks remain distinct gates. Never close an issue merely because #59 merged.

## Next work

Prepare milestone 0.3 durable offline storage separate from evictable cache, local EPUB/PDF/CBZ import and recoverable downloads. Inspect the assigned issue and dependencies first; preserve source/account/book identity and existing positions/bookmarks. Provider feasibility research can proceed independently. UI polish remains ongoing in each release.

Merges/promotions require fresh owner authorization; this release approval does not authorize later work or promote beta/preview/main. No binary upload/install is part of the release closeout.
