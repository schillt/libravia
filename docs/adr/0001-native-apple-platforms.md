# ADR 0001 Native Apple platform experiences

Status: Accepted. Date: 2026-10-08.

## Context

LibraVia's foundation is a shared SwiftUI app targeting iPhone, iPad, and native Mac on Apple OS 27. The owner requires a beautiful, immersive, responsive reader with tailoring for each platform before 1.0.

## Decision

Retain a shared native app/domain layer and existing WebKit EPUB, PDFKit, and comic surfaces. Tailor navigation, panels, gestures, keyboard/pointer behavior, window layouts, and accessibility to each platform. Default to quiet reading with optional persistent title/progress.

## Alternatives and consequences

A single identical mobile presentation is simpler but does not satisfy tablet/desktop requirements. A separate app per platform duplicates the domain model and risks divergent reading behavior. Shared foundations with adaptive presentation require physical acceptance on all three platforms; compile success is insufficient. Older platforms and web clients are outside 1.0 scope.

## Verification

Verify sustained reading, selection, page turns, search, location restoration, rotation/resizing, VoiceOver, larger interface text, Reduce Motion, keyboard navigation, and pointer interactions. Track representative performance across milestones.
