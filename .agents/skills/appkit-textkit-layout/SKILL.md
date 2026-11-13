---
name: appkit-textkit-layout
description: Use when implementing or debugging AppKit editor folding, caret jumps, resize gaps, or viewport instability in NSTextView with TextKit 1. Separates glyph visibility from layout height, preserves UTF-16 paragraph boundaries, and scopes relayout to pre-change visible content without forcing whole-document layout.
---

# AppKit TextKit Layout

Treat storage, layout, drawing, selection, and scrolling as separate responsibilities. A visually hidden paragraph can still occupy space; a correct caret character index can still appear to jump because the viewport moved.

Use [write-swift](../write-swift/SKILL.md) for Swift and actor-isolation details, [appkit-interaction-proof](../appkit-interaction-proof/SKILL.md) for native verification, and [scroll-animation-ownership](../scroll-animation-ownership/SKILL.md) when user scrolling fights a programmatic target.

## 1. Establish the text system and the failing path

- Inspect the editor construction path and SDK baseline before choosing APIs. This procedure targets TextKit 1's `NSTextStorage`, `NSLayoutManager`, `NSTextContainer`, and typesetter pipeline. Do not transplant legacy callbacks into a TextKit 2 editor or force a compatibility switch just to inspect it.
- Identify the actual interaction: gutter click, outline click, Tab, outline cycling, typing, or window resize. They can reach different command and scroll paths.
- Record the selected UTF-16 range, visible document rect, text-container origin, relevant fold ranges, and whether the caret lies inside a fold.
- Use current definitions and references to trace layout invalidation, selection updates, and viewport writers. Do not infer that a similarly named handler is the caller.

Keep UI and layout mutations on the main actor. A `nonisolated` override may use `MainActor.assumeIsolated` only when its execution context is established; the assertion does not dispatch work to the main actor.

## 2. Collapse layout, not just drawing

The folding contract is:

- Source text remains unchanged.
- The heading stays visible.
- Hidden body text contributes no line-fragment height or paragraph spacing.
- The following visible heading retains its normal spacing.

Suppressing glyph drawing alone does not satisfy that contract. Null or not-shown glyphs can leave line height, paragraph spacing, or extra fragments behind. Measure the following heading's position rather than treating invisible text as proof of collapse.

For a TextKit 1 editor with a custom typesetter, a contiguous hidden remainder can be represented by one zero-height fragment. Respect the typesetter's paragraph, line, glyph-range, text-container, and begin/end lifecycle contracts. Do not emulate folding by shrinking every font, deleting Markdown, or repeatedly changing paragraph styles.

Keep fold intervals sorted. Reuse their storage and locate the enclosing interval without allocating per paragraph, font run, or glyph. Avoid one empty fragment per hidden line when the whole hidden remainder can be handled together.

Invalidate layout when fold geometry changes. Regenerate glyphs only when glyph generation actually changes; redundant glyph invalidation adds work and can disturb cached layout.

## 3. Preserve UTF-16 ranges and paragraph separators

- Use `NSString` and `NSRange` consistently for TextKit character positions. Swift character counts are not UTF-16 offsets. Glyph ranges and character ranges are also not interchangeable.
- Define body-fold boundaries at complete paragraph boundaries. Preserve the heading's line separator even when the fold reaches the document's end.
- Handle LF and CRLF without splitting the CR/LF pair. Exercise final sections with and without a trailing newline.
- For hierarchical folding, stop at the next heading of the same or higher level. A body-only fold must not accidentally hide child headings.
- Recompute ranges after edits using the editor's existing range-shifting rules. Do not compensate for stale ranges with layout offsets.

A hidden-line count is metadata, not a measurement of hidden layout height.

## 4. Anchor resizing to pre-change visible content

A lazily laid-out document can contain estimated or non-contiguous geometry after a width change. Preserve an anchor from the old layout before changing that width.

1. Snapshot the visible character coverage before changing insets, text-container width, or text-view geometry.
2. Convert document-view coordinates to text-container coordinates using `textContainerOrigin` exactly once. Do not mix `visibleRect`, clip-view coordinates, and glyph rectangles without conversion.
3. If the old visible layout is unavailable, establish only the layout needed to obtain a valid anchor before mutation. Do not invent a character anchor from a document-height ratio.
4. Apply the geometry change and invalidate the affected layout.
5. Refresh folds intersecting the captured visible coverage, including the following visible line needed to establish continuity.
6. Restore any required reading anchor from character layout, then verify the selection and visible spacing.

Use a bounded contiguous layout span where continuity matters. Do not call whole-container `ensureLayout` on every layout or scroll callback to hide uncertainty in a large document.

The caret is not the viewport anchor when it is elsewhere. Two visible folded sections must stay collapsed even if the caret is above, below, or offscreen. If folding actually hides the caret, moving it to a visible heading boundary is a separate, intentional selection transition.

## 5. Separate same-line edits from navigation

For an edit that leaves the caret on the same logical line and already inside the viewport, preserve the viewport rather than applying a typewriter breathing margin again. Repeated checking and unchecking should not recenter a visible row.

Capture the affected edit location before delegate callbacks consume or clear pending edit metadata. Compare the resulting logical lines using the current UTF-16 text, not stale offsets or visual row numbers.

Keep normal caret-follow behavior for newlines, intentional keyboard navigation, and edits that genuinely move the caret out of view. Do not disable scrolling globally to fix a checklist jump. Preserve existing selection adjustment, undo grouping, and edit notification semantics.

Caret drawing and caret animation do not themselves authorize a viewport scroll. Use the scroll-ownership skill when a scheduled scroll continues after direct user input.

## Verification contract

Choose cases that exercise the changed branches, not every possible combination:

- A small fully laid-out note and a large lazily laid-out note.
- Mixed prose, code fences, checklists, quotes, and tables inside a fold.
- LF/CRLF, nested headings, and the final section's document tail.
- Fold, narrow resize, wide resize, and unfold with the caret outside the visible folded headings.
- Repeated same-line checklist edits near both viewport edges, plus newline and navigation controls.

Assert consumer-visible geometry: the next heading follows the folded heading with the expected paragraph spacing; hidden body height does not survive resizing; Markdown remains unchanged by folding; selection changes only when its content becomes hidden.

For code changes, run the narrow relevant regressions and the existing editor performance harness after the edit. Correct spacing does not prove typing or resize performance, and a fast benchmark does not prove interaction correctness.

## Session evidence and repository anchors

In Cozy Notes, glyph-delegate hiding left blank body space. A custom `FoldTypesetter` established zero-height hidden layout. A later resize regression depended on the caret; capturing pre-change visible characters covered visible folds independently of it.

Current starting points are `Sources/CozyNotes/CaptureEditor.swift` (`FoldTypesetter`, `computeFoldedSection`, `refreshFoldLayoutAfterGeometryChange`, and `didChangeText`) and `Tests/CozyNotesTests/MobyDickWorkoutTests.swift`. Resolve their current definitions rather than retaining line numbers or build artifacts.
