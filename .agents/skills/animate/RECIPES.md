# Animation Recipes

Web recipes, not a mandate to animate each component. Apply [SKILL.md](SKILL.md)'s purpose/frequency/input gate and behavioral-contract checkpoint first. Native surfaces use [animate-native](../animate-native/SKILL.md).

Reuse existing tokens before the sample `--ease-out`, `--ease-in-out`, and `--ease-drawer` values. Every adopted recipe needs the shared reduced/explicit-disabled policy; samples do not override action timing, focus, or native feedback.

---

## Button press

Optional pointer/touch feedback on a custom control that passed the gate. Keep the existing native/static pressed and focus states; do not add scale feedback to keyboard or accessibility activation.

```css
.button[data-input="pointer"] {
  transition: transform 160ms var(--ease-out);
}

.button[data-input="pointer"]:active {
  transform: scale(0.97);
}
```

`scale()` scales children too — the label and icons come along, which is what makes it read as a physical press.

Use the component's existing input-source tracking; the illustrative `data-input="pointer"` is set on real pointer-down and cleared on keyboard input, blur, or cancellation. A `click` alone does not establish the source. Gate hover separately; do not delay activation to finish the scale.

---

## Dropdown, popover, menu, select

Scales out of its trigger, not out of thin air.

```css
.popover {
  transform-origin: var(--transform-origin); /* Base UI supplies this */
  transition:
    opacity 200ms var(--ease-out),
    transform 200ms var(--ease-out);
}

.popover[data-starting-style],
.popover[data-ending-style] {
  opacity: 0;
  transform: scale(0.95);
}
```

The `transform-origin` is the whole point — the panel should look like it came out of the thing you clicked.

---

## Tooltip

Same shape as a popover, faster, plus the detail most implementations miss.

```css
.tooltip {
  transform-origin: var(--transform-origin);
  transition:
    transform 125ms var(--ease-out),
    opacity 125ms var(--ease-out);
}

.tooltip[data-starting-style],
.tooltip[data-ending-style] {
  opacity: 0;
  transform: scale(0.97);
}

/* Once one tooltip is open, neighbours open instantly */
.tooltip[data-instant] {
  transition-duration: 0ms;
}
```

The initial delay prevents accidental activation. After that, skipping both the delay and the animation makes the whole toolbar feel faster.

---

## Modal

The one popover that stays centered.

```css
.modal {
  transform-origin: center; /* exempt — not anchored to a trigger */
  transition:
    opacity 250ms var(--ease-out),
    transform 250ms var(--ease-out);
}

.modal[data-starting-style],
.modal[data-ending-style] {
  opacity: 0;
  transform: scale(0.96);
}

.backdrop {
  transition: opacity 250ms var(--ease-out);
}
```

Animate the backdrop's opacity alongside it so they read as one surface.

---

## Drawer / sheet

```css
.drawer {
  transform: translateY(0);
  transition: transform 500ms var(--ease-drawer);
}

.drawer[data-closed] {
  transform: translateY(100%);
}
```

This is how Vaul hides a drawer before animating it in.

Add drag and it becomes a gesture problem — see **Drag to dismiss** below.

---

## Toast

```css
.toast {
  opacity: 1;
  transform: translateY(0);
  transition:
    opacity 400ms ease,
    transform 400ms ease;

  @starting-style {
    opacity: 0;
    transform: translateY(100%);
  }
}
```

- `ease` rather than `ease-out`, slightly slower than typical UI: Sonner reads as elegant partly because its motion is tuned to the component's personality rather than to the generic UI budget.
- If `@starting-style` isn't available, fall back to the mount flag:

```jsx
useEffect(() => { setMounted(true); }, []);
// <div data-mounted={mounted}>
```

When toasts stack and the list reflows, the opacity change has to work against the height change. There's no formula for that pair — adjust until it feels right, then check it again the next day.

---

## Accordion / collapse

```css
.content {
  overflow: hidden;
  transition:
    height 200ms var(--ease-out),
    opacity 200ms var(--ease-out);
}
```

Keep it short — this is one of the few animations that costs layout on every frame, so a long duration is expensive as well as sluggish. Measure the content height in JS (or use a headless primitive that supplies it) rather than animating to `auto`.

---

## Stagger a group entrance

Only after the purpose/frequency gate: a rare or occasional expressive entrance, not routine navigation, search results, or content the user needs immediately. Presenting a group together is normally correct.

```css
.item {
  opacity: 0;
  transform: translateY(8px);
  animation: fadeIn 300ms var(--ease-out) forwards;
}

.item:nth-child(2) { animation-delay: 50ms; }
.item:nth-child(3) { animation-delay: 100ms; }
.item:nth-child(4) { animation-delay: 150ms; }

@keyframes fadeIn {
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
```

Stagger is optional decoration. It must never hide usable content, delay interaction, or replay on routine updates; reduced or disabled motion presents the group together.

---

## Hold to confirm

Only for an existing hold-to-confirm interaction that passed the gate. This optional pointer/touch fill and scale are **presentation only**; CSS does not recognize a hold or authorize the destructive action. Preserve the control's actual hold threshold and confirmation behavior.

```css
.overlay {
  clip-path: inset(0 100% 0 0);
  transition: clip-path 200ms var(--ease-out); /* release: snappy */
}

.button[data-input="pointer"]:active .overlay {
  clip-path: inset(0 0 0 0);
  transition: clip-path 2s linear; /* illustrative visual cue, not a confirmation timer */
}

.button[data-input="pointer"]:active {
  transform: scale(0.97);
}
```

`linear` visualizes elapsed time without easing it; `2s` is a sample cue, not the behavioral authority. Reuse the input-source tracking from the button-press recipe: set `data-input="pointer"` on real pointer-down and clear it on keyboard input, blur, or cancellation. Keyboard and accessibility activation keep immediate native/static feedback, without this custom fill or scaling.

Implement the [gestures hold contract](../gestures/SKILL.md#hold-gestures-are-asymmetric): monotonic elapsed-time/input state confirms **exactly once**, independently of CSS or `transitionend`; release before completion, pointer cancellation, blur, disabled state, and detach/recreation cancel the hold. Provide the accessible non-hold confirmation alternative. Reduced or disabled motion changes presentation, not the intentional confirmation requirement.

---

## Tab indicator with a color transition

Timing individual color transitions across a tab list never quite lands. Clip instead.

Duplicate the tab list. Style the copy as the active state — different background, different text color. Clip the copy so only the active tab shows, and animate the clip on change:

```css
.tabs-active-copy {
  clip-path: inset(0 60% 0 20%); /* driven by the active tab's position */
  transition: clip-path 250ms var(--ease-in-out);
}
```

The text and background change together, in perfect sync, because they're one element being revealed rather than two colors being interpolated.

---

## Scroll reveal

Marketing surfaces only. Don't do this to functional UI a user visits daily.

```css
.reveal {
  clip-path: inset(0 0 100% 0);
  transition: clip-path 600ms var(--ease-in-out);
}

.reveal[data-visible] {
  clip-path: inset(0 0 0 0);
}
```

Trigger with `IntersectionObserver`, or Motion's `useInView` with `{ once: true, margin: "-100px" }`. Fire it once — re-animating on every scroll-by is an interface fighting its reader.

---

## Drag to dismiss

The gesture recipe. Springs, not durations, because the user can reverse mid-motion.

```js
// Dismiss on a flick, not just on distance
const timeTaken = Date.now() - dragStartTime.current;
const velocity = Math.abs(swipeAmount) / timeTaken;

if (Math.abs(swipeAmount) >= SWIPE_THRESHOLD || velocity > 0.11) {
  dismiss();
}
```

```js
// Set transform on the dragged element directly.
// Driving it through a CSS variable on the parent recalcs styles for every child.
element.style.transform = `translateY(${distance}px)`;
```

Four details that separate a good drag from a bad one:

- **Pointer capture** once the drag starts, so it continues when the pointer leaves the element's bounds.
- **Multi-touch protection** — `if (isDragging) return` on new touch points, or switching fingers mid-drag makes the element jump.
- **Damping past boundaries** — dragging beyond a natural edge moves the element less the further it goes. Real things slow before they stop.
- **Friction, not a wall** — allow the over-drag with rising resistance rather than refusing it.

Settle with a spring so an interrupted drag keeps its velocity:

```js
{ type: "spring", duration: 0.5, bounce: 0.2 }
```

---

## Masking a crossfade that won't settle

When two states overlap visibly during a transition and no amount of easing or duration tuning fixes it, blur the seam:

```css
.content {
  transition:
    filter 200ms ease,
    opacity 200ms ease;
}

.content.transitioning {
  filter: blur(2px);
  opacity: 0.7;
}
```

Without blur the eye reads two distinct objects swapping. Blur blends them into one perceived transformation. Keep it under 20px — heavy blur is expensive, especially in Safari.

---

## Programmatic, without a library

When eligible motion needs JS control but no dependency, WAAPI provides an animator. It does not itself guarantee compositing, cancel stale callbacks, or preserve behavior:

```js
element.animate(
  [{ clipPath: 'inset(0 0 100% 0)' }, { clipPath: 'inset(0 0 0 0)' }],
  { duration: 1000, fill: 'forwards', easing: 'cubic-bezier(0.77, 0, 0.175, 1)' }
);
```

Retain the returned `Animation` when cancellation/retargeting is needed. Verify the property's actual rendering path with [animation-performance](../animation-performance/SKILL.md); this `clip-path` example is not evidence of hardware acceleration.
