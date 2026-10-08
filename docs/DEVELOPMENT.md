# LibraVia development workflow

GitHub issues define work and acceptance; PRs define concrete changes; the project board records disposition. Repository guidance and ADRs let another engineer or agent continue without relying on a particular chat. Current explicit owner instructions take precedence.

## Branches

| Branch | Purpose | Incoming PRs |
| --- | --- | --- |
| `alpha` | Feature integration and daily development. | Focused issue branches; normally squash merge. |
| `beta` | Feature-complete milestone testing. | Owner-authorized promotion from an exact tested `alpha` candidate. |
| `preview` | Frozen release-candidate acceptance. | Owner-authorized promotion of the accepted `beta` candidate. |
| `main` | Accepted stable releases. | Owner-authorized promotion of the accepted `preview` candidate. |

Create issue branches from current `alpha`: `feature/<issue>-<description>`, `fix/<issue>-<description>`, `research/<issue>-<description>`, or `docs/<issue>-<description>`. Do not pre-create a branch for every future issue. Reuse assigned worktrees and preserve unrelated changes. No force pushes or deletion of the four long-lived branches.

All four branches require PRs and resolved review conversations; administrators are covered. `alpha` requires linear history. No required CI context is configured until a real compatible workflow exists and passes. Zero GitHub-required approvals avoids an impossible self-approval requirement for a solo owner; it does not authorize an agent to merge. Owner authorization controls merge and promotion.

## Issues and board

Each issue states the outcome, acceptance criteria, dependencies, and handoff requirements. Assign one outcome to a focused PR; split work when independently reviewable changes become large. Use milestone, area/type labels, and P1/P2 priorities. P0 means urgent data loss/security/core failure; P1 blocks the active milestone; P2 is planned work; P3 is optional/deferred.

| Status | Meaning |
| --- | --- |
| Backlog | Defined future work; dependencies or sequencing prevent starting. |
| Ready | Scope and prerequisites are clear; implementation may start. |
| In progress | An agent or engineer is actively implementing. |
| In review | Draft/ready PR is being reviewed or revised. |
| Acceptance | Implementation is integrated; required device/server/release evidence remains. |
| Blocked | Record the concrete blocker and next unblock action in the issue and Blocker field. |
| Done | Criteria pass or the owner records a scoped acceptance exception. |

Do not close an issue just because its PR merged. A milestone's gate issue independently verifies the aggregate outcome. No dates are imposed; version progression is quality-led. Update board status explicitly until repository/project automation is intentionally configured.

## Pull requests

Open drafts early enough to make the work inspectable. Target `alpha`; link `Refs #<issue>` and its milestone. Use closing keywords only when completion is actually accepted and automatic issue closure is intended. GitHub closing behavior on non-default branches must not be used as an acceptance workflow.

Lead with the concrete problem and resulting behavior. Include owned scope, migration/data effects, dependencies, relevant validation, and unverified limits. Keep public evidence sanitized. Request ready-for-review only when implementation checks pass; preserve draft status when required checks or blocker resolution remain.

The owner authorizes merges. Use squash merge for focused issue PRs into `alpha`. Promotion PRs use merge commits to preserve ancestry; never squash the promotion branches together. Delete merged issue branches only when their work/handoff is retained; keep all four long-lived branches. Backport fixes through reviewed PRs and record which candidates change.

## Validation

Use the regular Xcode 27 toolchain and record `xcodebuild -version`. Run only the checks relevant to changed behavior. Core/storage/provider work uses meaningful Swift tests; EPUB bridge changes use `node scripts/test_reader.js`; UI/renderer changes need destination builds and scoped interaction checks. README contains current commands. Use disposable build/test output and run destination builds sequentially when sharing DerivedData.

Documentation/templates/project-board changes need link/content checks and `git diff --check`, not app builds. Do not start hosted release gates for routine patches. Add required CI contexts only after a compatible workflow is implemented and demonstrated; never require a fictional check.

Report automated, compile, simulator, native Mac, physical iPhone/iPad, live-server, signed archive, and distribution evidence separately. A passed build cannot establish accessibility, sustained reading, audible behavior, or two-device interoperability. Do not bump marketing/build versions or distribute a build without that scope being requested.

## Handoff record

Use this in the issue/PR when pausing or completing work:

```text
Issue and linked acceptance gate:
Branch and checkout/worktree role:
Exact full commit SHA (or explicitly uncommitted):
Owned files and behavior changed:
Checks run and results:
Physical/server/distribution evidence:
Unverified limits and concrete blockers:
Next action and authorization needed:
```

Do not publish private workstation paths or identifiers. If local uncommitted work exists, identify it by repository-relative files and describe whether it is exploratory or verified. Another agent must inspect the working tree and exact issue before continuing.
