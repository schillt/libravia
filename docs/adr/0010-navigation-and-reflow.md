# ADR 0010: Fast, faithful navigation and coherent reflow

Status: Accepted by the owner, 2026-11-01; control independence clarified and visible resize behavior revised 2026-11-03; implementation and acceptance ongoing. Replaces the navigation concerns of the [withdrawn broad draft](0008-epub-reader-boundary.md) and explicitly retracts the planning suggestion of one active plus one replaceable pending turn.

## Context

The owner reports unresponsive turns, lost card appearance under rapid input, abrupt fading, a white curl backside in dark mode and confusing Mac sidebar/reflow behavior. Apple Books is the observable experience reference; its internal queues, snapshots and timings are not public. Responsiveness must not lose committed swipes.

## Decision

Honor every completed, committed swipe quickly, exactly once and in arrival order, including direction changes. Never replace, discard or cap valid pending turns merely because rendering is behind. Cancelled gestures and attempts beyond publication boundaries do not advance a page. Evaluate boundary attempts in navigation order; later reverse-direction input still applies.

Provide immediate feedback. Interrupt decorative settling and shorten transitions during rapid input so navigation catches up quickly; do not require a full decorative animation per queued turn. Keep the final location consistent with all committed input, without duplicate turns or accidental momentum-driven navigation.

Layout changes retain pending navigation in order while obsolete preview/layout results are cancelled or rejected. Cancelled or provisional previews cannot save progress. Reading data and annotations remain tied to document locations, not snapshots or page counts. Renderer failure discloses unfinished navigation, releases visual/input locks and offers recovery. Do not silently drop requests or automatically replay a turn whose completion is uncertain.

Following owner testing on 2026-11-03, freeze the visible EPUB page during direct window resizing and inspector/sidebar movement, soften the content viewer, and reflow behind the frozen presentation. Reveal the completed layout with a short dissolve after matching native paint and settled viewport geometry; do not expose intermediate letter reflow. This replaces the earlier requirement for visibly live reflow. Coalesce obsolete width observations without discarding committed navigation. A SwiftUI animation completion alone does not prove native geometry has settled. Reader control visibility and inspector presentation/destination/width are independent: tapping the page must not close, reopen or resize an open inspector. For typography changes, a bounded hold of the last complete page followed by a dissolve remains an evaluated technique. Temporary images are disposable and keyed to location, viewport and appearance. Uniformly fill the moving viewport without changing line breaks in the captured image. Release the hold for navigation or selection and restore live input immediately; stale captures, reversed resizing and renderer stalls cannot leave a frozen cover over the book. This is a page-level transition, not an asserted glyph-by-glyph morph.

Honor Reduce Motion. Treat observation intervals, snapshots, transition durations and paint waits as techniques requiring evidence, not assumed Apple Books internals. Preserve native keyboard/pointer behavior, text selection, links and editing controls.

## Alternatives and consequences

Replacing pending intent or dropping swipes avoids catch-up but violates the accepted policy. Playing a full animation per request can create a slow backlog. Separating logical navigation from interruptible decoration preserves all input while allowing faster feedback, at the cost of careful ordering and failure handling. Pending input is scoped to the reader session and is not replayed into another book or after an uncertain restart.

## Migration and verification

Preserve positions, bookmarks, annotations and provider progress formats. Test ordinary turns, long rapid sequences, alternating directions, cancellations, boundaries, layout changes with pending navigation, renderer termination and teardown. Assert final location matches every committed input in order, with no duplicates or lost turns; preview cancellation must not save provisional locations.

Compare the same DRM-free EPUB in Apple Books on the same device with comparable typography/theme. Measure input-to-feedback delay, navigation completion, frame responsiveness and reflow duration for warm/cold paths. Exercise resizing, sidebar/typography changes, rotation, reopening, selection, VoiceOver, larger text, Reduce Motion and keyboard/pointer input. Record fixtures separately from physical devices and sustained native Mac reading. Dark curl, rapid card appearance and overall polish remain open until their own checks pass.
