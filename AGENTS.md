# LibraVia agent guide

LibraVia is a native Apple OS 27 reading hub for DRM-free EPUB, PDF, and CBZ books. Start with the assigned GitHub issue and its latest comments. Current explicit owner instructions take precedence over repository guidance. Do not infer authorization to merge, promote, distribute, or publish a release from authorization to implement a feature.

## Current checkpoint

Version 0.2.0 is integrated on alpha; begin with [HANDOFF.md](docs/HANDOFF.md), [release notes](docs/releases/0.2.0.md) and [VALIDATION.md](VALIDATION.md). Gate #28 remains open. Do not recreate superseded PRs #42/#44/#45/#46/#47/#51/#52/#56 or treat their closure as completed acceptance. The next implementation milestone is 0.3, with reader acceptance and UI polish continuing.

## Read before work

- [Roadmap](docs/ROADMAP.md): product promises, milestones, and acceptance gates.
- [Architecture](docs/ARCHITECTURE.md) and [ADRs](docs/adr/README.md): current implementation, accepted decisions, and planned changes.
- [Development workflow](docs/DEVELOPMENT.md): branches, PRs, validation, and handoffs.
- [Release workflow](docs/RELEASE.md): alpha → beta → preview → main promotion.
- `SECURITY.md`, `PRIVACY.md`, and `CONTRIBUTING.md`: publication, data handling, and contribution boundaries.

## Before editing

1. Inspect working-tree status, current branch, full HEAD SHA, intended base, assigned issue, dependencies, and linked PRs. Reuse the assigned checkout or worktree and preserve unrelated dirty files.
2. Confirm the issue's scope, acceptance criteria, and provider/platform constraints. Check whether another implementation already exists before starting.
3. Create a focused issue branch from current `alpha`, such as `feature/12-immersive-reader`, `fix/12-position-restoration`, or `docs/12-architecture`. Never implement directly on a promotion branch.
4. Record the owned changes and intended checks. If blocked by missing access, server fixtures, or devices, complete independent work and record the concrete remaining gate.

## Implementation guardrails

- Keep Jellyfin and future provider DTOs inside their adapters. Core storage, identity, reading data, and reader commands must not depend on one provider's DTOs.
- Scope reading data by source, account, and book. Equal titles do not prove equal books. Preserve legacy positions/bookmarks during migrations.
- Save reading changes locally before network synchronization. Do not silently discard note conflicts, resurrect deleted annotations, or claim unsupported server sync.
- A cache is disposable; an explicitly saved offline book must eventually use durable storage. Until milestone 0.3 lands, current downloaded cache entries are not permanent offline saves.
- Device-copy removal must never delete server files and must preserve reading data. Sign-out/forget-account behavior is a separate, explicitly defined operation.
- Require no iCloud backend or LibraVia companion server for 1.0. Generic OPDS access does not imply annotation sync. BookLore and Storyteller native support remain investigation outcomes.
- Treat visual and interaction improvements as ongoing work in every release, even without a dedicated design milestone. Track concrete UI reports as issues, include proportional accessibility and platform acceptance, and preserve previously accepted reading behavior. Milestone 0.8 completes broader platform acceptance; it does not defer earlier polish.
- Use native, accessible Apple controls. Keep reading content unobscured, preserve locations during layout changes, and tailor compact/wide and touch/keyboard/pointer interactions.
- Prefer existing dependencies and Apple frameworks. Discuss new dependencies, significant format expansion, or architecture changes before implementing them; record accepted decisions in an ADR.
- Use original/public-domain books and synthetic accounts for tests. Never publish tokens, private URLs, device/account identifiers, raw traces, personal library screenshots, signing material, or private local paths.

## Validation and completion

Run checks proportionate to the changed behavior; see `README.md` and `docs/DEVELOPMENT.md`. Documentation and board changes do not need app builds. Do not run hosted release gates, upload builds, or change versions simply to complete a routine patch.

Keep automated tests, compilation, simulator UI, native Mac interaction, physical iPhone/iPad use, live-server interoperability, signing, and distribution as separate evidence. Never substitute one for another.

Open a focused draft PR into `alpha`. Summarize the problem, behavior, issue, validation, and material limits. Do not merge or enable auto-merge unless the owner explicitly authorizes it. Promotion PRs advance exact tested candidates through `alpha` → `beta` → `preview` → `main`; see `docs/RELEASE.md`.

Merged implementation can still be in **Acceptance**. Close an issue and mark **Done** only when its criteria pass or the owner explicitly records a scoped exception. Milestone gate issues remain open until their independent acceptance is satisfied.

## Required handoff

Update the issue or PR with the issue number, branch/worktree role, exact full SHA, owned files, changes, relevant checks and results, unverified gates, blockers, and the next concrete action. Keep public evidence aggregate and sanitized. Link the implementation PR and acceptance gate so another agent can continue without chat history. A plan or inspected implementation is not completed work.
