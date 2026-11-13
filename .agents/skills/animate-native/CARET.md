# Native Writing Caret

Reference for [animate-native](SKILL.md). [animate](../animate/SKILL.md) owns the motion gate; this file owns the caret presentation contract, platform mechanics, and proof.

A caret is two states that must never be conflated:

- **Logical state** — text, UTF-16 selection, composing region, undo grouping, focus, accessibility. Commit immediately through the platform.
- **Rendered state** — the drawn bar's position, bounds, and opacity. It may trail ordinary typing without delaying the edit.

Spring settling time is not input latency. Measure and report them separately.

## 1. The contract

1. **Only ordinary typing eases the rendered caret.** One committed character or one backspace, delivered through the platform's normal typing route, may retarget the bar.
2. **Everything else snaps.** Selection and navigation, paste/drop, undo/redo, programmatic mutation, large replacements, marked/composing text, focus loss, window deactivation, scrolling, resize/fold/theme geometry, reduced motion, disabled animators, foreign or magnifier cursors, and non-visible windows.
3. **Classify at the input boundary.** Do not infer typing from a small character delta, a global `currentEvent`, or a generic text-change callback. A programmatic one-character edit is still programmatic.
4. **Use the logical target for visibility and scrolling.** The rendered position must never authorize a viewport write, extend a scroll, or decide whether the caret is on screen.
5. **A viewport write is an ownership event even when the value is unchanged.** If a caret-visibility path computes the current origin, return before calling `setBoundsOrigin`/`scroll(to:)`, or the observer may cancel the caret animation as if the user had scrolled.
6. **No bounce.** Functional typing gets critical damping; visible overshoot is a gesture or expressive exception, not a writing default.
7. **Preserve an explicitly chosen writing feel.** Frequency alone does not delete an approved caret convention; a real defect (delayed edits, displaced reading position, stale lifecycle state) does.

### Snap matrix

| Event | Rendered caret |
| --- | --- |
| Ordinary key or IME character commit, backspace | Ease from the displayed position |
| Rapid typing or reversal | Retarget continuously; clamp velocity so the target is not crossed |
| Same-coordinate edit that changes native bounds (combining glyph, width change) | Resume the existing spring; snap only if idle |
| Selection, arrow/search navigation, mouse/touch placement, accessibility action | Snap |
| Paste, drop, undo/redo, direct `Editable` mutation, `setText` | Snap |
| Marked/composing IME text, replacement spanning more than one insertion point | Snap |
| Focus loss, window resign, control detach, Activity recreation | Cancel and hide; restore with a snap |
| Scroll, resize, fold, font/theme/layout change | Snap |
| Reduced motion, disabled animators, non-visible window | Snap or hide |
| Foreign cursor drawable, magnifier, split/bidi caret not owned by the presentation | Draw the native bounds unchanged; do not ease |

## 2. AppKit recipe

- Own a `CALayer` sublayer and suppress AppKit's insertion-point drawing only if the layer is fully responsible for it.
- Commit the model position and bounds to the logical target with implicit actions disabled. Add short **additive** springs for the visual delta (`position`, and `bounds` when width/height changes).
- Reuse the established response/damping convention. In Cozy Notes that is a 0.125-second response with critical damping; this is a platform convention, not a universal value.
- Keep a sequence suffix on owned animation keys so stale travel animations can be removed without touching blink or unrelated layers.
- **Additive composition is not automatic retargeting.** An additive spring composes with the layer's current model/animation state. If you add a fresh from-model delta while an older travel animation is still live, verify rapid reversal on screen; `layer.position` is the model, not the presentation. Either let the existing additive animation compose, or retarget explicitly from `layer.presentation()` and remove the keys you own.
- Blink is independent. Do not restart or reconfigure blink timers from the travel animation.
- The existing caret-visibility check must use the logical selection rectangle. Compute the desired clip origin, compare it with the current origin, and return before writing when equal.
- On focus loss, resize, scroll, selection change, or policy change: remove travel animations and show the bar at the logical target immediately.

## 3. Android recipe

Keep native `EditText` and `InputConnection` authoritative. A passive cursor drawable may draw the eased bar while returning the native bounds unchanged.

- Use `TextView.setTextCursorDrawable` on API 29+ and intercept this editor's themed cursor resource on API 26–28. Do not reach hidden `Editor` fields, replace the cursor view, or disable native insertion handles/blink.
- **Native drawable bounds are the geometry.** They include bidi and split-caret behavior. Do not re-derive x/y from `selectionStart` and a layout call.
- **Bounds update during the native draw.** Reading them in `endInput` can return the previous target. Drop the owned queued frame when an admitted selection move is pending; let the next native draw resolve the target, reset the frame clock, and schedule exactly one callback even if the spring was already running.
- Admit typing only when one input transaction produced one expected text change and the selection equals the expected target. Text or selection changes outside that transaction snap.
- A same-coordinate admitted edit must resume an already-running spring, not only the target-change branch; combining glyphs and zero-width changes can move bounds without moving the index.
- Spring analytically on the Choreographer. Sample the displayed position and velocity, retarget from them, clamp reversal velocity so the target is not crossed, stop when both displacement and velocity are below threshold, and remove the callback on detach/policy change.
- Reconcile viewport changes by scope:
  - Editor-local `onScrollChanged` may snap.
  - A tree-level `OnScrollChangedListener` fires for ancestors and siblings. Compare the editor's window location, size, padding, text size/scale, line spacing, and typeface; snap only when one changed. Unrelated tree scrolling must not cancel typing.
- Respect `ValueAnimator.areAnimatorsEnabled()` plus the product's reduced-motion preference. Disabled means no animator and an immediate authoritative draw.

## 4. Viewport separation

The caret presentation owns no scroll state.

- A caret-follow path may request scrolling from the logical target, but the render animation must not start, extend, or retarget a viewport animation.
- A scroll of any kind snaps the caret; do not try to preserve apparent continuity by moving the caret with the viewport.
- When showing or hiding surrounding chrome (banner, chip strip, outline), capture the reading anchor once, apply the layout change, restore the anchor, and keep the caret's logical target unchanged.
- Preserve `NSScrollView`/`NSClipView` native wheel and trackpad ownership. A caret layer is not a scroll writer.

## 5. Proof

Choose cases that distinguish the changed branches; do not build an exhaustive cross-product.

| Claim | AppKit | Android |
| --- | --- | --- |
| Text and selection are immediate | Real key events through a real window/responder; assert storage and selection before the next display link | `InputConnection.commitText`/`deleteSurroundingText`; assert logical text and selection in the same UI task |
| The rendered bar actually eases | Sample `layer.presentation()` across frames; require a presentation offset from the target | Sample the drawable position when the native drawable reflects the new bounds; require motion, not just arrival |
| Rapid retarget does not reset or overshoot | Rapid key sequence; compare displayed position and keys before/after the second input | Capture before/after in one input task; cross-task advancement is legitimate. Check the analytic envelope |
| Snap paths | Selection, arrow, paste, undo, programmatic edit, focus loss, resize, wheel, reduced motion | Same, plus direct `Editable`, `setText`, accessibility, IME selection, layout/scroll, policy settings |
| Lifecycle | Remove observers/callbacks; close only the probe window | Detach observers, stop frames, restore settings, retain draft on recreation |

- Do not assert a fixed number of draws as completion. Sample the native cursor state (`pendingTyping == false` with updated bounds) or an equivalent authoritative condition, with a bounded deadline.
- A screenshot proves one instant; pair it with state/offset traces for temporal claims.
- Report logical input latency, rendered cadence, and spring settling separately. A passing benchmark does not prove which edit caused the result.
- Name unavailable API levels, physical keyboards, OEM IMEs, magnifier behavior, and hardware frame costs rather than substituting a mock.

## 6. Anti-patterns

| Never | Instead |
| --- | --- |
| Delay `insertText`, selection, IME commit, or save until the spring ends | Commit immediately; ease only the rendered bar |
| Ease every text change | Classify typing at the input boundary; snap programmatic edits |
| Use the eased position to decide caret visibility or scrolling | Use the logical target |
| Read Android cursor bounds before the native draw | Let the draw resolve bounds; drop the stale queued frame |
| Reimplement bidi/split-caret layout | Draw the platform's cursor bounds |
| Assert “animated” because a draw count elapsed | Require observed presentation/target separation and native state completion |
| Write a viewport origin that already equals the desired value | Compare and return before writing |
| Cancel typing on any tree-level scroll notification | Reconcile the editor's own geometry |
| Use a generic drawer/spring duration | Reuse the writing-caret response/damping convention |
| Add bounce “so typing feels alive” | Critical damping; bounce needs a gesture or rare expressive purpose |
