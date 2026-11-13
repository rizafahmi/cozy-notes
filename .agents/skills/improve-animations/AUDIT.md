# Animation Audit Playbook

Eight audit categories and their evidence requirements. Apply [animate](../animate/SKILL.md)'s canonical purpose/frequency/input gate and behavioral-contract checkpoint; use [animate-native](../animate-native/SKILL.md) for AppKit/Android Views. Reuse repository tokens and platform conventions before the web starting values. This playbook diagnoses failures; it does not maintain a competing recipe table.

## 1. Purpose & frequency

Record the named purpose, input source, actual usage frequency, and existing native/static feedback. Label frequency estimates; rare or first-run does not automatically mean delightful motion is needed.

Hunt for delayed logical editing, custom keyboard/accessibility press or shortcut buildup, routine navigation/search entrances, and frequently repeated decoration. An explicitly chosen visual writing caret is not automatically a finding: apply [animate](../animate/SKILL.md)'s separate presentation checkpoint and identify a real defect before removing it. Preserve native feedback and immediate operations; presentation must not delay saves, warning actions, focus, or model changes.

## 2. Easing & duration

Use the decision sequence and starting budgets in [animate](../animate/SKILL.md), not remembered or duplicated values. Cite the existing token/platform timing and why it serves the observed interaction. A new value needs an exact specification and provenance.

Hunt for visibly delayed acknowledgement, unnecessarily long transitions, and easing that stalls the watched response. Default web UI transitions to under 300ms, but a deliberate platform/component convention needs evidence before retuning it. Do not flag a native default merely because it differs from a CSS recipe. Tooltips encountered after an initial toolbar tooltip should avoid repeated delay where the existing platform interaction supports it.

## 3. Physicality & origin

- If scale is justified, avoid `scale(0)`; choose the near-final scale from the actual convention. **Pure fades and instant states are valid**, not defects missing a transform.
- If a trigger-anchored surface scales, its origin should explain that relationship. Unanchored centered modals are exempt; native transitions may already provide the right spatial story.
- A pressable control needs usable feedback, not universal scale. Prefer native/static feedback; custom pointer/touch motion must pass the gate and preserve the real hit area, keyboard focus, and accessibility activation.

Hunt for incorrect origin on an existing spatial animation, gratuitous scaling, or feedback that hides/moves the usable action. Do not add a transform solely to satisfy a review rule.

## 4. Interruptibility

Rapidly repeated or reversible motion must retarget from the displayed state without stale callbacks affecting its replacement. CSS transitions can do this; imperative animators require explicit lifetime management. An entry from zero on every update is not retargeting.

- Keep direct gesture tracking 1:1. Use a release/retarget spring only when velocity continuity actually matters; typing, caret travel, and navigation do not earn motion merely because they are interruptible.
- Preserve collection order, membership/occurrence identity, surviving control callbacks, focus, and the reading anchor across the **whole** update, including text replacement before layout.
- Cancel only owned animation work. Use the existing lifetime mechanism; add generation protection only if callbacks can survive cancellation and mutate a replacement.
- Ordinary press/release timing may be symmetric. Hold-to-confirm has a deliberate duration and separate activation/cancellation/accessibility contract; it is not a visual substitution for a click.

Hunt for replayed entrances, delayed operations in completion handlers, stale hide/removal callbacks, duplicate writes on recreation, and old viewport targets overriding direct input. Use [break-ui](../break-ui/SKILL.md) for repeated-input and occurrence-removal cases.

## 5. Performance

Use [animation-performance](../animation-performance/SKILL.md) for the rendering-path diagnosis and profiling procedure.

- Prefer compositor-eligible properties, but do not claim acceleration from `transform`, opacity, a layer-backed view, or an animator name alone.
- `transition: all` risks unbounded work; name the intended properties. Check installed Motion version and supported element/path before recommending an upgrade or full transform string.
- Web layout/paint, AppKit redraw/text layout/constraints, and Android `onDraw`/`invalidate`/`requestLayout` are distinct costs. `Canvas.scale()` is drawing, not proof of independently composited View animation.
- Do not replace layout with scale or semantic visibility with opacity unless interaction, accessibility, and layout contracts remain correct. Passive exit copies must not intercept input or duplicate accessibility.
- Avoid parent-driven inherited CSS values and per-frame allocation/layout when a cheaper implementation meets the same contract. Blur is a paint cost, not a mandatory crossfade fix.

Report measured frame cost with the actual interaction and repository budget, or label the risk unverified. A passing benchmark establishes that run's result, not which edit caused improvement; comparative causal claims need a controlled baseline.

## 6. Accessibility

Apply the shared normal/reduced/explicit-disabled policy. Reduced motion may retain a gentle fade **or an instant state**. Explicit animation-disable must apply the final state immediately without starting an animator; cancel pending callbacks on a live policy change.

Hunt for unhandled motion preferences, custom press animation on keyboard/accessibility activation, ungated hover effects, invisible-but-interactive fading elements, duplicate accessible exit copies, and warning actions delayed by entry. Static focus/pressed feedback and readable status are valid; deleting animation does not mean deleting feedback.

Use actual platform settings for native tasks. Android animator enablement is not a universal reduced-motion API; do not bypass a disabled system setting with a custom frame loop.

## 7. Cohesion & tokens

- Match the product's actual motion language, extending existing tokens rather than maintaining near-duplicate curves and durations.
- Simultaneous group appearance is normally correct. Optional stagger needs a rare/occasional expressive purpose and must not hide usable content, delay actions, or replay on routine updates.
- For double-exposed crossfades, inspect state visibility and view identity first. A subtle blur may fit a nonfunctional expressive seam, but it adds paint cost and can harm readable text; it is not a universal remedy.

Hunt for conflicting tokens, one unjustifiably bouncy component, unnecessary group delays, and visually overlapping states. Do not flag a list merely for lacking stagger.

## 8. Missed opportunities

Add only candidates supported by an observed UX seam and the shared gate: a jarring occasional state change, unclear spatial relationship, or a genuinely rare expressive moment. Prefer native/static feedback and a pure fade when sufficient. Preserve the operation and every applicable transaction contract.

Report at most a handful; zero is valid. Include exact scope, timing/API source, accessibility policy, and the real runtime check. Do not infer a missing animation from absent CSS or force delight into common save/search/empty states.

