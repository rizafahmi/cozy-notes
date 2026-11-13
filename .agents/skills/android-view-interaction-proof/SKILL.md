---
name: android-view-interaction-proof
description: Use when verifying Android Views interaction regressions involving InputConnection editing, native caret/cursor behavior, touch or key dispatch, scrolling, animation, lifecycle, or Activity recreation. Builds atomic UI-thread observations, distinguishes logical state from rendered state, and requires native completion rather than a draw count or a successful-looking invocation.
---

# Android View Interaction Proof

Prove the consumer's interaction sequence, not a handler call or a screenshot. Input delivery, logical mutation, layout, drawing, and settling are different stages; success at one says nothing about the next.

Use [animate-native](../animate-native/SKILL.md) for implementation and [CARET.md](../animate-native/CARET.md) for the writing-caret contract. Use [scroll-animation-ownership](../scroll-animation-ownership/SKILL.md) for competing viewport writers. This skill covers Android verification; AppKit belongs to [appkit-interaction-proof](../appkit-interaction-proof/SKILL.md).

## 1. Set the verification boundary

- Treat a user-reported failure as a valid repro. Do not rerun it merely to challenge the report.
- Name the exact route: `InputConnection.commitText`, `setComposingText`, `deleteSurroundingText`, `sendKeyEvent`, accessibility action, direct `Editable` mutation, `setText`, touch, or programmatic API. They are not interchangeable coverage.
- If the request is verification-only, do not modify app code, add permanent tests, or turn the diagnostic into a fix.
- Use the real Activity/View that owns the behavior. A standalone `EditText` probe does not cover Activity recreation, window focus, IME routing, or the app's observers.
- Use an owned emulator/device and private app data. Do not alter the user's vault, draft, or shared emulator data to obtain a cleaner fixture.

State whether evidence came from instrumentation driving real input, accessibility/UI automation, or physical hardware. They are different coverage claims.

## 2. Prepare the runtime and geometry

- Use the repository's Gradle wrapper, JDK, SDK, and build variants. Confirm the instrumentation package, target package, signing compatibility, and API level before launch.
- Record the effective configuration, not just the physical one:

```sh
adb shell wm size
adb shell wm density
adb shell settings get system font_scale
adb shell settings get global animator_duration_scale
adb shell settings get global window_animation_scale
adb shell settings get global transition_animation_scale
```

A persisted density override can make a nominal 320×640 device narrower than a supported phone layout. Check the computed dp width against the product's supported minimum before diagnosing a layout or glyph-wrap failure.

- Record animation settings before changing them. Restore only the values you changed, in a `finally` path; include originally absent entries.
- Keep fixtures isolated and bounded. Retain them until explicit completion, then uninstall only the owned probe and remove owned media.

## 3. Drive real input

- Let the Activity, UI thread, and native input dispatcher service the interaction. Do not call private handlers or assign internal state to simulate typing.
- For IME routes, use `InputConnection` methods on the editor's actual connection. For hardware keys, dispatch a complete `KeyEvent` down/up sequence through the window or `InputConnection.sendKeyEvent` as appropriate.
- For touch, dispatch real `MotionEvent` down/move/up/cancel with correct coordinates and time; check the control's inside/outside tracking and active-pointer loss.
- Programmatic mutation is a separate case. Exercise it through the public API (`setText`, `Editable.replace`, selection API) and expect the snap path.
- Establish focus and window visibility explicitly. Observe `isFocused`/window focus rather than assuming `requestFocus` succeeded.

## 4. Observe atomically

**Capture before, operation, and immediate after inside the same UI-thread task.** Comparing positions across separate `runOnMainSync` calls can include legitimate animation or layout advancement and produce false failures.

```java
runOnMainSync(() -> {
    before = snapshot(editor);
    connection.commitText("i", 1);
    immediate = snapshot(editor);
});
```

Then observe later frames separately. A rapid-retarget claim can use the atomic before/after for logical continuity; the animation envelope needs subsequent frame samples.

For asynchronous settling, use a bounded deadline and a condition tied to native state, not a sleep or an arbitrary draw count. A `ViewTreeObserver.OnDrawListener` schedules samples; it does not prove that the cursor drawable ran.

### Snapshot both states separately

| State | Examples |
| --- | --- |
| Logical | text, `selectionStart`/`selectionEnd`, composing spans, undo availability, focus |
| Rendered | cursor drawable/overlay position, target, velocity, running/pending flags, actual view origin |
| Geometry | view location in window, width/height, padding, text size/scale, line spacing, typeface |

Do not infer rendered position from the selection index. Bidirectional and split carets make that false.

## 5. Native cursor and draw completion

- The cursor drawable's bounds are authoritative and update during the native draw. Reading them immediately after `endInput` can return the previous target.
- If the implementation admits a selection move and defers target resolution to the next draw, completion is “no pending typing and bounds reflect the new target,” not “one draw listener fired.”
- Sample until that condition or the deadline. Permit the native draw to run naturally; do not post fake invalidations as a substitute for cursor drawing, and do not poll with sleeps.
- Check that idle frames stop. A settled spring must remove its Choreographer callback and must not keep invalidating.
- For rapid reversal, assert the displayed position stays within the envelope from the captured before position to the new target; exact equality across separate tasks is not a valid assertion.

## 6. Scrolling and geometry callbacks

- Distinguish editor-local scrolling from ancestor/sibling tree scrolling. A global `OnScrollChangedListener` fires for both.
- Assert that an unrelated container scroll leaves the caret animation running; assert that moving the editor itself cancels/snaps.
- Verify the no-op case: requesting the current viewport origin must not cancel an in-flight caret animation. Compare actual offset, not animation target.
- Resize, rotate, and layout changes should snap; no stale target may survive.

## 7. Screenshots and media

Instrumentation may run inside the target process but its `getContext()` can still address the probe package.

- Write screenshots through `getTargetContext().getFilesDir()` or another target-owned path, then pull them:

```sh
adb exec-out run-as <target.package> cat "files/<name>.png" > local.png
```

- Verify the file exists and is decodable. An `ENOENT` means the path, not the UI, was wrong.
- A screenshot proves one rendered instant. Pair it with state/offset traces for cancellation, retargeting, or persistence claims.

## 8. Lifecycle and policy

- Test Activity recreation for accepted state, draft retention, and observer/callback cleanup. Recreating must not repeat a completed write or resurrect an old animation target.
- Switch normal → reduced → disabled while motion is active; confirm cancellation, authoritative final state, and no stale completion.
- Detach/re-attach the view and verify frame callbacks, content observers, and scroll/layout listeners are removed. No duplicate observer may remain.
- Restore settings and delete owned probe media even when the scenario fails.

## 9. Select cases by mechanism

Useful dimensions:

- IME commit, composition start/update, whole-word replacement, backspace, large commit.
- Rapid repeated commit and reversal; same-coordinate combining/zero-width edit.
- Direct `Editable` mutation, `setText`, programmatic selection, accessibility selection, arrow/key navigation.
- Focus loss and restoration, window visibility, Activity recreation.
- Editor-local scroll vs ancestor/sibling scroll; resize/rotation.
- Normal, reduced, disabled animation; policy switch mid-flight.
- Touch down/cancel/up and keyboard activation for feedback controls.

Choose only the dimensions that distinguish the changed branch. Do not build an exhaustive cross-product.

## 10. Require completion and report separated evidence

Run the narrowest relevant check after a code change. Add a regression only when existing tests do not cover the failing consumer path; a verification-only investigation needs no new permanent test.

- Require the instrumentation's final result and all claimed cases. A started test, a draw callback, or a command returning is not proof that the target completed.
- Preserve failures rather than swallowing them in shell pipelines.
- Assert consumer-visible results: immediate logical text/selection, actual rendered movement, no overshoot, settled frames stopped, exact saved output, retained draft.
- Do not test source text, callback wiring, arbitrary durations, or merely that nothing threw.

Report separately:

- **build/install passed**
- **instrumentation case passed**
- **visually observed** (state the route and screenshot)
- **performance measured** (state the device, API level, frame trace, and budget; emulator timing is not hardware proof)

Name unverified API levels, physical keyboards, OEM IMEs, magnifier behavior, and hardware frame costs. Do not replace them with a mock and call it device proof.

## Session evidence

A native caret probe initially failed because it compared positions captured in separate `runOnMainSync` tasks; capturing before/after inside the same input task passed. It also failed while counting `View` draws before the cursor drawable ran; waiting for `pendingTyping == false` with updated native bounds passed.

A persisted 420 dpi override on a 320×640 emulator produced a ~122 dp-wide app, below the supported phone layout, and caused false wrap/target failures. `wm size 1080x1920` restored the intended ~411 dp scenario. Screenshots written with the probe context produced `ENOENT`; `getTargetContext()` plus `run-as` worked.

The lesson: verify the actual native state transition and effective environment, not a proxy that merely looks like progress.
