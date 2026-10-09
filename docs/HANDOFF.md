# Current development handoff

## Revised reader candidate

Issue #61 tracks production iPhone chapter/progress compression while turning horizontal card/curl pages. Branch `fix/61-mobile-preview-viewport` starts from alpha `7391c9c678316f9ee96c82857a0c51266fed1870`. Candidate keeps marketing version 0.2.0 and increments build to 55 in project and generator. The preview WKWebView now disables automatic content insets and native scrolling, matching the live full-page canvas; horizontal live/preview views disable native bounce, while vertical live scrolling retains bounce. This corrects an identified viewport-policy mismatch; direct production-device reproduction and fix acceptance remain required.

PR #62 contains the patch and release-documentation update; runtime candidate is `4259c7604a0d08b2e3af55f04e90719fb5e21a40`. Signed iPhone Release build, signature verification and installation passed; owner reports the build seems to work fine. iPhone 18 Pro / iOS 27.0 Debug simulator checks covered portrait/landscape, hidden/revealed controls, safe-area clearance, next-page navigation and settled rotation reflow. Full gesture acceptance remains open.

Do not include the unrelated local Xcode Cloud configuration. Compile, security review, installation and direct finger acceptance remain separate evidence in #61 and its PR. Test card/curl forward/back/cancel with controls visible/hidden, rotate/recount and check vertical scroll/selection/links. The owner explicitly authorized merging #62 into alpha and replacing the v0.2.0 source release for build 55. Resolve the revised tag for the final integrated SHA; the original build 54 alpha SHA is `7391c9c678316f9ee96c82857a0c51266fed1870`. The owner will perform TestFlight operations.

## Release checkpoint

Owner authorized v0.2.0 on alpha, 2026-10-08. Feature PR #59 reviewed `f62951a6e67778f2ababb641a74c0ab7fbf9e2ea`; alpha squash commit is `86b3fd02fb95cfc8f85d02246b61e82e85c1167a`. Resolve tag `v0.2.0` for the final version/documentation commit and inspect its release PR for exact checks. Current app/project generator version: 0.2.0/build 55; build 54 is historical.

Owned integrated scope: reader core/preferences/trackpad helpers; EPUB/PDF/comic surfaces, controller/chrome and Mac window; trusted renderer/frame scheduler; catalog layout; scene commands/project registration; tests and performance tooling; architecture/roadmap/agent guidance. Superseded drafts #42/#44/#45/#46/#47/#51/#52/#56 remain closed with retained-change references. Preserve their branches/worktrees and unrelated dirty main files until explicitly reconciled. Begin new work from refreshed alpha, not a stale draft branch.

## Evidence

70 core tests, reader/frame checks, three report tests, trackpad checks, production Mac build and native WebKit stress probe passed for the feature candidate. Security scan `95fd6ec3-b117-4aca-936b-eb2400a336a1` completed with no reportable vulnerabilities across31 changed files. This is static diff evidence, not runtime/distribution certification. See [VALIDATION.md](../VALIDATION.md), [release notes](releases/0.2.0.md) and [performance evidence](PERFORMANCE.md).

## Outstanding acceptance

Gate #28 remains open. Retest the reported real Mac book with sustained slider drags, repeated inspector toggles, navigation/search and close/reopen. Verify no lockup/quitting, blank gutters, stale locations or text flicker. Test physical trackpad direction/reversal/cancellation and Reduce Motion separately from fixtures.

On physical iPhone, check curl behind visible controls, safe-area edges, title/chapter duplication, search-dismiss navigation and chapter scrub haptics; retain exact installation SHA. Complete physical iPad, VoiceOver/larger-text/keyboard/contrast, PDF selection/links/resize and comic zoom/pan/navigation coverage. Existing live-server, signed archive/privacy and cross-installation sync checks remain distinct gates. Never close an issue merely because #59 merged.

## Next work

Prepare milestone 0.3 durable offline storage separate from evictable cache, local EPUB/PDF/CBZ import and recoverable downloads. Inspect the assigned issue and dependencies first; preserve source/account/book identity and existing positions/bookmarks. Provider feasibility research can proceed independently. UI polish remains ongoing in each release.

Merges/promotions require fresh owner authorization; this release approval does not authorize later work or promote beta/preview/main. No binary upload/install is part of the release closeout.
