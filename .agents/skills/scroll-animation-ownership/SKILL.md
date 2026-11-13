---
name: scroll-animation-ownership
description: Use when implementing or debugging caret-follow scrolling, programmatic scroll springs, mouse-wheel or trackpad interruption, or content that snaps back after user scrolling. Defines who may write the viewport offset, traces actual offset versus animation target, and verifies input handoff through repeated events and settling.
---

# Scroll Animation Ownership

Direct user scrolling takes ownership from an older programmatic scroll. A wheel event can work correctly and still appear broken when a scheduled animation writes the old target back afterward.

Use [apple-design](../apple-design/SKILL.md) for motion principles and [appkit-interaction-proof](../appkit-interaction-proof/SKILL.md) for native event verification. This skill governs ownership and lifecycle, not spring tuning or a new animation framework.

## 1. Identify every viewport writer

Trace current definitions and references for:

- Native wheel, trackpad, scrollbar, and touch-scroll entry points.
- Caret visibility requests after typing or keyboard commands.
- Jump-to-heading, search-result, and navigation scrolling.
- Layout, resize, fold, and refresh anchor restoration.
- Scheduled spring ticks, animators, timers, and completion callbacks.

For AppKit, distinguish `NSScrollView` input handling from `NSClipView` offset mutations such as `scroll(to:)` and `setBoundsOrigin`. A caret layer animation is not necessarily a viewport animation.

Keep ownership in the existing scroll controller or event path. Do not add a second independent scroll engine or a broad gesture abstraction to solve one conflict.

## 2. Observe the sequence, not just the endpoint

Use a bounded diagnostic trace with:

- Monotonic elapsed time and the triggering action.
- Actual viewport origin, separately from any animation target.
- Target, velocity, pending callback or generation state when available.
- Document height, viewport height, and valid scroll bounds, including insets.
- Caret or selection location and the active fold state.
- Input delta, line versus precise-pixel scrolling, and gesture/momentum phases.

Sample before input, immediately after native input handling, during scheduled ticks, and after settling. A visually settled animation may still have a live target or pending callback.

Interpret the trace carefully:

- Offset advances on wheel input, then retreats toward an unchanged target: an older writer is overriding input.
- Offset cannot advance and the document fits the viewport: there may be no scrollable content.
- Offset temporarily exceeds an actual boundary and returns to that boundary: normal elasticity may explain it.
- Target is absent but offset still resets: investigate another writer or native layout anchoring.

Do not label every return movement a spring bug. Establish the scrollable bounds and which writer changed the offset.

## 3. Hand off ownership before delegating input

When a fix is authorized, the input contract is:

1. Cancel or invalidate the older programmatic animation before it can write another offset.
2. Clear its obsolete target and velocity, not only the timer handle.
3. Ensure queued callbacks from that animation cannot restart it. Use the existing cancellation/lifetime mechanism; add generation protection only if callbacks can survive cancellation.
4. Delegate the original event once, unchanged, through the native input path on the same turn.
5. Let the platform own gesture tracking, momentum, and boundary elasticity.
6. Resume caret-follow scrolling only for a fresh action that intentionally requires it, such as typing or keyboard navigation.

Verify the interception point actually receives each relevant input type. For AppKit, `willStartLiveScroll`/`didEndLiveScroll` do not bracket every legacy mouse-wheel event; notifications alone may miss the reported device path.

Do not swallow the event, complete the old spring at its target, replay wheel deltas manually, or defer native input behind an animation.

## 4. Keep geometry changes from resurrecting old intent

Fold/unfold and resize can invalidate a scroll target without changing the user's selection. Reconcile that target with the new geometry rather than treating it as a permanent reading anchor.

- Anchor required geometry updates once, from pre-change visible content; see [appkit-textkit-layout](../appkit-textkit-layout/SKILL.md).
- Do not reapply the same anchor on every bounds-change or drawing callback.
- Distinguish a layout refresh from a new request to reveal the caret.
- Start a newly requested animation from the actual current offset, not the old target.
- Preserve the platform's valid overscroll behavior instead of globally disabling elasticity.

A drawing or layout callback observing the caret is not user intent to return to it. Likewise, retaining a target after apparent settling can keep stealing input long after the initiating command.

## 5. Prove interruption and subsequent behavior

Use enough content to scroll and keep the probe away from a boundary. Exercise the exact initiating path, then:

- Scroll during the programmatic animation, with several successive inputs.
- Scroll again after it appears settled.
- Reverse direction and check that input remains responsive.
- Observe idle callbacks long enough to detect a delayed return to the old target.
- Issue a fresh intentional caret/navigation scroll and verify that programmatic scrolling still works.

The contract is continued user-directed progress within valid bounds, without the old target being reasserted. One immediate offset change, a non-throwing event handler, or a screenshot of the final position is insufficient proof.

For native input, cover the device paths affected by the change: line-wheel input, precise scrolling, and gesture momentum where reachable. State any unverified hardware or phase behavior explicitly.

Do not fix the symptom by increasing damping, shortening the animation, adding a cooldown, disabling caret-follow scrolling, or repeatedly restoring an origin. Resolve the competing writer and its lifetime.

## Session evidence and repository anchors

The earlier Cozy Notes investigation reproduced bounce-back after Tab folding and unfolding: eight wheel inputs advanced the viewport before old caret-follow spring ticks pulled it toward an unchanged target. That failure concerned the viewport writer, not the separate visual caret layer.

The app subsequently removed the viewport spring and now updates automatic scroll origins immediately. Approved ordinary-typing caret easing has been restored only to the visual indicator; it must never read its presentation position as scrolling intent. Current navigation anchors are `Sources/CozyNotes/CaptureEditor.swift`: `doCommand(by:)`, `ensureCaretVisible`, `currentCaretRect`, `updateCaret`, and the clip-view bounds observer. Resolve current definitions rather than searching for the removed `scrollSpringTargetY`, `stepScrollSpring`, or `cancelScrollSpring`.
