---
name: gestures
description: Build drag, swipe, and sheet interactions that track the finger 1:1 and stay interruptible. Use when building or fixing anything the user drags, swipes, flings, holds, or dismisses with a gesture — drawers, sheets, swipe-to-dismiss toasts and cards, drag-to-reorder, pull-to-refresh, hold-to-confirm — or when a gesture feels laggy, disconnected from the finger, jumps on release, or can't be caught mid-animation. Triggers on — gesture, drag, draggable, swipe, swipe to dismiss, fling, momentum, velocity, drawer, sheet, bottom sheet, snap points, Vaul, dragConstraints, dragElastic, dragMomentum, onDragEnd, whileDrag, useMotionValue, rubber-band, overscroll, pull to refresh, hold to delete, press and hold, touch-action, dismiss threshold, "doesn't follow my finger", "jumps when I let go", "can't grab it mid-animation".
---

# Gesture-Driven UI

This guide covers web gesture implementation after [animate](../animate/SKILL.md)'s purpose/frequency/input gate and behavioral-contract checkpoint. Direct manipulation tracks input; release uses the control's actual commit and settle semantics. Native AppKit/Android Views use [animate-native](../animate-native/SKILL.md), not a web drawer library or custom replacement for native scrolling.

## First decision: build it, or use a solution that exists?

Reuse the repository's existing accessible gesture component first. For web sheets/drawers, consider [Vaul](https://vaul.emilkowal.ski/) through `pick-ui-library` if no suitable primitive exists; do not add a dependency or hand-roll tracking merely to animate presentation. Keep native platform controls and gesture ownership on native surfaces.

## The two phases of every gesture

Walk this split for any gesture you build. Mixing the phases up is the #1 cause of gestures that feel wrong.

```
Is the pointer currently down?
├── Yes → TRACK phase: position maps 1:1 to the pointer.
│         No easing. No duration. No spring. The element IS the finger.
└── No  → RELEASE phase: apply the control's commit/cancel and motion policy.
          Carry velocity if animated settling needs it; an instant settle is valid.
```

### Track phase rules

- **1:1 means 1:1.** Drive position from a `useMotionValue` (or direct `transform` writes), never a spring or a transition — a spring during tracking makes the element trail the finger and feel disconnected, like dragging something through syrup.
- **Write `transform` directly on the dragged element.** Never update a CSS variable on a parent to move children: CSS variables are inheritable, so every change recalculates styles for all descendants. This exact bug made Vaul's drag laggy past ~20 list items; setting `transform` on the element fixed it.
- **No React state per move event.** A re-render every pointermove drops frames. Motion values and direct style writes bypass the render cycle.
- **Rubber-band at the edges.** Dragging past a boundary should move the element a fraction of the distance (Motion: `dragElastic` ≈ 0.2), not stop dead — hard stops feel like hitting a wall; resistance communicates "there's nothing further" physically.

### Release phase rules

- **Preserve release continuity when settling is animated.** A velocity-aware spring can help a real fling or interrupted settle. Reuse the component's native/existing behavior; simple reposition may stop immediately, and reduced/disabled policy may settle without animation.
- **Dismiss on distance OR velocity.** Passing a distance threshold (~40–50% of travel) dismisses, but so does a fast flick over a short distance. In Motion, read both from `onDragEnd`'s `info.offset` and `info.velocity`. Distance-only thresholds make flicks feel ignored.
- **Bounce is optional, not a consequence of every drag.** Use little or none for functional UI; justified momentum may earn overshoot after the gate. Ordinary button feedback does not need it.
- **Snap-back preserves the control contract.** If the gesture does not commit, return promptly from the displayed state through existing machinery or an instant policy path. Do not delay cancellation behind a spring.

## Interruptibility is non-negotiable

A gesture-controlled surface must accept new input while settling. Cancel/retarget its owned motion from the displayed position and, when needed, velocity. Retargetable springs can carry velocity; transitions or an instant settle may suffice. Do not restart an entrance keyframe from zero or let stale completions override a newer gesture.

## Linked values

The dragged element is rarely alone — an overlay fades, the page behind scales. Derive these from drag progress, don't animate them separately:

```jsx
const y = useMotionValue(0);
const overlayOpacity = useTransform(y, [0, drawerHeight], [1, 0]);
```

One source of truth means the overlay is always exactly as faded as the drawer is dismissed — including mid-gesture, including when the user reverses. Two separate animations drift apart the moment a gesture is interrupted.

## Motion drag props

```jsx
<motion.div
  drag="y"
  dragConstraints={{ top: 0 }}
  dragElastic={0.2}
  onDragEnd={(e, info) => {
    if (info.offset.y > threshold || info.velocity.y > 500) dismiss();
  }}
/>
```

`dragMomentum` is on by default — right for a flung card, wrong for a simple reposition; disable it when the element should stop where the finger stops. `dragConstraints` takes a ref or bounds object.

## Sheets without springs: the Vaul curve

Vaul mimics the iOS sheet with pure CSS to stay small: `cubic-bezier(0.32, 0.72, 0, 1)` over **500ms**. The curve is extremely steep at the start — that's what lets a 500ms duration still feel snappy while landing with a spring-like gentle settle. Two rules from it:

- A **small floating drawer** (not touching the screen edge) should override to ~200ms — the 500ms iOS timing only reads right on a full-width edge-attached sheet:
  ```css
  [vaul-drawer]  { transition: transform 0.2s cubic-bezier(0.165, 0.84, 0.44, 1); }
  [vaul-overlay] { transition: opacity  0.2s cubic-bezier(0.165, 0.84, 0.44, 1); }
  ```
- **The component must feel like a single entity.** If the drawer opens in 200ms, its height changes and content crossfades must live in the same timing family — one slow sub-animation makes the whole thing feel broken.

Mark interactive children with `data-vaul-no-drag` so pressing a button inside the drawer doesn't start a drag.

## Spatial consistency

**An element dismisses in the direction it entered.** Sonner's toast slides up from the bottom, so swipe-down dismisses it — enter and exit share one axis, which is what makes the gesture feel discoverable and intuitive without instruction. A gesture that dismisses along an axis the element never moved on has to be learned; one that reverses the entrance is *felt*.

## Hold gestures are asymmetric

Hold-to-confirm is a separate behavior contract, not ordinary press styling. Visualize a deliberate time threshold with linear progress; cancelling can reset promptly, while ordinary press/release may be symmetric. The control's monotonic elapsed-time/input state owns confirmation **exactly once**, not a CSS animation or end callback. Preserve release, pointer-cancel, blur, disabled-state, and detach/recreation cancellation, plus an accessible non-hold confirmation alternative. Reduced/disabled motion changes presentation, not the intentional confirmation requirement.

## Touch checklist

Run through this for every gesture you ship:

- **Verify the actual platform/input route.** A real phone is needed for physical touch/refresh-rate claims; emulator or synthetic/native handler coverage must be labeled as such. Preflight runtime/focus/signing where applicable; see the native adapter.
- **Preserve usable platform hit targets.** For web touch controls, 44×44 CSS px is a useful starting minimum; Android and Apple have their own units/conventions. Increase hit padding through the existing control rather than scaling the layout or changing tracking semantics as feedback.
- **`touch-action`** on the drag axis (`touch-action: pan-x` for a vertical drag, etc.) so the browser doesn't fight the gesture with native scrolling.
- **Gate hover effects** behind `@media (hover: hover) and (pointer: fine)` — touch fires phantom hovers on tap.

## Reduced motion

Direct tracking remains immediate where it is the operation itself; decorative travel and momentum do not. Apply the canonical policy: reduced release may use a gentle fade or instant settle, with no compulsory positional animation. Explicit disabled animation cancels pending settling and applies the authoritative position/state without an animator; do not bypass it with a frame loop. Reconcile active gestures and stale callbacks when policy changes.

## When it still feels wrong

A "weird" spring is usually fixed by increasing `damping`. A gesture that stutters is a performance problem — check the track-phase rules above first, then use the `animation-performance` skill. To diagnose a feeling you can't name, record the gesture and scrub it frame by frame.
