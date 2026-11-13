---
name: apple-design
description: "Apple-style interface craft: gesture continuity, spatial consistency, restrained feedback, translucent materials, and typography (optical sizing, tracking, leading). Use when building or reviewing Apple-style UI, gestures, sheets, momentum, interruption, accessibility, or design foundations. Motion recipes follow animate's frequency, purpose, and input-source gate. Native AppKit and Android Views implementation routes to animate-native; React Native routes to animate-expo."
---

# Apple Design

## Initial Response

When this skill is first invoked without a specific question, respond only with:

> I'm ready to help you build fluid, Apple-style interfaces on the web, my knowledge comes from Apple's WWDC design talks, translated for the web.

Do not provide any other information until the user asks a question.

How Apple builds interfaces that stop feeling like a computer and start feeling like an extension of you. This knowledge comes from Apple's WWDC design talks — chiefly *Designing Fluid Interfaces* (WWDC 2018) — distilled and translated into the web platform (CSS, Pointer Events, `requestAnimationFrame`, spring libraries like Motion/Framer Motion).

For gesture-driven motion that passes the decision gate, the through-line is **continuity: start from the current on-screen value, preserve the user's velocity, and let the user grab or redirect the motion.** A velocity-aware spring can provide that continuity; it is not the default for every control or state change.

## Motion Decision Gate & Platform Route

Run [animate](../animate/SKILL.md)'s frequency, purpose, and input-source gate before any recipe below. That policy and the repository's existing tokens take precedence; these examples do not establish a second timing system.

- **Keyboard-driven actions, high-frequency navigation, and logical text/selection updates stay immediate.** An explicitly chosen smooth writing caret may ease its visual indicator only; apply [animate](../animate/SKILL.md)'s writing-caret checkpoint instead of rejecting it solely by frequency. Selection/navigation, programmatic jumps, and reduced/disabled motion snap. Interruptibility alone does not justify adding motion elsewhere.
- **Preserve behavior:** action timing, input source, order/deduplication, occurrence identity, focus, hit area, reading anchor, accessibility exposure, and cancellation/lifecycle. Feedback never delays the action or waits for an animation to finish. Prefer native/component feedback and repository tokens; no universal press scaling, stagger, or added transform just to make a fade physical.
- **Native implementation:** use [animate-native](../animate-native/SKILL.md) for AppKit and Android Views, and [animate-expo](../animate-expo/SKILL.md) for React Native. CSS, Pointer Events, and Motion examples here are web examples, not native API prescriptions.

For AppKit editor folding, caret, and layout use [appkit-textkit-layout](../appkit-textkit-layout/SKILL.md); for caret-follow and programmatic scrolling use [scroll-animation-ownership](../scroll-animation-ownership/SKILL.md); for native interaction evidence use [appkit-interaction-proof](../appkit-interaction-proof/SKILL.md).

## The Core Idea

> "When we align the interface to the way we think and move, something magical happens — it stops feeling like a computer and starts feeling like a seamless extension of us."

During direct manipulation, a fluid interface responds instantly, tracks continuously, carries actual gesture momentum, and can be redirected. Elsewhere, an instant state change or existing control highlight may be the most direct response; simulated physics is not a requirement.

Apple frames design as serving four human needs: **safety/predictability, understanding, achievement, and joy.** Every rule here serves one of them.

## 1. Response — kill latency

The moment lag appears, the feeling of directness "falls off a cliff." Response is the foundation everything else is built on.

- **Show feedback on pointer-down; preserve normal activation timing.** Prefer the control's existing pressed highlight. Do not move the action from `click`/touch-up to pointer-down, delay it until release animation completes, or add motion to keyboard activation.
- **Be vigilant about latency.** Audit artificial timers, transition waits, and nonessential work on the input path. Keep necessary debouncing and gesture recognition semantics intact rather than removing them for visual responsiveness.
- **Direct manipulation tracks continuously.** For an admitted drag, slider, or drawer, update the visual 1:1 with the pointer during the gesture, not only at release.
- **Ordinary press/release may use symmetric timing** when the gate admits motion and repository tokens support it; scaling is optional, not universal. **Hold-to-confirm is separate:** its deliberate progress, cancellation, and possibly asymmetric response belong to that control's existing action semantics, never to an ordinary button.

```css
/* Optional instant feedback using the component's existing token; no movement or action delay. */
.button:active {
  background-color: var(--button-pressed-background);
}
```

## 2. Direct manipulation — 1:1 tracking

> "Touch and content should move together."

When the user drags something, it must stay glued to the finger — and respect the offset from *where they grabbed it*. Snapping to the element's center on grab breaks the illusion immediately.

- Use Pointer Events with `setPointerCapture` so tracking continues even when the pointer leaves the element's bounds.
- Track a short **velocity/position history** (last few `pointermove` events), not just the current point — you'll need velocity at release.

```js
el.addEventListener('pointerdown', (e) => {
  el.setPointerCapture(e.pointerId);
  const grabOffset = e.clientY - el.getBoundingClientRect().top; // respect where they grabbed
  // ...track position + timestamp history for velocity
});
```

## 3. Interruption — preserve control

> "The thought and the gesture happen in parallel."

For a justified transition, new input must still work. A user should be able to grab a moving gesture-controlled surface and redirect it from its current on-screen state rather than wait for a close/reopen sequence. This requirement does not create permission to animate an interaction that failed the gate.

- **Never lock out input during a transition.**
- **Retarget from the presentation (current) value, not the old target.** Preserve the logical final state and cancellation rules while avoiding a visible jump. Native model/presentation state belongs to the native adapter.
- **Simple CSS transitions can retarget from the current value.** Use an existing velocity-aware animation API when a gesture handoff needs velocity continuity; do not assume every transition or spring carries it automatically, or restart keyframes from a stale endpoint.
- **When a gesture reverses, preserve its velocity continuity.** A hard replacement can create a visible “brick wall.” Choose an implementation that can retarget from both current position and velocity when this physical handoff is actually needed.
- **Preserve X and Y velocity components independently** when a gesture moves in both axes; independent springs are useful when the axes have independent targets or constraints, not a universal requirement for 2D motion.

## 4. Behavior over animation — springs for velocity continuity

> "Think of animation as a conversation between you and the object, not something prescribed by the interface."

Instant updates and short retargetable transitions are appropriate for many controls. Use native/component feedback first. Choose a spring when an admitted drag release or gesture reversal must carry real velocity into a new target, not merely because an element should “feel alive.” Fixed-duration motion can still retarget; a spring earns its place when the required continuity needs it.

Apple deliberately replaced the physics triplet (mass/stiffness/damping) with two designer-friendly parameters. Think in these:

- **Damping ratio** — controls overshoot. `1.0` = critically damped, no bounce, smooth settle. `< 1.0` = overshoots and oscillates. Lower = bouncier.
- **Response** — how quickly the value reaches the target, in seconds. Lower = snappier. **This is not "duration"** — a spring has no fixed duration; its settle time emerges from the parameters.

**For a spring already justified by the gate:**
- Start with **damping `1.0`** (critically damped) for a non-bouncy settle, unless the repository or platform interaction specifies otherwise.
- Add bounce (**damping ~`0.8`**) **only when the gesture itself carried momentum** (a flick, a throw, a drag release). Overshoot on a menu that just faded in feels wrong; overshoot on a card you flicked feels right.

**Reference gesture values from Apple's fluid-interface examples, not universal UI defaults:**

| Interaction | Damping | Response |
| --- | --- | --- |
| Move / reposition (e.g. PiP) | `1.0` | `0.4` |
| Momentum-driven rotation | `0.8` | `0.4` |
| Gesture drawer / sheet settle | `0.8` | `0.3` |

**Web mapping (Motion / Framer Motion):** `bounce` + `duration` offers designer-facing spring controls, but is not numerically identical to Apple's damping + response. Reuse the repository's spring configuration. A non-bouncy gesture settle is a starting point; reserve bounce for actual momentum-driven interactions.

```js
import { animate } from 'motion';

// Example admitted gesture settle (no overshoot); prefer repository spring tokens.
animate(el, { y: 0 }, { type: 'spring', bounce: 0, duration: 0.4, velocity: releaseVelocity });

// Momentum interaction — slight bounce with the measured flick velocity.
animate(el, { y: target }, { type: 'spring', bounce: 0.2, duration: 0.4, velocity: releaseVelocity });
```

## 5. Velocity handoff — the seam between drag and animation

When an admitted gesture hands off to an animation, preserve the measured release velocity so there is no artificial seam between dragging and settling. Keep the control's boundary, commit, and cancellation semantics; an instant settle requires no velocity animation.

Pass that velocity in the units expected by the existing spring API. Some APIs want **relative** velocity: normalize by the remaining distance only when that distance is nonzero; at the target, use the API's defined settle behavior.

```
relativeVelocity = gestureVelocity / (targetValue − currentValue)
```

Example: element at `y=50`, target `y=150` (100px to go), finger moving 50px/s → initial spring velocity = `50 / 100 = 0.5`. Framer Motion / Motion take absolute px/s velocity directly (`velocity` option), so you usually hand it the raw value.

## 6. Momentum projection — animate to where the gesture is *going*

> "Take a small input and make a big output."

For an admitted flick-to-snap interaction, use velocity to **project the resting position** and choose among the control's existing allowed snap targets. This makes a flick feel like a throw without changing the control's commit or cancellation rules.

Apple's exact projection function (from the *Designing Fluid Interfaces* sample code):

```js
// decelerationRate ≈ 0.998 for normal scroll feel; 0.99 for snappier
function project(initialVelocity /* px/s */, decelerationRate = 0.998) {
  return (initialVelocity / 1000) * decelerationRate / (1 - decelerationRate);
}

const projectedEndpoint = currentPosition + project(releaseVelocity);
const target = nearestSnapPoint(projectedEndpoint);   // choose target from the projection
animateSpringTo(target, { velocity: releaseVelocity }); // then hand off velocity (§5)
```

This exponential-decay example gives a scroll-like projection. Reuse existing gesture physics and native scrolling behavior rather than replacing them to match the formula; snapping and commit rules remain the control's contract.

## 7. Spatial consistency — symmetric paths, anchored origins

> "If something disappears one way, we expect it to emerge from where it came."

- **Use consistent paths for reversible spatial transitions.** A panel that slides in from the right normally dismisses to the right; a gesture-directed dismissal can follow the actual gesture. Reduced-motion or instant variants need no travel path.
- **Anchor spatial motion to its source.** For a trigger-anchored menu or popover that already scales, set `transform-origin` at its trigger. Do not add a scale to a pure fade just to satisfy this rule; sheets and unanchored modals retain their platform's spatial convention.
- **Keep reversible spatial timing coherent.** Compatible outbound/return curves preserve the relationship; mirrored curves can help when appropriate. Reuse repository tokens rather than forcing asymmetric ordinary press/release timing.

## 8. Hint in the direction of the gesture

Humans predict a final state from a trajectory. Intermediate motion should telegraph where things are going — Control Center modules "grow up and out toward your finger." Make the in-between frames point at the outcome, not just interpolate blindly to it.

## 9. Rubber-banding — soft boundaries

At an edge, resist progressively instead of stopping hard. A hard stop reads as "frozen"; continuous resistance reads as "responsive, but there's nothing more here." Apply damping that increases the further past the boundary the user drags.

```js
// The further past the bound, the less the element follows — real things slow before they stop
function rubberband(overshoot, dimension, constant = 0.55) {
  return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));
}
```

## 10. Gesture design details (the "feel" checklist)

- **Tap:** retain the control's instant touch-down highlight and normal touch-up commit/cancel behavior. Use platform/component hit padding and hysteresis; do not change the hit area to implement animation.
- **Drag/swipe:** retain the recognizer's platform/component movement threshold before committing to a direction, then track 1:1.
- **Detect all plausible gestures in parallel from the first move**, then confidently cancel the losers once intent is clear. Avoid recognizers that only report a *final* state (`swipeleft`-type events) — they throw away the continuous tracking you need for feedback.
- **Minimize disambiguation delays.** Double-tap detection unavoidably delays single taps; only pay that cost where double-tap truly exists.

## 11. Frame-level smoothness

Smoothness is about *what's in the frames*, not just the frame rate.

- Keep the per-frame positional change below the perception threshold to avoid strobing.
- For very fast motion, a subtle **motion blur / stretch** encodes speed and reads better than a hard sharp streak.
- `requestAnimationFrame` is the web's display-synced callback, but its updates run on the main thread. Prefer composite-eligible `transform` and `opacity` when equivalent; their names do not guarantee GPU execution or a frame-budget pass. Follow [animation-performance](../animation-performance/SKILL.md) for traces and measured use of `will-change`, and the native adapter for native scheduling.

## 12. Materials & depth — translucency conveys hierarchy

Apple uses translucent materials as a floating functional layer that brings structure without stealing focus. On the web, approximate with `backdrop-filter`.

- **Build nav/toolbars/sheets as translucent layers** (`backdrop-filter: blur()` + a semi-transparent background) with content scrolling underneath — not opaque bars that consume a fixed strip.
- **Material weight encodes hierarchy:** darker/heavier materials separate structural regions (sidebars); lighter materials draw attention to interactive elements (buttons). **Never stack a light translucent surface on another** — legibility collapses.
- **Bigger surfaces should read as thicker:** stronger blur + a deeper shadow than small chips. Consider context-aware shadow — heavier over busy/text content for separation, lighter over plain backgrounds.
- **Dim to focus, separate to keep flow.** A modal task pairs the surface with a dimming scrim and pushes the background back/down. A parallel, non-blocking panel uses translucency and offset *without* a scrim so the flow isn't broken. For stacked sheets, progressively dim and push back each parent layer.
- **Vibrancy keeps text legible over changing backgrounds.** Over blurred/translucent surfaces, don't use flat gray text — use higher-contrast, slightly heavier weight, and a small letter-spacing bump. Put color on a solid layer, not the translucent foreground.
- **Scroll edge effects, not hard dividers.** Instead of a 1px border under a sticky header, fade a small blur/gradient mask where content meets floating chrome — only where floating UI actually overlaps content.
- **Material motion is optional.** A pure fade or instant surface change is valid. For an admitted spatial entrance, a small scale can convey depth; animated blur is a separate, potentially expensive effect that needs performance evidence. Never require scale/blur just to make a fade “physical,” and use native material APIs through the native adapter.

```css
.toolbar {
  background: rgba(255, 255, 255, 0.6);
  backdrop-filter: blur(20px) saturate(180%);
  border-top: 1px solid rgba(255, 255, 255, 0.4); /* bright top edge = light catching the material */
}
```

## 13. Multimodal feedback — motion + sound + haptics

Three rules for combining senses (from *Designing Audio-Haptic Experiences*):

1. **Causality** — it must be obvious what caused the feedback. Trigger it on the actual causal event (the toggle flipping, the item snapping home), and match its character to the action's physicality.
2. **Harmony** — schedule supported visual, sound, and haptic feedback from the same causal event. Platform APIs cannot promise the same display frame; never delay the action to synchronize effects. Prefer existing native feedback over adding web Vibration API embellishments.
3. **Utility** — add feedback only where it earns its place. Reserve haptics/sound for meaningful moments (success, error, commit, snap). Over-feedback trains users to ignore all of it.

## 14. Reduced motion & accessibility

Reduced motion permits **instant feedback or a restrained fade** when it aids comprehension; it does not require a replacement animation. Treat the following signals independently and handle preference changes during an active transition:

- **`prefers-reduced-motion: reduce`** — drop slides, springs, parallax, and overshoot. Settle position immediately; use a short opacity/color transition only when justified, otherwise settle everything instantly.
- **`prefers-reduced-transparency: reduce`** — make translucent surfaces frostier/solid: raise background opacity, drop the blur.
- **`prefers-contrast: more`** — near-solid backgrounds with a defined, contrasting border.
- **Explicit animation-disable setting** — cancel active motion, commit the canonical final visual state, and run the normal state/lifecycle updates immediately **without creating an animator**. A zero-duration spring or a wait for an end callback is not an instant path. This setting wins over any reduced-motion fade.

Avoid full-viewport moving backgrounds, slow looping oscillations (near 0.2 Hz / one cycle per 5s), and abrupt brightness jumps. Solve legibility and contrast directly rather than adding compulsory theme or repositioning motion; do not hide reading content to decorate a transition. Preserve focus, accessibility exposure, and the reading anchor when settling or cancelling.

```css
@media (prefers-reduced-motion: reduce) {
  .sheet { animation: none; transition-property: opacity; }
}
@media (prefers-reduced-transparency: reduce) {
  .toolbar { background: white; backdrop-filter: none; }
}
/* Example root attribute bound to the app's explicit animation-disable setting. */
[data-animations-disabled="true"] .sheet {
  animation: none;
  transition: none;
}
```

The reduced-motion example allows an existing short opacity transition; `transition: none` is also valid. Position changes settle directly to their intended state, not an arbitrary `transform: none`. CSS cannot cancel a JS animator: guard its creation and settle/cancel it in the component's state path, keeping activation, visibility, and accessibility timing unchanged.

## 15. Typography — optical sizing, tracking, leading

Apple designs type to change shape with size; the same discipline applies on the web. (From *The Details of UI Typography*, WWDC 2020.)

- **Tracking (letter-spacing) is size-specific — never one value for all sizes.** Large display text wants *negative* tracking (letters read too far apart as they grow); small text wants slightly *positive* tracking for legibility. A fixed `letter-spacing` is wrong somewhere. Tighten headings, leave body near `0`.
- **Leading (line-height) tracks size inversely.** Tight on large headings, looser on body copy. Increase it for scripts with tall ascenders/descenders; tighten it for dense, information-heavy UI.
- **Build hierarchy from weight + size + leading as a set,** not size alone. Emphasize with weight — it adds presence without taking more space.
- **Respect the user's text-size setting** (Dynamic Type). Scale layout *with* the text — spacing in `rem`/`em`, not fixed px — so a larger font doesn't break the layout.
- **Default to the platform's system font** before a custom face; it already ships optical sizing, tracking tables, and legibility tuning. Override only with a reason.

```css
:root { font: 100%/1.5 system-ui, sans-serif; } /* body: system font, comfortable leading */

.display {
  font-size: clamp(2rem, 5vw, 4rem);
  line-height: 1.05;        /* tight leading for large text */
  letter-spacing: -0.02em;  /* negative tracking as it grows */
  font-optical-sizing: auto;
}
```

## 16. Design foundations — the eight principles

The motion and craft above serve Apple's eight design principles (*Principles of Great Design*, WWDC 2026). Use these as the names you reason with:

1. **Purpose.** Make with intention; decide what *not* to build. Every feature asks for the user's time, attention, and trust — spend that budget only where it pays off.
2. **Agency.** Keep people in control: offer choices, don't force a single path. Back it with forgiveness — easy undo for slips, a confirmation dialog only for genuinely destructive, irreversible actions (use sparingly; overusing it trains people to click through).
3. **Responsibility.** Act in the user's interest. Privacy: ask at the right moment, only for what's needed, transparently. Safety: anticipate misuse and harm — especially with AI (an allergy-aware recipe app must not suggest a harmful ingredient). Add previews, confirmations, disclaimers; cut a feature whose risk outweighs its value.
4. **Familiarity.** Build on what people already know. Use metaphors that are neither too literal nor too abstract (a trash can means delete), and honor their physics. Be consistent: things that look the same must behave the same and live in the same place (close is always top-left on macOS) so people can predict what happens next. Only break a familiar pattern if you can prove it's better — then test it, don't assume.
5. **Flexibility.** Design for different contexts, devices, and the full range of abilities. Adapt to the platform (iPhone = quick touch; desktop = deep workflows with precise pointer control) and to the situation. Design inclusively (age, language, expertise, accessibility). When no single layout fits everyone, let people personalize — rearrange controls, hide what they don't use.
6. **Simplicity — not minimalism.** Strip the unnecessary so the core purpose shines; burying everything in one place looks minimal but isn't simple. Be concise (plain language, no jargon, fewer steps) and clear (use hierarchy — order, spacing, contrast — so the most important thing is the most obvious). Every element earns its place; sometimes *adding* context simplifies (a video scrubber that shows time remaining). Show the common path first, advanced options one level deeper.
7. **Craft.** Uncompromising attention to detail builds trust. Beautiful typography, colors that adapt to light/dark, clear iconography, and responsive animations that give immediate, natural feedback. Nothing is random — every spacing, timing, and alignment value is a deliberate choice you can defend. Jittery scroll, misaligned icons, and layouts that break on rotation read as carelessness. Craft needs iteration and longevity — keep evolving the design as features and hardware change.
8. **Delight.** The result of getting the other seven right, not confetti tacked on top. Decide the emotion you want people to feel (calm, confident, excited) and reinforce it in every decision.

Tactical rules that serve these:

- **Feedback comes in four kinds:** status, completion, warning, error. Confirm meaningful actions, expose ongoing status, warn before problems, validate inline (not on submit).
- **Wayfinding.** Every screen should answer: Where am I? Where can I go? What's there? How do I get out? Never trap the user.
- **Grouping & mapping.** Proximity implies relationship; place a control near what it affects and arrange controls to mirror what they change. If you need a label to explain a control, the mapping is weak.
- **Direct, specific labels beat safe generic ones.** Name nav items for their contents ("Progress", "Library"), not vague umbrellas ("Home"). Specificity creates predictability.

## 17. Process

- **Prototype interactively — an interactive demo is worth "a million static designs."** You discover the interface by building and playing with it; a working prototype also sets a concrete bar that prevents a mediocre final implementation.
- **Design interaction and visuals together.** "You shouldn't be able to tell where one ends and the other begins." Motion is not a layer added after the pixels.
- **Test with real people in real context**, and review motion with fresh eyes — play it in slow motion / frame-by-frame to catch what's invisible at full speed.

## Quick Reference

Use these techniques only after the [canonical gate](../animate/SKILL.md); gesture values are references, not a replacement for repository tokens.

| Need | Technique | Concrete value |
| --- | --- | --- |
| Justified gesture spring | Critically damped, no overshoot | reference `damping 1.0`, `response 0.3–0.4` |
| Momentum / flick spring | Under-damped, slight bounce | `damping ~0.8`, `response 0.3–0.4` |
| Gesture → spring velocity | Hand off release velocity in API units | normalize by remaining distance only when nonzero |
| Flick landing point | Project momentum | `current + (v/1000)·d/(1−d)`, `d ≈ 0.998` |
| Interrupt cleanly | Start from presentation (live) value | read the on-screen transform |
| Avoid reversal "brick wall" | Carry velocity through re-target | spring that blends velocity |
| Reversible spatial transition | Coherent outbound/return timing | existing tokens; mirror curves only when appropriate |
| Decide reverse vs. commit | Preserve the recognizer's decision policy | existing position/velocity/constraint rules |
| 1:1 drag | Pointer Events + capture | respect the grab offset |
| Feedback | Instant native/component highlight | preserve normal activation and cancellation timing |
| Boundary | Rubber-band, don't hard-stop | progressive resistance |
| Translucent chrome | `backdrop-filter` layer | content scrolls under |
| Type tracking | Size-specific, never fixed | tighten large text (`-0.02em`), body near `0` |
| Reduced motion | Instant or restrained fade, not required travel | `@media (prefers-reduced-motion)` |
| Explicit animation disable | Cancel and settle immediately, without an animator | normal final state and lifecycle |
