# Animation Standards Reference

Review-specific evidence reference. [animate](../animate/SKILL.md) owns the shared gate and web recipes; [animate-native](../animate-native/SKILL.md) owns AppKit/Android Views implementation. Copy actual repository/platform values when specifying a fix, not a duplicated table here.

## Should it animate?

Use the canonical purpose/frequency/input gate and behavioral-contract checkpoint. Record measured usage or a labeled estimate, existing native/static feedback, and pointer/touch, keyboard/accessibility, programmatic, or independent status input. Navigation and logical typing remain immediate. An approved smooth writing caret may interpolate presentation under [animate](../animate/SKILL.md)'s separate caret checkpoint; it must not delay edits or own scrolling. Rarity alone earns no motion.

## Easing

Inspect the actual existing token and platform behavior. The shared web starting curves live in [animate](../animate/SKILL.md); do not require custom CSS easing on a native transition. Cite the observed delay or discontinuity a proposed value resolves.

## Duration

Use repository tokens and the shared starting budgets, defaulting new web UI to under 300ms. A longer deliberate component/platform transition is not automatically wrong. The operation, focus, and action availability must not wait for a transition to finish.

## Physicality

Pure fades, instant states, and simultaneous group appearance are valid. If scale serves the purpose, avoid `scale(0)` and check the trigger origin for anchored surfaces; unanchored centered modals are exempt. Native/static press feedback comes first, custom scaling is optional and input-source dependent, and the actual hit/focus footprint stays correct.

## Springs

Use a spring for real gesture-release/retarget velocity continuity when required, not to make every state "alive." Direct tracking is 1:1. Use [animate](../animate/SKILL.md)'s starting parameters or the existing platform configuration only after the gate; verify the API's units and cancellation semantics.

## Interruptibility

Repeated or reversed motion must start from the displayed state, not replay from zero. Check owned cancellation, stale callbacks, recycled views, and recreation, not just the easing API. Use [gestures](../gestures/SKILL.md) for velocity-aware tracking and [animate-native](../animate-native/SKILL.md) for native model/presentation lifecycle.

## Ordinary press versus hold-to-confirm

Ordinary press/release may be symmetric and must retain existing activation timing. Hold-to-confirm visualizes a deliberate time threshold with linear progress and explicit cancellation; it is a separate operation contract with an accessible alternative. A CSS animation or end callback must not be the authority for confirmation.

## Performance

Use [animation-performance](../animation-performance/SKILL.md) to distinguish compositor eligibility, actual scheduling, redraw/layout, and measured frame cost. Transform/opacity or a native animator name is not proof of GPU execution. Preserve semantics when considering a layout-to-scale or visibility-to-opacity substitution; custom Canvas transforms still participate in drawing.

Require the actual interaction trace and repository workload/budget for measured claims. Separate compilation, regressions, visual evidence, performance results, and causality. A benchmark pass alone proves only that run's stated result.

## Transforms & clip-path

- **`translate` percentages** are relative to the element's own size — `translateY(100%)` moves by the element's height regardless of dimensions (how Sonner/Vaul position toasts/drawers). Prefer over hardcoded px.
- **`scale()` scales children too** (font, icons, content) — a feature for press feedback.
- **3D**: `rotateX/Y` + `transform-style: preserve-3d` for depth/orbit/flip without JS.
- **`clip-path: inset(t r b l)`** is a powerful animation tool: each value eats in from that side. Uses: reveal-on-scroll (`inset(0 0 100% 0)` → `inset(0 0 0 0)`), hold-to-delete overlay, seamless tab color transitions (duplicate + clip the active copy), comparison sliders.

## Gestures & drag

- **Momentum dismissal**: use the existing recognizer's direction, units, geometry, and commit rules. Distance and measured velocity can both matter; do not apply a universal absolute-speed cutoff or change dismissal semantics as motion cleanup.
- **Damping at boundaries**: dragging past a natural edge moves less the further you go (real things slow before stopping).
- **Pointer capture** once dragging starts, so it continues when the pointer leaves bounds.
- **Multi-touch protection**: ignore extra touch points after the drag begins (`if (isDragging) return`) — prevents jumps.
- **Friction over hard stops** — allow over-drag with rising resistance rather than an invisible wall.

## Crossfade review

Check legibility, correct state visibility, view/occurrence identity, focus, accessibility, and reading anchors before considering decorative blur. [choreograph](../choreograph/SKILL.md) governs presentation coordination; blur is optional and has a measured paint/filter cost.

## Stagger

Simultaneous appearance is normally correct. Optional stagger needs a rare/occasional expressive purpose and must not hide usable content, delay actions, or replay on routine navigation/search. Use the canonical recipe after the gate rather than flagging a list for missing stagger.

## Accessibility

Use the shared normal/reduced/explicit-disabled policy and the native adapter's actual preference APIs. Reduced state may fade gently or settle instantly; disabled state cancels pending work and settles without an animator. Preserve focus/pressed feedback, readable content, semantic visibility, hit testing, and accessibility exposure. Pure opacity does not itself remove an interactive element.

## Debugging (recommend in reviews when feel is uncertain)

- **Slow motion**: bump duration 2–5× or use DevTools animation inspector. Check colors crossfade cleanly, easing doesn't stop abruptly, `transform-origin` is right, coordinated properties stay in sync.
- **Frame-by-frame**: Chrome DevTools Animations panel reveals timing drift between coordinated properties.
- **Real devices** for gestures (drawers, swipe) — connect a phone, hit the dev server by IP, use Safari remote devtools.
- **Fresh eyes next day** — imperfections invisible during development surface later.

## Cohesion

Match admitted motion to the product's existing conventions without replacing behavioral correctness with a favorite personality. Crossfade timing may need a runtime feel check; no formula or passing benchmark establishes legibility, correct identity, or which edit caused an improvement.
