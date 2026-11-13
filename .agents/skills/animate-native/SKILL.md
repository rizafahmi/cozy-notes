---
name: animate-native
description: Implement motion in native AppKit and Android Views without changing action timing, input semantics, view identity, persistence, focus, or reading position. Use for native banner/card fades, touch feedback, completion states, cancellation, and reduced or disabled animation. Reuses animate's decision gate; React Native belongs to animate-expo.
---

# Native Animation Implementation

Use [animate](../animate/SKILL.md)'s purpose/frequency/input gate and behavioral-contract checkpoint first. This is a platform adapter, not another motion philosophy or a new animation framework. Keep native feedback, logical text insertion/selection, search, keyboard navigation, and accessibility activation immediate. An approved smooth writing caret may interpolate visual position after ordinary typing without delaying the editing operation or owning viewport scrolling. A pure fade or an instant state change can also be right.

For specialized work, load only the relevant guide:

- [AppKit interaction proof](../appkit-interaction-proof/SKILL.md): event routing, focus, run-loop isolation, and explicit scenario completion.
- [AppKit TextKit layout](../appkit-textkit-layout/SKILL.md): pre-change anchors, UTF-16 ranges, and bounded relayout.
- [Scroll animation ownership](../scroll-animation-ownership/SKILL.md): viewport writers and direct-input handoff.
- [Animation performance](../animation-performance/SKILL.md): rendering-path and frame-cost evidence.
- [Write Swift](../write-swift/SKILL.md): language, toolchain, isolation, and sequential-mutation semantics. Honor the repository's SDK, Swift version, and test-runner conventions over newer examples.

## 1. Establish the transaction and input route

Trace the actual control, owning window/Activity, state mutation, and every caller before editing. Keep AppKit view changes on the main actor and Android view changes on the UI thread.

- **The model owns completion.** Perform the existing save, insert/remove, navigation, or warning action through its normal path. Animate acknowledgement afterward; never place the operation in an animation completion callback. Preserve existing asynchronous I/O, errors, conflicts, undo, and draft retention.
- **Source is explicit at the input boundary.** Touch/pointer-down may start custom feedback; keyboard, accessibility, and programmatic activation use native/static feedback. Do not classify a later callback from a stale global `currentEvent`, or infer touch from a `click` alone.
- **Preserve membership separately from occurrence identity.** Pending attachments may deduplicate URLs in order, while repeated links already in a note remain distinct occurrences. Reuse surviving cards and keep their actions bound to the right occurrence. Do not normalize paths or change equality as part of a fade.
- **Capture the reading anchor before the whole update**, including text replacement. Restore after necessary layout, clamp to valid bounds, and avoid a full-document relayout per frame. Layout updates do not authorize a new caret-follow scroll.
- **Keep the interaction footprint stable.** Animate a visual child or owned decoration, not the container that owns layout, hit testing, focus, and accessibility. Do not fade away an action before the user can invoke it.

Choose exact timing from existing motion tokens or platform conventions. The shared gate's web values are not native requirements. Do not add a dependency for an opacity transition.

### Smooth writing caret — a separate presentation contract

- Preserve an explicitly chosen writing feel instead of removing it solely because typing is frequent. The indicator can ease briefly while text, logical selection, IME, undo, and accessibility update immediately.
- Classify ordinary typing at the actual input boundary. Do not animate every small programmatic edit or infer typing from a stale global event. Keep selection, arrow/search navigation, paste/large changes, layout/scroll/focus changes, and reduced or explicitly disabled motion on a snap/hide path.
- On AppKit, an owned caret layer can commit model position/bounds immediately and use short critically damped additive springs for presentation continuity; native selection remains authoritative. Reuse the established response/damping, not a generic drawer spring.
- On Android, retain native `EditText` and `InputConnection` editing/selection semantics. If a passive cursor drawing/overlay is required, avoid per-frame allocation or text relayout, stop frames when settling ends, and cancel on focus/lifecycle/policy changes. Custom drawing still costs frames; it is not automatically a compositor property animation.
- Use the logical target, never the eased visual position, for any existing caret visibility check. The caret animation must neither start nor prolong a viewport scroll. Test text/selection immediately, rendered continuity over time, snap paths, and the existing typing/frame budgets independently.


## 2. Map normal, reduced, and disabled policy

| Platform | Read policy | Implementation boundary |
| --- | --- | --- |
| AppKit | `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`; observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` through `NSWorkspace.shared.notificationCenter` when live updates matter; include any existing app animation-disable preference | Reduced motion can be a short opacity fade or instant state. Explicit disabled motion applies the final state without creating an animator. |
| Android Views | `ValueAnimator.areAnimatorsEnabled()` on API 26+ for system animator enablement; also read existing app reduced/disabled preferences | This boolean is not a general reduced-motion API. Respect zero-duration system animation settings; do not bypass them with a custom frame loop. Map a separate reduced preference only where the platform/product actually exposes one. |

Check policy before starting motion and when the existing settings/lifecycle path reports a change. On return to the foreground, reconcile tracked feedback with current policy. Switching to disabled cancels pending animations/callbacks and applies the authoritative state; switching to reduced removes travel and settles or retargets to the chosen reduced state. Do not merely change the duration while an older completion can still run.

Static pressed/focus indication, readable status text, and an accessible announcement remain valid feedback. Animation policy must not change operation timing or the save result.

## 3. AppKit implementation

Reuse the control's native tracking and focus behavior. Animate an owned visual layer or a view's existing transition path; do not introduce a second owner for AppKit-managed layer properties.

- **Owned layer fade:** `CABasicAnimation(keyPath: "opacity")` is suitable for a visual backing/sublayer. Write its model-layer target with implicit actions disabled so removing the animation exposes the correct final state. Do not use persistent fill modes to disguise a stale model value.
- **View fade:** use the repository's `NSAnimationContext` / `animator().alphaValue` pattern for a normal `NSView` transition. Layout and action availability are committed separately. Verify the actual redraw path; a layer-backed view alone does not prove compositing.
- **Retargeting:** sample `layer.presentation()` before removing an owned animation, with the current model value as the fallback. Start from that displayed value toward the new model target. Cancel only the animation keys this feature owns.
- **Completion ownership:** a cancelled Core Animation delegate callback is not a successful transition. Check completion status and the existing lifetime/generation mechanism before hiding a view. Add a generation token only when queued callbacks can survive cancellation and affect a replacement.
- **Removal:** remove the logical occurrence and its interactive view immediately. If a visual exit bridge is useful, leave a passive snapshot/owned decoration in the old coordinates, outside stack layout. It must return no hit-test target, expose no duplicate accessibility element, and be discarded on completion or cancellation.
- **Banner entry:** update content and constraints once, make required warning actions immediately usable, then fade only the decoration that passed the gate. Do not animate text-container width, editor height, or a reading-origin restoration merely to soften a banner.
- **Scroll:** let native wheel/trackpad input take ownership from older programmatic motion. Use the scroll-ownership guide rather than tuning a spring to hide a competing writer.

Core Animation transform/opacity on an already-rendered layer can be compositor-eligible. Repeated `draw(_:)`, text layout, or constraint changes are different costs; measure instead of calling all native fades GPU-accelerated.

## 4. Android Views implementation

Preserve native `Button`/`EditText`/scroll behavior. Add custom feedback only where the shared gate finds a real gap.

- **Touch press:** start permitted visual feedback on `ACTION_DOWN`, restore on `ACTION_UP`, `ACTION_CANCEL`, or loss of the active pointer. Respect the control's existing inside/outside tracking. Do not consume events, manually invoke save, or replace the native click contract to obtain the scale.
- **Stable hit area:** animate a decoration/visual child when a scaled control would alter its interactive footprint. Keep the real focusable/clickable container fixed. Native ripple or static tint may already be sufficient.
- **Animator ownership:** use the existing `ViewPropertyAnimator`, `ObjectAnimator`, or `ValueAnimator` path for the actual property. Cancel/retarget from the current displayed value. Cancellation can invoke listener callbacks; guard stale end actions before changing visibility or recycled views. Reset transient visual state when detached or recreated.
- **Completion slot:** if a Save/Done crossfade passed the gate, reserve stable geometry, publish the actual saved status immediately, and keep only the authoritative action focusable and accessible. A fading label copy must not remain another clickable button or duplicate announcement. Never postpone the write until the fade ends.
- **Real persistence:** keep SAF permissions, writer/worker errors, and draft restoration on the existing path. Activity recreation or repeated activation must not repeat a completed write merely because the feedback restarts.
- **Rendering:** `alpha`, translation, and scale on a hardware-accelerated View may avoid relayout. `Canvas.scale()` inside `onDraw()` still participates in drawing and usually requires invalidation for each changed frame; it is not equivalent to an independently composited View property. `requestLayout()` is another cost. Trace the implemented path under realistic content.

Springs can serve a real gesture handoff or the explicitly approved visual writing-caret contract above; they are not universal feedback. Ordinary press/release timing may be symmetric. Hold-to-confirm changes the interaction contract and is not a visual-only substitution for a click.

## 5. Preflight runtime proof before building a harness

Use the repository's existing runner and fixtures first. Resolve prerequisites once rather than repeatedly rebuilding a throwaway probe to guess why input did not arrive.

**AppKit:** when the scenario depends on focus/tracking, use an isolated process with a real `NSApplication`, window, normal event loop, and observed first-responder/key-window state. A temporary signed `.app` may be needed for a credible activation environment; a bundle-less probe does not establish it. Check graphical-session and capture/input permissions before claiming visual or pointer-exit proof. Do not drain the shared test process's global event queue or block its main actor with sleeps.

**Android:** use the repo's Gradle wrapper, configured JDK/SDK, and an owned emulator/device. If instrumentation is used, confirm the runner/target package and signing compatibility before launch. Let the real Activity/UI thread and native input dispatch service the interaction. Record animation settings before changing them on an isolated emulator, and restore only the values you changed.

Use private temporary vault **and history** paths. Retain fixtures until explicit completion, then close only owned windows/processes and remove temporary probes/media. Do not kill the user's running app, alter their note/draft, or wipe shared emulator data to clean the scenario.

## 6. Verify the consumer contract once after editing

Select only cases that distinguish the changed branches:

- Pointer/touch down, pointer exit or cancellation, release, and a rapid re-press; keyboard/accessibility activation remains immediate.
- Insert/remove while a fade is active; a surviving control still opens/removes the correct item.
- `[A, A]`, `[A, B, A]`, and re-adding A where pending input should deduplicate; repeated existing links retain their intended occurrences.
- Real save through the owning controller/Activity, with the expected saved links, file count, and original attachment bytes—not just the preview card count.
- Update near the top/bottom of the document, with the reading anchor captured before text replacement and no delayed return after settling.
- Normal, reduced, and explicitly disabled animation; switch policy mid-transition when that path changed.
- Detach/Activity recreation if the change affects lifetime, with no stale hide callback, duplicate operation, or lost draft.

A user report is sufficient repro. Add a permanent regression only when no existing test covers the failing consumer path. Use a throwaway feature smoke for known straightforward behavior; preserve the repo's isolated, full-suite-safe test conventions. Do not pin source text, callback wiring, arbitrary duration defaults, or merely that nothing threw.

Require explicit completion and meaningful output. Pair native rendered proof with state/offset traces for temporal claims; a screenshot alone cannot establish cancellation or retargeting. Run the narrow check and any affected existing performance budget once after the completed change, not throughout editing.

Report separately: **build passed**, **regression passed**, **visually observed**, and **performance measured**. Include only evidence obtained. A passing optimized benchmark establishes that run's result, not which edit caused an improvement. Name unavailable focus, capture, physical input, or hardware coverage at the claim; do not replace it with a mock and call it visual proof.
