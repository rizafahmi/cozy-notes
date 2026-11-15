## Summary
<!-- Describe what this change does and why. -->

## Verification
- [ ] `swift build && swift test` passes cleanly on a clean checkout
- [ ] `shellcheck scripts/build-macos.sh scripts/package-release-macos.sh` passes (if shell scripts were modified)
- [ ] Preserves core invariants: zero network calls, zero external Swift packages, programmatic AppKit only, and plain-file storage
- [ ] Moby-Dick performance budgets (`MobyDickWorkoutTests`) pass within threshold
