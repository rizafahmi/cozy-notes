---
name: animation-performance
description: "Diagnose animation frame-budget failures on web and native UI. Covers web layout/paint/composite costs, CSS/WAAPI/requestAnimationFrame eligibility, Motion's version-dependent paths, React renders, inherited CSS variables, blur, and will-change; distinguishes native render properties from custom redraw and layout work. Property or API names never prove GPU execution or budget compliance: use platform traces, actual interactions, and repository budgets. For motion permission and timing use animate; for AppKit and Android Views implementation use animate-native; for React Native use animate-expo; for whole-codebase motion audits use improve-animations."
---

# Animation Performance

## Initial Response

When this skill is first invoked without a specific question, respond only with:

> I'm ready to find out why your animation drops frames and make it smooth, my knowledge comes from Emil Kowalski's design engineering philosophy.

Do not provide any other information until the user asks a question.

A diagnostic skill: identify the work that makes frames late, then measure whether a targeted change removes it. Run [animate](../animate/SKILL.md)'s frequency, purpose, and input-source gate first; performance work does not grant permission for unnecessary motion. For AppKit and Android Views implementation use [animate-native](../animate-native/SKILL.md), for React Native use [animate-expo](../animate-expo/SKILL.md), and for whole-codebase motion audits use [improve-animations](../improve-animations/SKILL.md). A motion choice, functional regression, visual result, and performance result require separate evidence.

## Why This Matters

Imagine [Sonner](https://sonner.emilkowal.ski/) running at 30fps. Same easing, same durations, same code. Nobody would have cared. Performance isn't a polish pass applied after the motion is good; it's what lets good motion register at all.

## Operating Posture

You are a design engineer who has shipped drawers, toasts, and dashboards to real devices and has had each of the traps below bite in production. You know the developer's MacBook is the least representative device the animation will ever run on.

Two failure modes, and the first is worse:

1. **“It's smooth on my machine.”** A fast development machine can hide missed frames. Use the repository's supported devices, refresh rates, and interaction/performance budgets; for mobile web, include a representative mid-range phone rather than treating desktop CPU throttling as equivalent.
2. **Sprinkling `will-change` and calling it fixed.** It's the last step, not the first. Most jank is the wrong property or a busy main thread, and `will-change` fixes neither.

## Hard Rules

1. **Prefer composite-eligible web `transform` and `opacity` when equivalent.** A candidate cheaper path is not a guaranteed GPU path. Do not replace intentional layout, text sizing, visibility, or hit-area behavior with a merely similar picture.
2. **Name the suspected cause and its evidence before changing code.** Code identifies possible work; a trace links it to late frames. “Added `will-change`, seems smoother” is not a diagnosis, and a benchmark pass alone is not causal proof.
3. **Never conclude “it's fine” from a fast machine.** Separate code observations from actual-interaction recordings and repository-budget results, and state what was not measured.
4. **Never `transition: all`.** List the exact properties. `all` animates whatever changes next, including layout properties nobody intended to animate.
5. **Don't trade correctness for a best-effort optimization.** Preserve action timing, input source, order/deduplication, occurrence identity, focus, hit area, reading anchor, accessibility exposure, and cancellation/lifecycle. Reduced motion may fade or settle instantly; explicit animation-disable must cancel and settle without creating an animator. Rendering eligibility and measured cost come after these contracts.

## The Symptom Table

Start here with a hypothesis, not a guaranteed remedy. Match the symptom, inspect the actual implementation, then read the corresponding section.

| Problem | Starting hypothesis / next check |
| --- | --- |
| Animation stutters | Trace layout/paint work; test equivalent `transform`/`opacity` instead of geometry properties |
| Shadow animation is choppy | Test a visually equivalent `filter: drop-shadow()`; measure filtering cost and browser eligibility |
| Jank during navigation or loading | Look for main-thread contention; test an eligible CSS/WAAPI handoff and confirm it in a trace |
| Motion `x`/`y` drops frames | Inspect the installed version and actual path; a full `transform` string may use an eligible path without upgrading dependencies |
| Hand-rolled animation drops frames in React | Inspect per-frame state renders; use a ref or existing motion value for visual-only updates |
| Drag gets laggier as the list grows | Trace inherited CSS-variable invalidation; test direct `transform` on the animated element |
| Blur transition lags, especially in Safari | Reduce blur radius and surface size; a radius below 20px is a heuristic, not a budget guarantee |
| Unexpected properties animate | Replace `transition: all` with explicit properties |
| Element shifts 1px when motion starts or ends | Diagnose rasterization/layer changes; test scoped, temporary `will-change` only if evidence supports it |

## The Frame Budget

A 60Hz display has a nominal **16.7ms** refresh interval; 120Hz has **8.3ms**. That interval is not all available to application work: input handling, layout, drawing, and compositing also consume it. Use the repository's frame, interaction-latency, and workload budgets at the actual target refresh rates, not a universal “60fps is smooth” rule.

For scale, a complex layout recalculation can take over 100ms and miss several refresh opportunities. A property name or a low average duration cannot establish a frame-budget pass; inspect late-frame distribution under the real interaction.

Two things decide whether you stay inside the budget:

1. **What you animate**: how much work each frame costs.
2. **Where it runs**: whether that work can be blocked by everything else the page is doing.

## What You Animate

To show a visual change, the browser runs up to three steps:

- **Layout**: calculate the size and position of every element.
- **Paint**: draw the page into layers.
- **Composite**: put those layers on screen.

Properties can enter at different pipeline stages depending on browser, effect, layer state, and content. These are starting classifications, not guaranteed acceleration:

| Likely work | Properties | Caveat |
| --- | --- | --- |
| Composite-eligible | `transform`, `opacity` | Often reusable without layout/paint, but layer creation, rasterization, effect combinations, and per-frame JS can still cost frames |
| Conditional compositing or paint | `filter`, `clip-path`, `background-color` | Support varies by browser, value, content, and driver; filters may add expensive GPU work even without repaint |
| Paint + composite | `box-shadow`, `border-radius`, `color` | Usually redraw; the actual affected area and implementation determine cost |
| Layout + possible paint/composite | `width`, `height`, `padding`, `margin`, `top`, `left`, `border-width` | Geometry changes can propagate to surrounding content; trace the actual layout scope |

`transform` and `opacity` do not change document-flow geometry, which makes them good candidates when the same semantics can be retained. They do not prove layer promotion, off-main-thread execution, or a frame-budget pass. Test conditional paths across supported browsers and devices.

**Candidate cheaper paths, only when behavior and appearance remain equivalent:**

| Instead of | Animate |
| --- | --- |
| Visual-only growth without intended reflow | `scale()` on a visual surface; do not scale text or change the control's hit area unintentionally |
| Visual-only movement without intended reflow | `translate()` (percentages are relative to the element's own size) |
| A fade accompanying a visibility change | `opacity` plus the original visibility, focus, hit-testing, and accessibility semantics |
| A visually equivalent shadow | `filter: drop-shadow(…)`, after testing alpha-shape differences and filter cost |

An animated `box-shadow` often repaints; a `drop-shadow()` is only a candidate alternative, not necessarily cheaper or visually identical. Filtering a large surface can be costly even on an accelerated path.

Two things follow:

- **Layout animations don't always miss the budget, and scaling is not the same operation.** `padding` can alter wrapping and surrounding geometry; `scale()` can distort text and change visual/hit-test coordinates. Keep necessary layout behavior and measure its real cost. No property is immune to regression on slower devices.
- **Distinguish intended reflow from visual movement.** A sidebar's `margin-left` can relayout neighboring content each frame; `translateX` does not reserve or reclaim that space. Choose according to the interaction and reading-anchor contract, then trace the result.

## Where It Runs

**DOM updates driven by document `requestAnimationFrame` run on the main thread.** They compete with input, style/layout work, and other scripts. JavaScript can also run in workers, but a worker does not make ordinary DOM writes off-main-thread; OffscreenCanvas is a separate rendering path with its own costs.

| Driver | Scheduling / eligibility |
| --- | --- |
| Document JS + `requestAnimationFrame` (including JS-driven layout/gesture updates) | Callback and DOM updates on the main thread; rendered output may still use the compositor |
| Web Animations API (`element.animate()`, eligible Motion paths) | Can hand supported property/value animations to the compositor; unsupported cases and per-frame callbacks can involve the main thread |
| CSS transitions and keyframes | Also compositor-eligible for supported cases; layout/paint properties do not become cheap just because the driver is CSS |

**Compositor scheduling, GPU rendering, and meeting the frame budget are different claims.** An eligible animation can progress without a JS callback each frame, but setup, rasterization, uploads, large layers, filters, or GPU contention can still produce late frames. CSS or WAAPI is not a promise of smoothness under arbitrary load. Verify the actual path and late-frame work in a platform trace.

`transform` and `opacity` are widely supported candidates. Treat `filter`, `clip-path`, and `background-color` as conditional; property names alone establish none of these claims.

**Watch motion that coincides with heavy page work:** admitted page transitions or pointer-triggered tab indicators can overlap navigation, hydration, or long tasks. A compositor-eligible handoff may remove JS scheduling contention; it will not fix unrelated layout, paint, or GPU costs. Keyboard and high-frequency navigation remain instant under the canonical gate.

Motion can hand eligible `opacity` and full `transform` animations to WAAPI; `filter` and `clip-path` eligibility depends on the effect and browser. The independent `x`, `y`, `scale`, and `rotate` paths also depend on the installed version and configuration:

```jsx
<motion.div animate={{ x: 100 }} />                         // eligible independent-transform path in supported Motion 14.2+ configurations
<motion.div animate={{ transform: "translateX(100px)" }} /> // candidate full-transform WAAPI path; inspect the actual driver
```

Motion 14.2 introduced an eligible combined-transform path for independent transforms on supported HTML animations. Older versions may drive these values through JS; a full transform string can be an alternative when it preserves composition and behavior. Inspect the installed implementation instead of upgrading dependencies as a reflex. Layout animations (`layout`, `layoutId`), per-frame `onUpdate`, `transformTemplate`, inertia, drag, and `useTransform` may require main-thread work; identify what actually runs each frame rather than making an “every version” guarantee.

**Acceleration is progressive enhancement.** Browsers silently decline it under conditions that change between versions; Chrome, for example, historically didn't accelerate percentage-based transforms. That's not a reason to stop using `translateY(100%)`. Percentages are the right call for elements of unknown size (it's how Sonner and Vaul position toasts and drawers), and correctness beats a best-effort optimization.

## Native: Render Properties Are Not Custom Redraw

Route native implementation through [animate-native](../animate-native/SKILL.md). The web pipeline is an analogy, not an API translation:

- **Core Animation vs AppKit work.** Animating existing `CALayer` render properties such as `transform`, `position`, or `opacity` can reuse layer content through Core Animation. That does not move AppKit view updates, `draw(_:)`/`drawRect:`, invalidation, Auto Layout, or TextKit layout off the main thread. A layer-backed view can still redraw; masks, filters, rasterization, and layer area can be expensive. Updating a transform used inside custom drawing is redraw work, not automatically a Core Animation property animation.
- **Android View render properties vs custom drawing.** `View` translation, scale, rotation, and alpha can reuse display-list/render-property paths with hardware acceleration when supported. The animator, callbacks, and invalidation may still involve the UI thread; API choice alone proves no RenderThread/GPU handoff. `Canvas.scale()` inside `onDraw()` transforms the drawing commands: changing that input and calling `invalidate()` causes redraw/display-list recording, not a standalone View-property animation. `requestLayout()` requests measure/layout work and can add further drawing work.
- **Canvas transforms redraw.** A transform applied to a web canvas draw operation or native custom-drawing pass changes how that pass draws; it does not automatically animate already-rendered content without redraw. Distinguish that from a CSS transform of the canvas element, a Core Animation layer property, or an Android View render property. Hardware-accelerated drawing can still miss the budget.

Names such as `scale`, `transform`, “native,” or “hardware accelerated” prove neither acceleration nor cost. Record the actual interaction and renderer work: browser DevTools Performance for web; Instruments (Core Animation/Animation Hitches and Time Profiler as available) for AppKit; Perfetto/System Trace and frame timing for Android, including UI-thread and RenderThread slices. Compare with the repository's budgets on supported hardware. Use [appkit-interaction-proof](../appkit-interaction-proof/SKILL.md) for editor interaction evidence and the existing [layout](../appkit-textkit-layout/SKILL.md) and [scroll ownership](../scroll-animation-ownership/SKILL.md) skills rather than duplicating their protocols.

## React: Don't Animate Through State

Many animation libraries write visual values outside React's render cycle, but that alone does not guarantee smoothness. A hand-rolled `setState` on every frame can cause unnecessary reconciliation alongside rendering work. Move visual-only per-frame writes to an existing ref or motion value without losing semantic state or lifecycle updates.

```jsx
// Potential unnecessary per-frame React work:
setY(nextY);

// Avoids that React render; DOM/style and rendering work still need measurement:
ref.current.style.transform = `translateY(${nextY}px)`;
// or with a motion value: y.set(nextY)
```

Look for state updates inside `requestAnimationFrame`, `pointermove`, `scroll`, or drag handlers.

## Two Traps That Look Correct

Both of these use `transform` and still drop frames.

**Inherited CSS variables.** Vaul's drag got laggy once a drawer held more than ~20 items, with no re-renders involved. The drag distance was written to a CSS variable that `translateY()` read:

```js
// Can invalidate inherited dependent styles throughout the subtree:
const style = { "--swipe-amount": `${draggedDistance}px` };

// Direct visual update avoids that inherited-variable dependency:
const style = { transform: `translateY(${draggedDistance}px)` };
```

Custom properties inherit by default; changing one can invalidate dependent styles throughout a subtree. The exact affected set depends on references and browser optimizations, so confirm style-recalculation cost in a trace rather than claiming every descendant always recalculates. Direct `transform` on the animated element avoids that inheritance path. Keep existing ownership and semantic state intact.

**Blur.** Animated `filter: blur()` can become expensive, especially on large surfaces and in Safari. Under 20px is a useful starting heuristic, and 2–5px may soften a crossfade, but neither is a budget guarantee. Measure radius, surface area, backdrop interaction, rasterization, and filtering cost on the target hardware; use a smaller effect or no blur when justified.

## `will-change`

A rasterization or layer-state change can shift an element by a pixel, but that symptom does not prove a CPU-to-GPU handoff. `will-change` is a hint that may prepare a layer or other resources, not a forced promotion or an automatic fix:

```css
.drawer {
  will-change: transform;
}
```

**Test it only after diagnosing a layer/rasterization cost or measured shift.** Browsers may already prepare eligible animations, and extra layers consume memory and compositing resources. Scope the hint to the actual animated element while needed, not `*` or every large container; remove it when the animation no longer needs preparation.

For expensive paint or blur, verify whether preparation actually reduces late-frame work. A smaller surface often reduces raster/composite cost; a large promoted filtered layer can instead make GPU or memory pressure worse. Keep the change only with evidence under the repository's interaction budget.

## Should You Avoid JS Animation?

No. Main-thread animation is a valid tool when the required interaction needs it and measured work fits the budget. Contention can happen during normal input as well as loading; do not assume a busy main thread is rare or the only source of jank.

An existing Motion setup can provide velocity-aware springs, shared layout, exit lifecycle, and momentum gestures. CSS transitions and WAAPI also support interruption and programmatic cancellation; they are not categorically unable to retarget. Choose by the gate, behavior contract, and installed capabilities, not by a blanket CSS/JS rule. Do not add or upgrade a dependency just to claim acceleration.

**Working split:** try CSS transitions/WAAPI for admitted simple visual motion; use existing gesture/animation machinery when velocity continuity or lifecycle integration requires it. Whichever driver you choose, confirm eligibility and actual work with a trace.

## Workflow

### Phase 1: Find what animates

List every animation in scope with platform, driver, actual properties, input source, workload, and repository budget. Apply the canonical gate; remove unnecessary action/navigation buildup rather than optimizing it into existence. An approved smooth writing caret is evaluated separately: measure logical editing latency and visual/frame cost, not spring settling time as if it delayed insertion.

| Element | Platform / driver | Actual work to inspect | Input / workload |
| --- | --- | --- | --- |
| Tab indicator | Web `motion/react` `layoutId` | JS/layout and resulting transform writes | admitted pointer route change, not keyboard navigation |
| Drawer | Web pointer tracking + existing settle driver | per-frame updates and `transform` path | drag and release with representative content |
| Card hover | Web CSS transition | expand `all` before choosing exact properties | fine pointer; obey frequency gate |
| Native visual surface | Core Animation or Android View property animator | render properties vs redraw/invalidation/layout | actual native interaction and content |

Expand Motion shorthands and library APIs into what they actually update. For custom drawing, identify draw callbacks and invalidation/layout requests separately from any render-property animation.

### Phase 2: Diagnose

Use this checklist to form hypotheses, then follow the recording rather than assuming a universal order:

1. **What work happens each frame?** On web, distinguish layout, paint, composite, and JS; on native, distinguish render-property animation from custom redraw, invalidation, and layout. Even `transform`/`opacity` can be costly with large layers or effects.
2. **Does jank coincide with other work?** Inspect navigation, hydration, input, and long tasks. Test an eligible CSS/WAAPI handoff only when main-thread scheduling is the measured cause; native traces must likewise show which thread and work are late.
3. **Is React re-rendering per frame?** Inspect state updates in rAF, pointer, or scroll handlers; retain semantic state while reducing visual-only renders.
4. **Does cost grow with content?** Inspect inherited CSS-variable dependencies, redraw area, layer count, and nodes animating together. Do not add automatic stagger as a performance workaround that changes reading order or action timing.
5. **Which Motion path is installed?** Inspect shorthand expansion and configuration; test an equivalent full `transform` only if it changes the actual driver. No dependency upgrade is required as a reflex.
6. **Are blur/filter radius and area expensive?** Use measured cost, not a universal 20px cutoff.
7. **Does the trace show preparation/rasterization cost?** Test scoped, temporary `will-change` for that cause, then compare the same interaction. A remaining stutter alone is not evidence that it helps.

Record the actual interaction with representative data and concurrent work. On web use DevTools Performance for late frames, long tasks, style/layout/paint, and compositor activity; the Animations panel is for visual inspection, not a performance-budget pass. On native use the platform traces listed above. Profile supported hardware and the repository's declared budgets. Desktop CPU throttling models neither a weak GPU nor a small memory budget.

### Phase 3: Report

For each finding:

```
**[Element]**: `file.tsx:42`
Suspected cause: [work identified from code]
Trace evidence: [actual interaction, tool, thread/work and late-frame relationship; or not recorded]
Before: `transition: all 200ms` (includes unintended layout properties)
After: explicit equivalent visual properties using existing tokens, preserving behavior
Build/regression evidence: [checks actually run, or not run]
Visual/interaction evidence: [device + input source + lifecycle/anchor/accessibility checks, or not observed]
Performance evidence: [trace/benchmark, workload, hardware, refresh rate, repository budget + result, or not measured]
Causal conclusion: [supported by trace/comparable before-after evidence, or still a hypothesis]
```

A build proves compilation, a regression check proves only its covered behavior, a visual recording proves what was observed, and a benchmark pass proves that run met its stated budget. None alone proves which change caused an improvement. Preserve comparable workloads and trace evidence for a causal claim; do not report GPU/off-main-thread execution from an API or property name. Order findings by measured cost, apply only the requested fixes, then stop.
