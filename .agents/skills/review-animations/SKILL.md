---
name: review-animations
description: Review motion against animate's shared purpose/frequency/input gate and preserved behavioral contracts, with evidence-backed findings. Check action timing, identity, interruption, accessibility, and measured rendering cost; do not flag valid pure fades or instant states for lacking decoration.
disable-model-invocation: true
---

# Reviewing Animations

## Initial Response

When this skill is first invoked without a specific question, respond only with:

> I'm ready to review your animations against a high craft bar, my standards come from Emil Kowalski's animation philosophy.

Do not provide any other information until the user asks a question.

A specialized review skill. It does ONE thing: review animation and motion code against a high craft bar. It does not write features, fix unrelated bugs, or review non-motion code. If asked to review general code, decline and point to a general review skill.

## Operating Posture

Review motion for supported consumer-visible regressions, not stylistic violations invented from a recipe. A transition that delays input, changes data/identity, displaces reading content, or exceeds a measured budget matters more than whether it uses a favorite curve. Approval depends on evidence within the stated scope.

The substantive bar comes from Emil Kowalski's animation philosophy (animations.dev). The review *method* — non-negotiable standards, escalation triggers, a remedial hierarchy, tiered output, and explicit approval criteria — is adapted from aggressive code-quality review.

Use [animate](../animate/SKILL.md) as the canonical gate and recipe entrypoint, [animate-native](../animate-native/SKILL.md) for AppKit/Android Views, and [STANDARDS.md](STANDARDS.md) for review-specific evidence and specialist routes. Do not maintain a conflicting policy table in the review.

## The Ten Non-Negotiable Standards

Every animation in the diff is measured against these. A violation is a finding.

1. **Justified motion.** Every animation must answer "why does this animate?" — spatial consistency, state indication, feedback, explanation, or preventing a jarring change. "It looks cool" on a frequently-seen element is a block.

2. **Frequency and input.** Apply the shared gate and label usage estimates. Custom keyboard/accessibility press and navigation buildup remain absent, while logical text/selection stays immediate. An approved writing caret may ease visual position only; review its separate presentation/scroll/policy contract, not frequency alone. An independent status change needs its own gate.

3. **Responsive timing with provenance.** Reuse repository tokens and platform conventions. Cite an observed delay or unjustified custom value, not a missing preferred CSS curve on a native control.

4. **Bounded UI timing.** Default new web transitions to under 300ms. Longer deliberate platform/component behavior needs justification, not automatic replacement; presentation must never postpone the operation.

5. **Purposeful physicality.** If a trigger-anchored surface scales, check its actual origin. Unanchored modals are exempt. Avoid `scale(0)` when scale is chosen, but pure fades, static feedback, and simultaneous entrances are valid.

6. **Interruptibility and lifetime.** Retarget from the displayed state; guard stale callbacks and cancellation/recreation. Springs are useful for actual gesture velocity continuity, not mandatory for every reversible state.

7. **Measured rendering cost.** Prefer cheaper equivalent rendering without changing layout, text, hit areas, or visibility semantics. Property/API names establish neither compositing nor a frame-budget pass; use traces or label the performance risk unverified.

8. **Accessibility and motion policy.** Reduced motion may fade or settle instantly. Explicit disabled animation settles without an animator and cancels pending work. Gate custom feedback by input source; retain native/static focus, readable status, and accessible actions.

9. **Preserved behavior.** Action timing, order/deduplication, legitimate occurrences, survivor callbacks, focus, hit areas, persistence, reading anchors, and undo remain independent of the presentation timeline. Ordinary press/release may be symmetric; hold-to-confirm is a separate intentional contract.

10. **Cohesion without compulsory decoration.** Follow product conventions. Do not prescribe stagger, bounce, blur, or added transforms merely because they are absent; confirm the UX seam and shared gate first.

## Aggressive Escalation Triggers

Confirm the actual path before reporting these:

- Animation completion gates an ordinary save, navigation, warning action, or focus update.
- Refactoring motion changes order/deduplication, occurrence identity, saved output, or surviving control targets.
- Custom keyboard/accessibility press or high-frequency navigation buildup, delayed logical typing, or loss of native/static feedback. Approved visual writing-caret easing is not a violation by itself.
- Replayed entrances, stale hide/remove callbacks, duplicate writes on recreation, or older viewport writers overriding direct input.
- Missing reduced/explicit-disabled handling, ungated hover motion, or invisible/duplicate interactive or accessible exit views.
- Unbounded `transition: all`, avoidable per-frame layout/redraw, or documented frame-budget failure; do not call a source-only risk measured.
- Wrong origin on an existing spatial animation, `scale(0)`, or a custom duration/easing that demonstrably delays acknowledgement.

Pure fades, simultaneous entrances, symmetric ordinary press/release, platform timings, and instant reduced states are not automatic findings.

## Remedial Preference Hierarchy

When proposing fixes, prefer earlier moves over later ones:

1. **Preserve or restore behavior first.** Keep the operation immediate and fix identity, focus, persistence, anchors, and stale completion effects.
2. **Delete unnecessary motion.** Keep native/static feedback for paths that fail the gate.
3. **Reduce justified motion.** Use fewer properties or smaller/shorter effects with existing tokens and policy states.
4. **Fix the actual spatial/timing failure.** Correct an admitted animation's origin or retargeting; ordinary symmetric presses do not need an asymmetric rewrite.
5. **Choose a cheaper equivalent rendering path.** Use [animation-performance](../animation-performance/SKILL.md); measure instead of assuming layout-to-scale or opacity-to-visibility equivalence.
6. **Add polish only for a named purpose.** Optional stagger/blur/springs must pass the shared gate and cannot delay usable content.

## Required Output Format

Two parts, in this order.

### Part 1 — Findings table (REQUIRED)

A single markdown table. One row per issue. Never a "Before:/After:" list.

| Before | After | Why |
| --- | --- | --- |
| `transition: all 300ms` | Name intended properties with existing tokens | Avoid unbounded property work; verify the actual rendering path |
| `transform: scale(0)` | `transform: scale(0.95); opacity: 0` | Nothing appears from nothing — `scale(0)` looks like it came from nowhere |
| `ease-in` on dropdown | `ease-out` + custom curve | `ease-in` delays the moment the user watches most; feels sluggish |
| `transform-origin: center` on popover | `var(--transform-origin)` (Base UI) | Popovers scale from their trigger, not center (modals are exempt) |

### Part 2 — Verdict (REQUIRED)

Group remaining commentary by impact tier, highest first. Omit empty tiers.

1. **Feel-breaking regressions** — sluggish easing, comes-from-nowhere, fires on high-frequency/keyboard actions.
2. **Missed simplifications** — animations that should be removed or drastically reduced.
3. **Performance** — measured late frames or explicitly unverified rendering risks, not property-name GPU claims.
4. **Interruptibility & timing** — replay, stale completion, delayed operation, or lost gesture continuity; no blanket symmetric-press finding.
5. **Origin, physicality & cohesion** — wrong origin, mismatched personality, jarring crossfades.
6. **Accessibility** — normal/reduced/disabled policy, actual input-source gating, focus, and accessible state.

Close with an explicit decision:

- **Block** — an evidence-backed behavioral regression, failed shared gate, inaccessible action, stale lifecycle effect, or measured budget failure in scope.
- **Approve** — reviewed paths preserve behavior and satisfy the gate; interruption and applicable motion policies are covered. State any unverified visual, hardware, or performance limit explicitly.

Be specific and cite current `file:line` evidence. Exact target values come from the repository/platform convention or [animate](../animate/SKILL.md)'s starting recipes with stated provenance. A passing benchmark is a result, not proof of which edit caused it.

## Guidelines

- Use the relevant platform adapter and existing animation/gesture machinery. Do not add a dependency or custom draw loop just to match a web recipe.
- Separate build, regression, visual observation, and performance evidence. For uncertain feel, name the concrete recording/runtime check; a screenshot alone does not prove temporal behavior.
