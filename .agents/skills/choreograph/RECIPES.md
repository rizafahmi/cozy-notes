# Choreography Recipes

Web presentation patterns after [animate](../animate/SKILL.md)'s shared gate and [SKILL.md](SKILL.md)'s behavioral-contract checkpoint. Reuse repository tokens; these samples are not universal timing or permission to animate. Required actions, semantic state, focus, accessibility, and reading anchors stay outside the timeline. Apply normal/reduced/explicit-disabled policy to every adopted recipe; native surfaces use [animate-native](../animate-native/SKILL.md).

## Overlap: CSS stagger with an index variable

Optional expressive one-shot entrance on a nonfunctional hero or intro. Do not put ready CTAs or readable product content behind a delay; apply the effect to passive decoration when immediate access would otherwise be lost.

```tsx
<div className="stagger">
  <h1 style={{ "--i": 0 }}>Title</h1>
  <p style={{ "--i": 0 }}>First paragraph, same beat as the title</p>
  <p style={{ "--i": 1 }}>Supporting paragraph</p>
  <div style={{ "--i": 2 }}>CTAs</div>
</div>
```

```css
.stagger > * {
  --step: 120ms;
  animation: enter 0.6s ease both;
  animation-delay: calc(var(--step) * var(--i));
}

@keyframes enter {
  from {
    opacity: 0;
    transform: translateY(10px);
  }
}

@media (prefers-reduced-motion: reduce) {
  .stagger > * {
    animation: none; /* an instant reduced state is valid */
  }
}

[data-motion="off"] .stagger > * { animation: none; }
```

- `both` is required. `backwards` applies the first keyframe during the delay, so later items don't flash their final state before they animate. `forwards` keeps the end state.
- Omitting `to` makes the keyframe animate to the element's own styles.
- Changing a custom property on a parent recalculates styles for every descendant. That's fine for a one-shot entrance, but don't drive per-frame values (a drag) through an inherited variable on a large tree.

## Overlap: Motion variants with a non-uniform stagger

```tsx
import { motion, stagger } from "motion/react";

const list = {
  hidden: {},
  show: {
    transition: {
      // Delays shrink as the group goes on, so it reads as a wave, not a metronome
      delayChildren: stagger(0.06, { ease: "easeOut" }),
    },
  },
};

const lead = {
  hidden: { opacity: 0, y: 12 },
  show: { opacity: 1, y: 0, transition: { duration: 0.5, ease: [0.23, 1, 0.32, 1] } },
};

const support = {
  hidden: { opacity: 0, y: 6 },
  show: { opacity: 1, y: 0, transition: { duration: 0.4, ease: [0.23, 1, 0.32, 1] } },
};

const decoration = {
  hidden: { opacity: 0 },
  show: { opacity: 1, transition: { duration: 0.3 } },
};

<motion.section variants={list} initial="hidden" animate="show">
  <motion.span variants={decoration}>New</motion.span>
  <motion.h1 variants={lead}>Title</motion.h1>
  <motion.p variants={support}>Subtitle</motion.p>
  <motion.div variants={support}>CTAs</motion.div>
</motion.section>
```

- Each role gets its own variant (distance, duration). The stagger only sets *when* each one starts.
- `stagger(0.05, { from: "center" })` radiates out from the middle. Use a number index to radiate from the item the user interacted with.
- Older Motion versions use `staggerChildren: 0.06` instead of `delayChildren: stagger(...)`.
- For long lists, give items beyond the first ~6 the same delay as the 6th, so the group never takes longer than ~300ms.

## Together: remove the exiting element from the flow

For an admitted web chip exit where the existing contract reclaims space, a passive visual copy can fade while layout updates once. Sibling motion is optional. Capture a reading anchor before the entire mutation and exclude the exiting copy from input, focus, and accessibility.

```tsx
<ul>
  <AnimatePresence mode="popLayout" initial={false}>
    {chips.map((chip) => (
      <motion.li
        key={chip.id}
        layout
        exit={{ opacity: 0, scale: 0.95 }}
        transition={{ duration: 0.2, ease: [0.23, 1, 0.32, 1] }}
      >
        {chip.label}
      </motion.li>
    ))}
  </AnimatePresence>
</ul>
```

Without a library, an owned passive exit copy can retain its old coordinates outside normal flow. Do not absolutely position the still-interactive semantic item and call it removed. Remove the logical item immediately, preserve the anchor and survivors, and discard the copy on completion or cancellation; do not apply a stale exit to a replacement.

## Together: crossfade views in a resizing container

An optional passive visual crossfade can accompany a container update that passed the gate. Commit the new semantic state and usable actions immediately, exclude old copies from focus/input/accessibility, and preserve the pre-change reading anchor. A layout-dependent height animation needs performance evidence; reuse existing measurement instead of installing this sample's library.

```tsx
import useMeasure from "react-use-measure";

const [ref, bounds] = useMeasure();
const prevHeight = useRef<number>();

// The fade duration scales with how far the container moves
const fadeDuration = useMemo(() => {
  const MIN = 0.15;
  const MAX = 0.27;
  if (!prevHeight.current) {
    prevHeight.current = bounds.height;
    return MIN;
  }
  const delta = Math.abs(bounds.height - prevHeight.current);
  prevHeight.current = bounds.height;
  return Math.min(Math.max(delta / 500, MIN), MAX);
}, [bounds.height]);

<motion.div
  animate={{ height: bounds.height }}
  transition={{ duration: 0.27, ease: [0.25, 1, 0.5, 1] }}
  style={{ overflow: "hidden" }}
>
  <div ref={ref}>
    <AnimatePresence initial={false} mode="popLayout">
      <motion.div
        key={view}
        initial={{ opacity: 0, scale: 0.96 }}
        animate={{ opacity: 1, scale: 1 }}
        exit={{ opacity: 0, scale: 0.96 }}
        transition={{ duration: fadeDuration, ease: [0.26, 0.08, 0.25, 1] }}
      >
        {content}
      </motion.div>
    </AnimatePresence>
  </div>
</motion.div>
```

- The height uses a strong `ease-out`, and the content uses a lighter curve from the same family, so the swap stays visible without falling out of sync.
- `key` on the child is what tells `AnimatePresence` a view left. A missing key is the first thing to check when an exit doesn't play.
- If the container is part of a larger component (a drawer), bring that component's own open duration in line with this one so the whole thing feels like one entity.

## Direction-aware steps

```tsx
const [[step, direction], setStep] = useState([0, 0]);
const go = (d: 1 | -1) => setStep(([s]) => [s + d, d]);

const variants = {
  initial: (d: number) => ({ x: `${110 * d}%`, opacity: 0 }),
  active: { x: "0%", opacity: 1 },
  exit: (d: number) => ({ x: `${-110 * d}%`, opacity: 0 }),
};

<MotionConfig transition={{ type: "spring", duration: 0.5, bounce: 0 }}>
  <AnimatePresence mode="popLayout" initial={false} custom={direction}>
    <motion.div
      key={step}
      custom={direction}
      variants={variants}
      initial="initial"
      animate="active"
      exit="exit"
    >
      {content}
    </motion.div>
  </AnimatePresence>
  <motion.div layout>{/* Back / Continue follow the height change */}</motion.div>
</MotionConfig>
```

`custom` goes on **both** `AnimatePresence` and the child. The exiting child reads the latest direction from `AnimatePresence`. Without that, it uses the direction it had when it mounted.

For small or similar views, an instant swap or pure fade may suffice. Do not add travel or blur solely because the full slide looks excessive; keyboard/high-frequency navigation remains instant.

## Sequence: one draw after another

This drawing sequence is for a noninteractive explanation, not a frequently toggled checklist. Real controls update their semantic state and native/static feedback immediately.

```css
.square {
  animation: draw 0.6s cubic-bezier(0.645, 0.045, 0.355, 1) forwards;
}

.checkmark {
  animation: draw 0.4s cubic-bezier(0.645, 0.045, 0.355, 1) forwards;
  animation-delay: 0.6s; /* = the square's duration */
}

@keyframes draw {
  to { stroke-dashoffset: 0; }
}
```

With `pathLength="100"` on both paths, `stroke-dasharray: 100; stroke-dashoffset: 100` hides each one with round numbers. To make the handoff read as one gesture, start the checkmark slightly before the square finishes (e.g. 0.5s).

## Sequence: morph between two rich states with a crossfade

If overlapping rich visual states are genuinely illegible, sequence passive presentation only; `mode="wait"` must not hide or delay the new semantic state or required actions. Prefer an instant swap or simpler fade when that separation is not possible.

1. Keep one authoritative interactive/accessibility tree; any entering/exiting duplicates are passive decoration.
2. Retain the exiting copy's displayed values and old coordinates outside flow. Do not restart an exit from opacity 1 or a stale transform after interruption.
3. Reuse bounded existing transition values, with little/no bounce unless a gesture earned it. Capture reading anchors before changes, cancel obsolete work, and prevent stale completions from affecting a replacement.

## Carry: steer a shared layout animation through its parent

You can't customize the path a `layoutId` animation takes, but you can move the container it lands in.

```tsx
<motion.div
  animate={{ y: 73 }}
  transition={{ delay: 0.13, duration: 0.3, ease: [0.23, 1, 0.32, 1] }}
>
  {selected.map((img) => (
    <motion.img key={img.id} layoutId={img.id} src={img.src} />
  ))}
</motion.div>
```

The images morph into the bin *and* drop with it. Show the bin's front face with a delay timed to when the images have almost landed, so they never visibly pass through it.

## Imperative orchestration (`useAnimate`)

Use imperative orchestration only for genuinely dependent presentation work. It cannot gate click/save/navigation/focus. Reuse the component's existing animation owner and lifetime mechanism rather than introducing another controller for a decorative sequence.

1. Cancel owned running motion **before** invoking any new `animate()` call. Passing already-started animations into a helper that then stops old work reverses that order.
2. Start from the currently displayed values, not hardcoded entrance endpoints. Retain only the handles this feature owns.
3. Commit the normal operation immediately in its existing handler. Visual feedback may be retargeted around it; readiness of a hover/idle sequence never authorizes the operation.
4. Await completion only to chain dependent decoration. Before resuming, check that the same input/lifetime still owns the sequence; a cancelled leave must not restart an idle loop after newer input.
5. On detach, cancellation, or explicit animation-disable, invalidate pending completions, stop owned handles, and apply the authoritative visual state without starting another animator. Reduced motion may fade or settle instantly.
6. Verify rapid enter/leave/re-press and policy changes on the actual component. A resolved animation promise alone proves neither current ownership nor correct state.

