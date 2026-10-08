# LibraVia release workflow

The release path is **alpha → beta → preview → main**. A milestone gate, a frozen commit, and explicit owner authorization control each promotion. Long-lived branches are not automatically synchronized and no branch name alone proves acceptance.

## Current source release

The owner authorized PR #59 into alpha and designated v0.2.0 on 2026-10-08. The reviewed feature source was `f62951a6e67778f2ababb641a74c0ab7fbf9e2ea`; squash integration is `86b3fd02fb95cfc8f85d02246b61e82e85c1167a`. Version metadata is 0.2.0/build 54. The `v0.2.0` tag identifies the final documentation/version commit; release notes are in [releases/0.2.0.md](releases/0.2.0.md). Publish it as an alpha prerelease, without binary assets or promotion of beta/preview/main.

This is an explicit source-release designation, not a claim that every milestone gate passed. Keep #28 and outstanding issue acceptance open until evidence or a specific owner exception exists. See [VALIDATION.md](../VALIDATION.md) and [HANDOFF.md](HANDOFF.md). Future merges/promotions still require owner authorization.

## Promotion procedure

1. Complete the relevant feature issues and record outstanding acceptance in the milestone gate.
2. Record the full candidate SHA, its intended source/destination branches, and actual validation. Create a uniquely named annotated release-candidate tag when the owner authorizes candidate freezing.
3. Open a draft promotion PR containing only the frozen candidate. If the source branch advances, use a temporary promotion branch pinned to the recorded SHA; do not substitute the moving tip.
4. Confirm the PR head and tree still match the candidate and verify required checks against that SHA. Include device/server/distribution limits and any scoped owner exception.
5. Obtain owner authorization for that concrete promotion. Merge by merge commit to preserve branch ancestry. Verify the resulting destination contains the intended candidate and excludes newer source commits.
6. Record destination SHA, gate state, and next acceptance step. No force push, automatic promotion, or unrelated source change belongs in this process.

| Stage | Required outcome |
| --- | --- |
| alpha → beta | Feature-complete milestone candidate; relevant local checks pass and known limitations are recorded. |
| beta → preview | Milestone functional, physical-device, real-server, accessibility, and recovery gates pass or have explicit scoped exceptions. |
| preview → main | Exact candidate receives final privacy/signing/distribution/support acceptance and owner release approval. |

Initially all branches point at the existing main foundation. Their creation is workflow setup, not a new release or evidence of beta/preview acceptance. The current v0.1.0 release remains the historical foundation.

## Candidate fixes

Create a focused fix branch from the affected stage, verify the change, and open a PR to that stage. Backport/forward-port through separate reviewed PRs as needed so the fix is not lost. Any candidate change invalidates affected previous evidence: freeze a new SHA and repeat only the relevant checks plus required release gates. Keep prior candidate records truthful.

## Distribution and completion

Source integration, signed archive validation, upload, processing, tester availability, App Store release, and GitHub release publication are separate actions and results. Authorization for one does not imply the others. Keep signing configuration and private artifacts out of the repository.

Validate entitlements, privacy manifests/declarations, dependencies/licenses, transport configuration, supported platform/format/provider matrix, migrations, offline failures, and support instructions against the exact final candidate. Update `VALIDATION.md` with aggregate results, not raw traces or private library data.

Close milestone gates only when the owner accepts their evidence. Version 1.0 requires all product promises to have demonstrated acceptance and no known reading-data-loss defect or broken core journey.
