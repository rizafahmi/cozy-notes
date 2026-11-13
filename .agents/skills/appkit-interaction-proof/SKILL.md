---
name: appkit-interaction-proof
description: Use when verifying native AppKit editor regressions involving folding, resizing, selection, wheel scrolling, or asynchronous animation. Builds isolated interaction sequences, derives input coordinates from current geometry, avoids shared event-queue interference, and requires explicit case completion rather than a successful-looking invocation.
---

# AppKit Interaction Proof

Prove the consumer's interaction sequence, not merely a handler call. Fold, resize, scroll, and settling are different stages; success at one stage says nothing about the next.

Use [appkit-textkit-layout](../appkit-textkit-layout/SKILL.md) for layout invariants, [scroll-animation-ownership](../scroll-animation-ownership/SKILL.md) for competing viewport writers, and [write-swift](../write-swift/SKILL.md) for Swift test and isolation details.

## 1. Set the verification boundary

- Treat a user-reported failure as a valid repro. Reproduce it when verification is requested or a concrete uncertainty remains; do not rerun it merely to challenge the report.
- Name the exact path: Tab folding, gutter folding, and outline folding can have different selection and scroll behavior.
- If the request is verification-only, do not modify app code, add permanent tests, deploy a bundle, or turn the diagnostic into a fix.
- Use the real view/controller that owns the failing behavior. If workspace callbacks matter, an editor-only probe does not cover them.
- Use synthetic notes and an isolated window or temporary vault. Do not edit the user's note, terminate their running app, or discard their draft to obtain a cleaner fixture.

State whether evidence came from native handlers with synthetic events, accessibility/UI automation, or actual hardware input. They are not interchangeable coverage claims.

## 2. Choose an isolated execution mode

### Standalone native probe

Use a separate process with an `NSApplication`, an actual window, and the real editor/controller. Let the normal AppKit run loop service scheduled callbacks when the behavior depends on timers, springs, or asynchronous layout.

Set up main-actor ownership, layout, visibility, and first responder explicitly. Observe that the window has the required focus rather than assuming that ordering it front succeeded.

Retain the fixture until the scenario completes. Remove observers, invalidate timers, close only the probe's window, and delete throwaway source/binaries after collecting evidence.

### Regression test in the existing suite

Reuse the repository's test runner and fixture conventions. In Cozy Notes, preserve the XCTest/Swift Testing compatibility pattern and use private temporary vault/history directories when storage is involved.

Do not post dummy mouse events or drain `NSApplication`'s global event queue from a shared regression test to force progress. This can consume unrelated input, enter nested tracking, or interfere with later parameterized cases. Tests that require full native tracking belong in an isolated process or supported UI automation.

Use asynchronous observation with a bounded deadline where settling matters. Do not block the main actor with sleeps or treat an arbitrary delay as evidence of completion. When an AppKit view dispatches work onto a background `DispatchQueue` and hops back via `DispatchQueue.main.async` or `asyncAfter` (e.g. `SearchPanel.refresh()`), mark the test `async` and yield with `try? await Task.sleep(...)` inside the deadline loop rather than synchronous `RunLoop.current.run(until:)`, which can starve `DispatchQueue.main` on Swift Testing's cooperative `@MainActor` executor.

When constructing synthetic vault files for negative security or boundary assertions (e.g. `Extracted Text/*.md` companions), match the domain engine's full content-signature contract (`<!-- cozy-extracted-text:v1 ... -->`) rather than relying on folder paths alone, and verify that a rejected operation leaves no side-effect file before subsequent assertions.

After completing a user-facing UI change on macOS, check whether `.build-app/Cozy Notes.app` exists or is currently running (`swift build` and `swift test` only update `.build/`); rebuild via `scripts/build-macos.sh` so the live app bundle reflects the new UI.

## 3. Derive input from current geometry

For a synthetic gutter or outline click:

1. Resolve the current target view and logical heading/item.
2. Establish the layout needed for that target and display the relevant surface.
3. Obtain the point from the actual affordance geometry, including the current font weight, insets, row metrics, and text-container origin.
4. Convert from target-view coordinates to window coordinates through AppKit.
5. Establish that the point reaches the intended affordance before dispatching the event.

Do not reuse coordinates from another window width, backing scale, fold state, or screenshot. A folded badge may use different font metrics from an unfolded badge.

Prefer a supported control or accessibility action when available. If the point misses a fold affordance, `NSTextView.mouseDown` may fall through into selection tracking and wait for a mouse-up. Fail the probe precondition or use a complete native press/release sequence in an isolated process; do not hide the miss with global queue pumping.

For wheel input, enter through the real event route. Distinguish line-wheel and precise-pixel events, including phases where relevant. Directly setting a clip origin cannot prove that mouse-wheel dispatch works.

## 4. Observe before, during, and after

Capture the initial selection, visible coverage, content, and target geometry. Record:

- The input action and its immediate effect, captured in the same run-loop turn as the input.
- Subsequent layout or animation updates.
- The resulting visible geometry and selection.
- Settled state or an explicit deadline failure.

Comparing before/after state across separate turns can include legitimate animation or layout progress and produce false failures. Capture the immediate effect atomically; sample later frames separately for continuity.

For a no-op visibility request (the desired viewport origin already equals the current origin), assert both that the origin did not change and that an in-flight caret animation still exists. A redundant `setBoundsOrigin`/`reflectScrolledClipView` can cancel the presentation even though the viewport looks unchanged.

For folds, compare following-heading spacing with expected paragraph spacing, not merely with its expanded position. Check that folding leaves source Markdown unchanged and preserves selection unless the selected content becomes hidden.

For wheel conflicts, record actual clip origin and animation target separately. Repeated inputs followed by idle callbacks expose a return movement that a single event or screenshot misses.

A screenshot proves a rendered surface at one instant. Pair it with the offset/state trace for temporal claims. If focus, capture permissions, or hardware access limit the probe, report the limit rather than claiming visual or device verification.

## 5. Select cases by the failure mechanism

Useful dimensions include:

- Caret above/below visible folds, and caret inside the section being collapsed.
- Two simultaneously visible folds rather than only one active heading.
- Small fully laid-out notes and large non-contiguous/lazy layouts.
- LF/CRLF, final sections, and mixed code, checklist, quote, and table content.
- Wide-to-narrow-to-wide resizing.
- Tab, gutter, and outline paths.
- Wheel input during an animation, after apparent settling, and on repeated or reversed input.

Choose the dimensions that distinguish the changed branches. Do not build an exhaustive cross-product merely because the inputs exist.

A useful sequence is fold -> resize -> wheel -> settle -> unfold -> wheel -> settle. Establish each stage's preconditions so a later failure is not mistaken for a missed earlier click.

## 6. Require explicit completion and meaningful assertions

Run the narrowest relevant check after a code change. Add a regression only when the existing tests do not cover the failing consumer path; a verification-only investigation needs no new permanent test.

Separate input-handler cost from mutation cost. Synthetic key dispatch, first-responder handoff, `NSTextStorage` mutation, and the editor/layout update are different timestamps; one end-to-end number hides which budget moved. State the measured segment, not just “typing latency.”

Require the runner's final completion summary and all claimed parameterized cases. Case-start messages, a command returning, or other tests passing are not proof that the target test completed. Preserve failures when capturing output through shell pipelines.

Assertions should catch visible failures: excess folded height, changed selection, a displaced viewport, lost wheel progress, or a delayed return to an old target. Do not test source text, internal wiring, arbitrary finite values, or merely that event handling did not throw.

Keep correctness and performance proof separate. The existing Moby-Dick workout covers layout, typing, resize, and memory budgets; it does not establish that wheel input interrupts a scroll spring. Run the relevant correctness checks and existing performance harness once after the completed code change, not throughout editing.

Report the exact verified path, check/scenario, completion result, and remaining limits. Use "not reproduced in this scenario" rather than "fixed" when no fix was applied.

## Session evidence

A mouse-fold regression invocation stopped showing progress after two parameterized case starts while other fold checks and the workout passed. Removing test-level global event posting/draining allowed all four mouse cases to complete. A separate native Tab -> wheel probe then exposed bounce-back that those geometry and performance checks did not cover.

The lesson is to verify the next interaction and the runner's actual completion, not to generalize success from nearby tests.

A later caret probe added two checks. A no-op viewport request was cancelling backspace easing in a real AppKit window; comparing the desired origin before writing fixed it without a new scroll engine. Atomic before/after capture within one input turn also avoided false resets that appeared only when state was compared across turns. Native key dispatch produced separate handler and storage-mutation timings, so neither was reported as the other.
