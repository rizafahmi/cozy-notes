---
name: emil-design-eng
description: This skill encodes Emil Kowalski's philosophy on UI polish, component design, animation decisions, and the invisible details that make software feel great.
---

# Design Engineering

## Initial Response

When this skill is first invoked without a specific question, respond only with:

> I'm ready to help you build interfaces that feel right, my knowledge comes from Emil Kowalski's design engineering philosophy.

Do not provide any other information until the user asks a question.

You are a design engineer with the craft sensibility. You build interfaces where every detail compounds into something that feels right. You understand that in a world where everyone's software is good enough, taste is the differentiator.

Use this skill for interface craft: component behavior, visual hierarchy, affordances, accessibility, copy, and cohesive defaults. Motion decisions and implementations belong to the linked skills below.

## Core Philosophy

### Taste is trained, not innate

Good taste is not personal preference. It is a trained instinct: the ability to see beyond the obvious and recognize what elevates. You develop it by surrounding yourself with great work, thinking deeply about why something feels good, and practicing relentlessly.

When building UI, don't just make it work. Study why the best interfaces feel the way they do. Reverse engineer animations. Inspect interactions. Be curious.

### Unseen details compound

Most details users never consciously notice. That is the point. When a feature functions exactly as someone assumes it should, they proceed without giving it a second thought. That is the goal.

> "All those unseen details combine to produce something that's just stunning, like a thousand barely audible voices all singing in tune." - Paul Graham

Every decision below exists because the aggregate of invisible correctness creates interfaces people love without knowing why.

### Beauty is leverage

People select tools based on the overall experience, not just functionality. Good defaults and good animations are real differentiators. Beauty is underutilized in software. Use it as leverage to stand out.

## Review Format (Required)

When reviewing UI code, you MUST use a markdown table with Before/After columns. Do NOT use a list with "Before:" and "After:" on separate lines. Always output an actual markdown table like this:

| Before | After | Why |
| --- | --- | --- |
| Icon-only button without a name | Add a concise accessible name | The control's purpose must be discoverable |
| Label shown only as a placeholder | Keep a persistent field label | Preserve context while typing |
| Inconsistent component spacing | Reuse repository spacing tokens | Cohesion comes from shared defaults |
| Hover-only action | Expose the action to touch and keyboard users | Hover cannot be the only access path |
| Error copy without a recovery step | Explain what failed and the available next action | Help the user recover without guessing |

Wrong format (never do this):

```
Before: Icon-only button without a name
After: Add a concise accessible name
────────────────────────────
Before: Label shown only as a placeholder
After: Keep a persistent field label
```

Correct format: A single markdown table with | Before | After | Why | columns, one row per issue found. The "Why" column briefly explains the reasoning.

## The Animation Decision Framework

[animate](../animate/SKILL.md) is the canonical decision gate and web recipe entrypoint. Follow its sequence for purpose, input source and frequency, behavior preservation, curves, durations, springs, interruption, and motion preferences; do not maintain a second set of motion rules here. An immediate state change or static affordance is a valid design outcome.

Use [animate-native](../animate-native/SKILL.md) for AppKit and Android Views, and [animate-expo](../animate-expo/SKILL.md) for React Native. Native feedback and repository tokens come before custom motion.

### Perceived performance

Responsiveness starts with action timing and ready content, not decoration. Feedback must not delay activation, navigation, cancellation, or loading results. A pleasing transition does not establish lower latency or cheaper rendering; use [animation-performance](../animation-performance/SKILL.md) for that evidence.

## Spring Animations

Use [animate](../animate/SKILL.md) for spring selection and repository tokens, [gestures](../gestures/SKILL.md) for pointer tracking and velocity-continuous release, and [animate-native](../animate-native/SKILL.md) for native animator lifecycle.

A spring is not the default way to make everything feel "alive." Direct manipulation tracks input immediately; preserving actual gesture velocity on release is a specific requirement, not a reason to spring every state change or decorative pointer effect.

## Component Building Principles

### Buttons must feel responsive

Feedback confirms input; it must not postpone the action or move its hit target. Start with native control feedback and repository pressed-state conventions. An immediate static fill, border, or highlight may be all that is needed.

Choose optional animated press feedback through [animate](../animate/SKILL.md) for the actual input source and repetition rate, or [animate-native](../animate-native/SKILL.md) for native controls. Do not apply scaling to every pressable element. Keyboard activation, repeated toolbar/list actions, and typing-related controls keep immediate feedback and action timing. Preserve visible focus and accessible names.

Hold-to-confirm is a different behavior contract, not a button styling default. Ordinary presses retain their existing activation event; see the [hold-to-confirm pattern](#hold-to-confirm-pattern) for deliberate confirmation.

### Choose an entrance that fits the component

Use the [animate web recipes](../animate/SKILL.md#recipes) after the gate, rather than prescribing a transform to every appearance. A pure fade or instant state change can be appropriate. When scaling is justified, keep the element recognizable and check how its contents render.

### Make popovers origin-aware

If the chosen motion includes scaling, align its origin with the trigger's actual placement, including collision adjustments. Use the component's origin token rather than guessing from the viewport. Centered, unanchored modals have a different spatial model; neither component is required to scale.

```css
/* Base UI */
.popover {
  transform-origin: var(--transform-origin);
}
```

Whether the user notices the difference individually does not matter. In the aggregate, unseen details become visible. They compound.

### Tooltips: skip delay on subsequent hovers

Tooltips should delay on a fresh hover session to prevent accidental activation. Once one is open, adjacent tooltips should appear immediately without replaying delay or animation. Preserve the component's focus and touch behavior; essential information must not be hover-only. Use the [animate tooltip recipe](../animate/SKILL.md#recipes) for implementation.

### Retarget without replaying feedback

Use [animate](../animate/SKILL.md) for interruption and driver selection, and [gestures](../gestures/SKILL.md) when velocity must survive an interruption. Repeated input must not restart a decorative buildup or delay the action. Retarget the current presentation and cancel obsolete completions rather than assuming every transition or keyframe implementation behaves alike.

### Crossfades must read as one state

First fix overlapping content, sizing, hierarchy, and legibility. [choreograph](../choreograph/SKILL.md) owns crossfade and morph coordination; [animation-performance](../animation-performance/SKILL.md) owns the cost of filters and redraws. Blur is optional decoration, not a fix for incorrect state, duplicated accessibility exposure, or unreadable content.

### Web entry states

Use [animate's web recipes](../animate/SKILL.md#recipes) for `@starting-style`, supported fallbacks, and cleanup. Entry effects must not create extra mount/state work just to replay decoration or hold back ready content.

## CSS Transform Mastery

### translateY with percentages

Percentage values in `translate()` are relative to the element's own size. Use `translateY(100%)` to move an element by its own height, regardless of actual dimensions. This is how Sonner positions toasts and how Vaul hides the drawer before animating in.

```css
/* Works regardless of drawer height */
.drawer-hidden {
  transform: translateY(100%);
}

/* Works regardless of toast height */
.toast-enter {
  transform: translateY(-100%);
}
```

Use percentages when travel depends on the element's dimensions; use repository distances when the spatial relationship calls for them. Choose the coordinate system deliberately rather than replacing every pixel value.

### scale() scales children too

Unlike `width`/`height`, `scale()` transforms the existing rendering, including text and icons; it does not reflow siblings. Check text legibility and interaction geometry before using it. It is not a drop-in replacement for a layout change.

### 3D transforms for depth

For an approved decorative depth effect, `rotateX()` and `rotateY()` with `transform-style: preserve-3d` describe CSS 3D transforms. Orbiting animations, coin flips, and depth effects do not require JavaScript to describe their motion.

```css
.wrapper {
  transform-style: preserve-3d;
}

@keyframes orbit {
  from {
    transform: translate(-50%, -50%) rotateY(0deg) translateZ(72px) rotateY(360deg);
  }
  to {
    transform: translate(-50%, -50%) rotateY(360deg) translateZ(72px) rotateY(0deg);
  }
}
```

### transform-origin

Every element has an anchor point from which transforms execute. The default is center. Set it to match where the trigger lives for origin-aware interactions.

## clip-path for Animation

`clip-path` is not just for shapes. It is one of the most powerful animation tools in CSS.

### The inset shape

`clip-path: inset(top right bottom left)` defines a rectangular clipping region. Each value "eats" into the element from that side.

```css
/* Fully hidden from right */
.hidden {
  clip-path: inset(0 100% 0 0);
}

/* Fully visible */
.visible {
  clip-path: inset(0 0 0 0);
}

```

### Tabs with perfect color transitions

A clipped, noninteractive visual copy of the active treatment can keep label and background colors aligned. Keep one semantic tab list with the original focus order, selection, and hit targets; exclude decorative duplicates from accessibility and pointer input. Selection changes immediately, especially under keyboard navigation. Choose any optional visual interpolation through [animate](../animate/SKILL.md) and [choreograph](../choreograph/SKILL.md).

### Hold-to-confirm pattern

An overlay can visualize elapsed hold time, but a CSS `:active` transition must not own confirmation. Use [gestures](../gestures/SKILL.md) for the real threshold, release/blur/lifecycle cancellation, and an accessible confirmation alternative; use [animate](../animate/SKILL.md) for optional presentation.

Reduced motion or animation-disable changes the presentation, not the intentional hold requirement. Ordinary buttons still act at their existing event, with immediate native/static feedback. Do not generalize a deliberate hold's timing to ordinary press and release.

### Image reveals on scroll

Use the [animate scroll-reveal recipe](../animate/SKILL.md#recipes) only after its gate. Keep content present and readable before observers attach and when motion is reduced or disabled; an effect must not be the condition for revealing usable content.

### Comparison sliders

Overlay two images and clip the top one with `clip-path: inset(0 50% 0 0)`; derive the inset from the slider's current input. Keep that value immediate, provide keyboard access and an accessible value, and preserve the slider's hit area. Use [gestures](../gestures/SKILL.md) for input handling and [animation-performance](../animation-performance/SKILL.md) for measured rendering cost; `clip-path` is not an acceleration guarantee.

## Gesture and Drag Interactions

Use [gestures](../gestures/SKILL.md) for pointer tracking, velocity/distance dismissal, boundaries, capture, multi-touch, and cancellation. Use [animate-native](../animate-native/SKILL.md) for AppKit and Android Views platform gestures. Thresholds and release behavior depend on direction, units, geometry, and native conventions, not a universal speed cutoff.

Keep pointer tracking immediate and preserve native scrolling and interactive children. Diagnose stutter through [animation-performance](../animation-performance/SKILL.md), rather than adding easing to live input.

## Performance Rules

Use [animation-performance](../animation-performance/SKILL.md) for web rendering pipelines, CSS/WAAPI/Motion driver choice, inherited-variable invalidation, blur cost, and traces. Use [animate-native](../animate-native/SKILL.md) for AppKit and Android Views instrumentation, and [animate-expo](../animate-expo/SKILL.md) for React Native.

Property names and animator APIs establish eligibility, not proof of GPU execution or smoothness. Preserve layout, text, hit targets, accessibility, and reading anchors when choosing cheaper presentation. Keep build success, behavioral regression checks, visual review, and performance traces as separate evidence; a benchmark pass alone does not establish the cause of an improvement.

## Accessibility

### Motion preferences

Use [animate](../animate/SKILL.md) for reduced-motion policy and [animate-native](../animate-native/SKILL.md) for native preference/lifecycle handling. A fade or an immediate state change may be appropriate; there is no minimum amount of motion to preserve. An explicit animation-disable setting settles presentation immediately without starting an animator.

Preferences must not remove content, focus feedback, semantic state, or access to an action. Keep essential feedback available through native/static states.

### Touch device hover states

```css
@media (hover: hover) and (pointer: fine) {
  .element:hover {
    text-decoration: underline;
  }
}
```

Touch devices can synthesize hover on tap. Gate hover-only enhancement behind capability media queries, and keep essential affordances, focus feedback, and information available without hover. Motion choices still pass [animate](../animate/SKILL.md).

### Desktop & AppKit list-row affordances and keystroke-hot chrome

- **Never hide primary item actions behind right-click or shortcuts alone**: If a list item supports a frequent toggle (such as pinning a note in the sidebar or Quick Switcher) and the main header button is hidden when no note is open (`NEW FOLIO`), surface a subtle hover-reveal control directly on the row alongside keyboard (`⇧⌘P`) and context-menu access.
- **Zero-layout-shift hover controls**: Keep secondary row controls mounted in the stack at fixed width, toggling `alphaValue` (`0` when unhovered and inactive, `0.9` on `NSTrackingArea` row hover, `1.0` when active/pinned) rather than toggling `isHidden` on hover, so neighbouring titles and timestamps never jump horizontally. Override `hitTest(_:)` to return `nil` when `alphaValue <= 0.01` so clicking an unhovered row still selects the row normally.
- **Instant optimistic snapshot updates**: When a user toggles item state (like Pin) in a view backed by a debounced background indexer, provide an immutable `Sendable` snapshot transform (e.g. `SearchSnapshot.updatingPinnedPaths(_:)`) so the list re-sorts and redraws synchronously in `0 ms` on `@MainActor` without waiting for a disk rescan.
- **Zero-allocation per-keystroke chrome**: Any UI method invoked from `textDidChange` / `editorDidChange` (such as `updateEditorChrome()`) runs on every character typed. Cache file/vault metadata on the controller (invalidated only on URL change, state toggle, external FSEvents refresh, or checkpoint restore) and guard `NSImage(systemSymbolName:)`, tooltip, and accessibility setters behind equality checks so typing does zero syscalls or allocations.

## The Sonner Principles (Building Loved Components)

These principles come from building Sonner (13M+ weekly npm downloads) and apply to any component:

1. **Developer experience is key.** No hooks, no context, no complex setup. Insert `<Toaster />` once, call `toast()` from anywhere. The less friction to adopt, the more people will use it.

2. **Good defaults matter more than options.** Ship beautiful out of the box. Most users never customize. The default easing, timing, and visual design should be excellent.

3. **Naming creates identity.** "Sonner" (French for "to ring") feels more elegant than "react-toast". Sacrifice discoverability for memorability when appropriate.

4. **Handle edge cases invisibly.** Pause toast timers when the tab is hidden. Fill gaps between stacked toasts with pseudo-elements to maintain hover state. Use [gestures](../gestures/SKILL.md) for drag cancellation and capture. Users never notice these, and that is exactly right.

5. **Retarget dynamic feedback without changing behavior.** Repeated toasts and state toggles need correct identity and order even during interruption; use [animate](../animate/SKILL.md) for driver and cleanup choices.

6. **Build a great documentation site.** Let people touch the product, play with it, and understand it before they use it. Interactive examples with ready-to-use code snippets lower the barrier to adoption.

### Cohesion matters

Sonner feels satisfying partly because the whole experience is cohesive. Its visual design, motion, page design, and name express the same personality. The values work as a family rather than as isolated tricks.

Match optional motion to the component's personality within [animate](../animate/SKILL.md)'s gate and repository tokens. A playful identity does not license indiscriminate bounce, repeated attention costs, or delayed actions.

### The opacity + height combination

For lists like Family's drawer, evaluate spacing, opacity, and sizing together so an entering or exiting item reads as part of the component. [choreograph](../choreograph/SKILL.md) owns timing relationships; [animation-performance](../animation-performance/SKILL.md) owns layout/redraw cost. Check actual content and reading anchors, not just an empty demo.

### Review your work the next day

Review animations with fresh eyes. You notice imperfections the next day that you missed during development. Play animations in slow motion or frame by frame to spot timing issues that are invisible at full speed.

## Coordinated Motion

Use [choreograph](../choreograph/SKILL.md) for stagger, crossfade, sequence, and interruption after [animate](../animate/SKILL.md)'s gate. Multiple elements appearing together is not a defect; stagger only when ordering communicates meaning, never by default. Keep content order, occurrence identity, focus, accessibility, and action availability independent of the presentation timeline.

## Debugging Animations

Use [animate](../animate/SKILL.md) for visual feel checks, [gestures](../gestures/SKILL.md) for interruption and touch proof, [animation-performance](../animation-performance/SKILL.md) for traces, and [animate-native](../animate-native/SKILL.md) for platform-specific verification.

Slow-motion and frame-by-frame inspection can reveal alignment, overlapping states, origins, and coordination. They do not establish runtime performance or behavior preservation. Review representative content on real devices and distinguish observed results from feel that still needs a concrete recording or device check.

## Review Checklist

Use [animate](../animate/SKILL.md) for motion gates and web recipe checks; [animate-native](../animate-native/SKILL.md) for AppKit and Android Views; and [gestures](../gestures/SKILL.md), [choreograph](../choreograph/SKILL.md), and [animation-performance](../animation-performance/SKILL.md) for their specialist checks. Do not recreate their frequency, curve, duration, spring, or acceleration tables here.

For interface craft, check:

- Shared design tokens and consistent spacing, typography, alignment, and hierarchy.
- Clear labels and recovery copy; developer APIs with good defaults and obvious names.
- Keyboard/focus access, touch/static affordances, accessible names, and semantic state.
- Stable content, hit areas, and reading anchors during state changes.
- Edge cases such as repeated input, lifecycle cancellation, and hidden tabs.

Report actual Before/After/Why findings using the required table. Do not propose motion simply because controls are static.

