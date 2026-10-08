# ADR 0005 Release branches and acceptance

Status: Accepted. Date: 2026-10-08.

## Context

The owner selected alpha, beta, preview, and main as the development stages. Quality-led milestones require clear source integration, acceptance, and promotion boundaries that any agent can follow.

## Decision

Use focused issue branches and PRs into alpha, normally squash merged. Promote exact tested candidates by owner-authorized PR and merge commit through alpha → beta → preview → main. Protect all four branches from direct pushes, force pushes, and deletion. Keep separate milestone gate issues and Acceptance board status.

## Alternatives and consequences

Direct integration is faster but weakens review/ownership boundaries. Squashing promotions breaks shared ancestry; merging moving tips can include untested work. Frozen candidates and separate gate issues add explicit coordination but keep evidence truthful. Required CI checks must refer to real compatible workflows; owner approval is a human authority boundary, not a self-review requirement enforced by GitHub.

## Verification

Confirm branch protections and PR bases. Inspect exact candidate/head/tree before each promotion and verify newer commits remain excluded. Record post-merge SHA, evidence, exceptions, and distribution actions separately.
