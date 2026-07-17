---
name: self-evident-ui
description: Create, edit, or audit user interfaces so interaction mechanics are immediately understandable from visible controls, native affordances, placement, and established mental models. Use for every UI/UX design, implementation, review, usability audit, onboarding flow, empty state, settings screen, gesture interaction, or user-facing instructional-copy change.
---

# Self-Evident UI

Apply the "Don't Make Me Think" standard: the interface must communicate how it works through the interface itself. Treat text or diagrams that explain interaction mechanics as evidence that the design needs another pass.

## Core rule

Do not require users to read instructions to operate a feature. Replace explanations with recognizable controls, visible affordances, sensible placement, immediate feedback, and platform-native mental models.

A hidden gesture may be a shortcut, never the only discoverable path. Keep the equivalent visible control available and state-stable.

## Enforcement workflow

1. Inspect the real rendered flow and its current implementation before changing it.
2. Find copy or graphics that teach mechanics: "tap," "hold," "swipe," "drag," ordering explanations, gesture diagrams, or prose pointing to another control.
3. Identify the missing affordance or broken mental model that made the explanation necessary.
4. Redesign with the smallest familiar pattern that resolves it: labeled action, drag handle, chevron, numbered order, constrained picker, disabled state, direct empty-state action, inline feedback, or progressive disclosure.
5. Remove the now-redundant instructional copy and diagrams.
6. Verify the flow remains understandable on first use without the deleted explanation, including VoiceOver and Dynamic Type.
7. Re-audit adjacent screens for the same design smell before finishing.

## Decision test

For every explanatory string, ask:

- Does this explain how to operate a visible interface? Redesign the interface and remove it.
- Does this compensate for an undiscoverable gesture? Add a visible action; retain the gesture only as a shortcut.
- Does this repeat what the control, title, icon, selection state, or layout already says? Remove it.
- Does this explain a consequence, safety issue, permission boundary, destructive action, hardware dependency, domain concept, or data interpretation? Keep it concise; this is necessary context, not an interaction manual.

## Preferred patterns

- Prefer standard controls and platform conventions over custom teaching.
- Keep primary controls visible across states; do not make users remember where an action went.
- Make ordering spatially obvious with numbering and real reorder handles.
- Constrain invalid input instead of explaining validation rules afterward.
- Put the next action directly in empty and completion states.
- Use motion and feedback to confirm cause and effect, not to decorate instructions.
- Write labels as actions or states. Avoid prose such as "tap here to," "swipe to," or "hold to."

## Accessibility boundary

Visible instructional clutter and accessibility guidance are not equivalent. Preserve accurate accessibility labels, values, traits, hints, and alternative actions when they help assistive-technology users operate a control. Never remove safety or accessibility information merely to reduce word count.

## Completion standard

Before handing off UI work:

- Search user-facing strings for gesture-teaching language.
- Confirm every hidden gesture has a visible path.
- Confirm remaining explanation describes meaning or consequences, not mechanics.
- Report both what was removed and what was intentionally retained.
