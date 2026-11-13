---
name: animate
description: Build an animation from scratch, deciding whether it should animate, its purpose, preserved behavioral contracts, tool, properties, timing, interruption, and exit. Writes the implementation. Use for adding motion or a transition. This is the shared motion decision gate; use animate-native for AppKit and Android Views, animate-expo for React Native, review-animations for critique, and improve-animations for an audit or requested roadmap.
---

# Building Animations

## Initial Response

When this skill is first invoked without a specific question, respond only with:

> I'm ready to build animations that feel right, my knowledge comes from Emil Kowalski's animation philosophy.

Do not provide any other information until the user asks a question.

A construction skill: turn an approved motion request into an implementation without changing the behavior it acknowledges. This is the authoritative purpose, frequency, input-source, and accessibility gate for the motion skills. The tool examples and [recipes](RECIPES.md) are for the web; use [animate-native](../animate-native/SKILL.md) for AppKit and Android Views, or [animate-expo](../animate-expo/SKILL.md) for React Native. Audits belong to `improve-animations`; opportunity discovery belongs to `find-animation-opportunities`.

## Operating Posture

You are a senior design engineer building the animation yourself. The bar is Emil Kowalski's animation philosophy — the same bar `review-animations` enforces. Write it so it passes that review the first time.

Two failure modes, and the first is worse:

1. **Animating something that shouldn't animate.** The gate below exists to produce zero lines of code sometimes. That's a success, not a dodge.
2. **Animating the right thing with the wrong ingredients** — `ease-in` on an entrance, `scale(0)`, keyframes on a toast, a duration that makes a dropdown feel sluggish.

Never present motion options as a menu. Make the call, state the reasoning in one line, write the code.

## Hard Rules

1. **Run the sequence in order.** Purpose, frequency, input source, and the behavioral-contract checkpoint gate implementation. Do not start with a curve.
2. **Specify exact values with provenance.** Reuse repository tokens and platform conventions first. The tables below are starting points when no convention exists, not a reason to replace a working native default. State the chosen values and any justified exception.
3. **Extend the codebase's tokens, don't fork them.** If `--ease-out` or a duration scale already exists, use it. A parallel system is a defect.
4. **Normal, reduced, and explicitly disabled motion ship together.** Include input-source and hover gating; do not defer accessibility handling.
5. **Cheapest tool that works.** Reuse native feedback before adding custom motion. Do not install a motion library for a fade.
6. **Presentation never owns the operation.** Saves, navigation, focus, warning actions, and model changes must not wait for animation completion. Preserve their existing error, cancellation, and persistence semantics.

## The Build Sequence

### 1. Should this animate at all?

| Frequency | Decision |
| --- | --- |
| 100+ times/day (keyboard shortcuts, command palette toggle, core navigation) | No added action/entrance delay; use instant state and native/static feedback. Evaluate approved writing-caret presentation separately. |
| Tens of times/day (hover effects, list navigation) | Default to instant/native feedback; justify any near-imperceptible pointer-only effect |
| Occasional (modals, drawers, status feedback) | Brief motion only for a named purpose |
| Rare / first-time (onboarding, celebration) | Delight may fit, but rarity alone does not justify motion |

Treat frequency numbers as estimates unless measured; mark that uncertainty. **Keyboard and accessibility actions remain immediately usable**, without custom press, navigation, or shortcut buildup. Logical text insertion and selection also remain immediate. This does not categorically forbid a deliberately chosen smooth writing caret: a brief, non-bouncy visual interpolation may follow ordinary typing when it serves the product's established writing feel. Keep it separate from logical selection and viewport scrolling, retarget rapidly, and snap for selection/navigation, large or programmatic changes, and reduced/disabled motion. Preserve an explicitly liked interaction unless evidence identifies its actual defect; frequency alone is not that evidence.

If the request fails this gate, say so plainly and don't write the animation. Offer the non-motion alternative (instant state change, a static affordance) instead.

### Writing-caret exception — presentation, not the editing operation

An approved Bike-style caret is a continuous visual indicator, not a keyboard action waiting to finish. Record logical insertion/selection and rendered caret positions separately. Use the existing response/damping convention, keep text/IME/undo/focus native and immediate, and never let the visual caret authorize scrolling. Selection, navigation, paste/programmatic changes, resize/focus/scroll changes, and reduced or disabled motion snap or hide. Verify real typing, rapid retargeting, snap paths, and the affected frame/keystroke budgets; do not equate spring settling time with input latency. See [animate-native](../animate-native/SKILL.md) for the platform boundary.

### 2. What is the purpose?

Name it in one of these words before continuing:

- **Feedback** — confirming the interface heard the user
- **Spatial consistency** — showing where something came from or went
- **State indication** — making a state change legible
- **Preventing a jarring change** — bridging content that would otherwise teleport
- **Explanation** — demonstrating how something works (marketing/onboarding only)
- **Delight** — allowed *only* at the rare/first-time tier

Can't name it? Don't build it. "It looks cool" on a frequently-seen element is a reason to stop.

Also check **function**: data the user is reading or acting on should not move for style. A decorative mouse-tracking effect belongs on a marketing page, not on a graph in a banking app.

### Behavioral-contract checkpoint — before editing

Inspect the actual callers and transaction boundaries. Record the contracts that apply; do not invent a new state framework for this checklist.

| Contract | Preserve |
| --- | --- |
| Action timing and input source | Perform the existing operation immediately; distinguish pointer/touch, keyboard, accessibility, and programmatic paths. Do not run pointer feedback on the others. |
| Collection order and membership | Preserve insertion order and the existing deduplication boundary. A sequential conditional append checks membership after each acceptance; `filter` followed by a batch append checks only the old collection and can admit `[A, A]`. |
| Occurrence and view identity | A pending URL may be unique while existing repeated links are separate occurrences. Reuse surviving views; keep callbacks bound to the correct item after insert/remove. |
| Text and persistence | Preserve selection, undo grouping, edit notifications, conflict handling, saved links, file count, and unchanged attachment bytes where relevant. |
| Focus, hit areas, accessibility | Keep controls reachable immediately. A visual exit copy must neither intercept input nor remain an accessibility duplicate. |
| Reading position | Capture an anchor before the whole transaction, including text replacement; restore after the necessary layout and clamp to valid document bounds. Do not force whole-document layout on each frame. |
| Interruption and lifecycle | Cancel or retarget from the displayed state; prevent stale callbacks from hiding/reusing current views or repeating an operation. Restore the authoritative state after cancellation, recreation, or a motion-policy change. |

Choose regression cases from the mechanism, not an exhaustive matrix: repeated input in one batch, re-addition, removal of a repeated occurrence, rapid reversal/cancellation, or an update near a viewport boundary. Use [break-ui](../break-ui/SKILL.md) for consumer-boundary cases and [animate-native](../animate-native/SKILL.md) for native lifecycle and runtime proof.


### 3. Pick the tool — cheapest that works

For web implementations, walk down and stop at the first that fits. For native surfaces, use the platform adapter rather than translating CSS properties into custom drawing.

| Need | Tool |
| --- | --- |
| Hover, press, color, a state toggle you control with a class or attribute | **CSS transition** |
| Entry animation on mount, no JS state | **CSS `@starting-style`** |
| Predetermined motion using compositor-eligible properties while the page is busy | **CSS animation**; verify the actual rendering path |
| Programmatic control with CSS performance, no library | **WAAPI** (`element.animate()`) |
| Springs, layout animations, exit animations, gesture-driven values | **Motion** (`motion.dev`) |

CSS and WAAPI can keep eligible animations off the main thread; property choice, rasterization, and browser support still matter. A `requestAnimationFrame` loop runs on the main thread. Use [animation-performance](../animation-performance/SKILL.md) when eligibility or frame cost is uncertain; API names alone are not performance proof.

If a web task needs a *component* rather than an animation, use the existing accessible primitive or `pick-ui-library`. Native tasks should reuse platform controls and focus/tracking behavior, not install a web library or hand-roll a replacement control.

### 4. Pick the properties

- **Prefer `transform` and `opacity` for web motion.** They can avoid repeated layout/paint, but compositor eligibility is not a GPU guarantee. Layout properties such as `width`, `height`, and `padding` cost more; deliberate collapse/reveal may require them and needs measurement. See [animation-performance](../animation-performance/SKILL.md).
- **A pure fade is valid.** Do not add movement merely because an entrance lacks a transform. If scaling serves the purpose, start near the final size (`scale(0.9–0.97)`), never `scale(0)`.
- **`transform-origin` at the trigger** for popovers, dropdowns, menus, tooltips — `var(--transform-origin)` in Base UI. **Modals are exempt**; they're not anchored to a trigger, so they stay centered.
- **Percentages in `translate()`** are relative to the element's own size — `translateY(100%)` moves by its own height whatever the content. Prefer over hardcoded pixels.
- **Motion version and rendering path matter.** On supported HTML elements, Motion 14.2+ can accelerate independent transforms such as `x`/`y`/`scale`; older versions may need a full transform string. Check the installed version and trace the actual path before claiming acceleration.

- **Never drive a child's transform from a CSS variable on the parent** — it recalculates styles for every child. Set `transform` on the element directly.

### 5. Easing and duration — or a spring

**Easing**, in decision order:

| Situation | Easing |
| --- | --- |
| Entering or exiting | `ease-out` |
| Moving / morphing on screen | `ease-in-out` |
| Hover / color change | `ease` |
| Constant motion (marquee, progress) | `linear` |
| Default | `ease-out` |

**Never `ease-in` on UI.** It starts slow, delaying the exact moment the user is watching. `ease-out` at 200ms *feels* faster than `ease-in` at 200ms.

Reuse an existing easing token or native convention. If the web codebase has no suitable token, these are starting points:

```css
--ease-out: cubic-bezier(0.23, 1, 0.32, 1);        /* strong ease-out for UI */
--ease-in-out: cubic-bezier(0.77, 0, 0.175, 1);    /* strong ease-in-out for on-screen movement */
--ease-drawer: cubic-bezier(0.32, 0.72, 0, 1);     /* iOS-like drawer curve (Ionic) */
```

For a new curve, name its source or measured reason; [easing.dev](https://easing.dev/) and [easings.co](https://easings.co/) are references. Do not invent a parallel easing scale.

**Duration:**

| Element | Duration |
| --- | --- |
| Button press feedback | 100–160ms |
| Tooltips, small popovers | 125–200ms |
| Dropdowns, selects | 150–250ms |
| Modals, drawers | 200–300ms default; preserve a deliberate platform/component timing when justified |
| Marketing / explanatory | Can be longer |

**Default UI transitions to under 300ms.** A longer deliberate component or platform transition needs a stated reason, not an automatic retune.

**Use a spring when release or retargeting needs continuity.** Direct dragging should track input 1:1; do not put a lagging spring between the pointer and the surface. Interruptibility alone does not justify a new animation on typing or navigation. A deliberately approved writing-caret interpolation is a separate presentation use, governed by the checkpoint above. Web starting points, only after the gate passes:

```js
{ type: "spring", duration: 0.5, bounce: 0.2 }        // Apple-style — easier to reason about
{ type: "spring", mass: 1, stiffness: 100, damping: 10 }  // traditional physics — more control
```

Prefer little or no bounce for functional UI. Visible bounce needs a gesture or rare expressive purpose; it is not the default for feedback.

### 6. Interruption and exit

- **Retarget rapidly triggered motion from its displayed state.** CSS transitions can do this; imperative animators need explicit cancellation/retargeting. Do not replay an entrance from zero on every update.
- **Carry gesture velocity when settling requires it.** A spring can do that after direct input; an instant update or retargetable transition is sufficient for many other interactions.
- **Exit the way it entered.** A toast that slides in from the bottom leaves through the bottom. Symmetric paths are what make swipe-to-dismiss feel obvious.
- **Asymmetric timing belongs to a deliberate interaction contract**, such as hold-to-confirm. Ordinary press/release may be symmetric. Neither timing choice may delay an ordinary click, key command, or accessibility action.

### 7. Reduced motion and pointer gating

Ships with the animation, every time.

```css
@media (prefers-reduced-motion: reduce) {
  .element { animation: none; transition: opacity 120ms var(--ease-out); }
  /* State writes its intended transform directly; do not reset layout geometry. */
}

@media (hover: hover) and (pointer: fine) and (prefers-reduced-motion: no-preference) {
  .element:hover { transform: scale(1.05); } /* touch fires false hovers on tap */
}

/* If the product exposes an explicit animation-disable preference */
[data-motion="off"] .element { animation: none; transition: none; }
```


Reduced motion removes unnecessary travel and may use a gentle fade **or an instant state change**. Static/native feedback is still feedback. An explicit animation-disable preference must settle immediately without starting an animator. If that policy changes during motion, cancel pending work and apply the authoritative state; CSS overrides alone do not invalidate stale JS callbacks.

## Recipes

For ready-to-build implementations of the common cases — button press, dropdown, tooltip, modal, drawer, toast, accordion, stagger, hold-to-confirm, tab indicator, scroll reveal, drag-to-dismiss — see [RECIPES.md](RECIPES.md). Load it whenever the request matches one of those components; start from the recipe rather than from a blank file.

## Never Ship

Self-check against the shared gate and the relevant platform adapter. These findings need the stated alternative, not an unrelated cosmetic change:

| Never | Instead |
| --- | --- |
| `transition: all` | Name the exact properties |
| `transform: scale(0)` entrance | `scale(0.95)` + `opacity: 0` |
| `ease-in` on a UI element | `ease-out` or a strong custom curve |
| Custom press/navigation buildup or delayed logical editing on keyboard/accessibility/high-frequency paths | Immediate action/text/selection; evaluate approved visual writing-caret easing separately |
| UI duration over 300ms with no reason | 150–250ms |
| `transform-origin: center` on a trigger-anchored popover | `var(--transform-origin)` (modals exempt) |
| Keyframes on toasts, toggles, rapidly-triggered elements | CSS transitions |
| Avoidable per-frame layout or redraw | Cheaper properties, or a measured layout-dependent effect |
| Motion `x`/`y`/`scale` props under load on versions before 14.2 | Upgrade to 14.2+, or a full `transform` string |
| Ungated `:hover` motion | `@media (hover: hover) and (pointer: fine)` |
| Missing reduced/explicit-disabled handling | Gentle fade or instant reduced state; immediate disabled state |
| Stagger on a frequently used or functional list | Present content together; stagger only when the gate gives it a purpose |

## Output

Write the code. Then, in at most a few lines:

- **The gate result** — frequency tier and the named purpose. If something in the request was rejected, say which and why.
- **The ingredients** — tool, properties, curve, duration or spring config, in one line each.
- **Verification and limits** — name the exact completed check or runtime interaction and preserved contract. Separate build, regression, visual, and performance evidence. A screenshot proves one instant, not retargeting; a passing benchmark does not prove which change caused it. State unobserved feel or hardware behavior as unverified, with the concrete remaining check.

Don't pad this into a report. The code is the deliverable.

## Tone

Opinionated and brief. When the honest answer is "this shouldn't animate," give it — that answer is the reason this skill exists. When feel genuinely can't be settled from code, say so instead of guessing at a value.
