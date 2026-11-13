# Plan Template

Use this structure for requested written plans, not as a mandatory stage after implementation approval. The executor may have no conversation context: include the actual platform, preserved contracts, exact targets with provenance, and runtime prerequisites. No references to "the audit above" or "the easing we discussed."

```markdown
# NNN — <Short imperative title>

- **Status**: TODO
- **Source basis**: <affected paths/symbols and exact current excerpts or an available snapshot identity; no mandatory git stamp>
- **Severity**: HIGH | MEDIUM | LOW
- **Category**: <audit category>
- **Scope**: <actual files, behavior, and non-goals>

## Problem

What is wrong, where, and why it matters to the consumer. Distinguish source
evidence, user-reported failure, runtime observation, and unverified feel or
performance. Cite actual locations and include the relevant current excerpt:

​```css
/* src/components/dropdown.css:14 — current */
.dropdown { transition: all 400ms ease-in; }
​```

## Target

The exact end state: API/properties, values, token or platform provenance,
normal/reduced/explicit-disabled policy, and input-source gating. Reuse existing
native feedback and repository tokens; new values need a stated reason:

​```css
/* target */
.dropdown {
  transition: transform 200ms var(--ease-out), opacity 200ms var(--ease-out);
  transform-origin: var(--transform-origin);
}
​```

## Repo conventions to follow

How this codebase already does it, with one exemplar the executor should
imitate (token names, file placement, prop patterns):

- <actual existing token/platform transition, its exact value, and where it is defined; no new parallel motion system>
- <exemplar file:line that already does this correctly>

## Preserved behavioral contracts

Record only contracts relevant to this change, with the current owner/call path:

- **Timing/input**: <operation stays immediate; pointer/touch vs keyboard,
  accessibility, programmatic, or independent asynchronous state>
- **Data/identity**: <order and deduplication boundary; legitimate repeated
  occurrences; surviving view/action identity; real persisted result>
- **Interaction/layout**: <focus, stable hit areas, accessibility exposure,
  selection/undo, and reading anchor captured before the full text/layout update>
- **Lifetime/policy**: <retargeting from the displayed state, owned cancellation,
  stale callbacks, recreation, and live normal/reduced/disabled changes>

## Runtime prerequisites

Resolve these before constructing or rebuilding a probe:

- **Platform/toolchain**: <repo runner, supported SDK/runtime, configured JDK
  and Android SDK or AppKit launch environment>
- **Input/rendering**: <actual surface and required focus, first responder,
  event loop, permissions, device/emulator, instrumentation/signing compatibility>
- **Isolation**: <owned process/window, private vault and history paths,
  fixture lifetime, settings to restore, and throwaway artifacts to remove>

## Steps

1. <One concrete edit per step: file, what changes, resulting code.>
2. …

## Boundaries

- Do NOT touch <files/components out of scope>.
- Do NOT change storage, confirmation, input, or layout semantics merely to animate presentation.
- Do NOT add dependencies or a parallel motion/scroll controller.
- If a step drifts from current source, re-read the affected path and adapt to existing conventions. Stop only for a materially different contract or decision; do not blindly apply stale excerpts.

## Verification

- **Mechanical**: <narrow exact command needed for this change; expected explicit
  completion. Run after editing, not throughout; no unrelated lint/build suite.>
- **Consumer regression**: <existing test or scenario for the real changed path;
  add a regression only for an uncovered plausible consumer-visible failure.>
- **Runtime/feel**: launch the actual surface and exercise <interaction>:
  - <immediate operation and focus/action availability>
  - <retarget/cancel/reverse or occurrence removal with the correct survivor>
  - <preserved reading position or persisted links/files/original bytes, if relevant>
  - <normal, reduced, and explicitly disabled settings; live switch if affected>
  - <actual native input route or web frame-by-frame inspection, not a mock of the surface>
- **Performance**: <affected existing product budget and measured interaction,
  if needed; API/property names and benchmark passes are not causal proof.>
- **Evidence ledger**: <separate build passed / regression passed / visually
  observed / performance measured; include only evidence obtained and name limits.>
- **Done when**: <observable consumer contract plus explicit check completion;
  unverified hardware/visual coverage is stated, not inferred as passed.>
```

## Notes for the plan author

- One plan per finding. If two findings share every file and the same fix pattern (e.g. the same easing token swap across components), they may merge into one plan.
- Apply [animate](../animate/SKILL.md)'s shared gate and checkpoint, [AUDIT.md](AUDIT.md)'s evidence requirements, and [animate-native](../animate-native/SKILL.md) for native APIs/lifecycle. Copy existing token/platform values exactly; samples are starting points, not universal requirements.
- Runtime proof is required for changed behavior. A screenshot establishes one rendered instant, not interruption or delayed callbacks. State unavailable focus, capture, or hardware coverage honestly rather than replacing it with a fake success.
- Include an index only when the requested plan set needs one; list execution order and true dependencies. Direct implementation approval does not require plan files.
