# Implementation verification

## Scope

Continuous screenshot sessions while the floating card remains open; per-session ordered analysis;
current-turn image binding; multi-image browsing and recovery; native two-dimensional dragging and
resizing; nonactivating full-screen selection. Development build only, not a public release.

## Local evidence (2026-09-12)

- The local compiler is Swift 6.1.2; the packages require Swift tools 6.2. Full package tests must run
  on the remote Xcode 26 runner. Local parse/typecheck checks do not substitute for package tests.
- ContextStore standalone typecheck passed. A synthetic runtime smoke passed save, append, restore,
  capture-ID image lookup, state transitions and removal.
- Security regression smoke rejected injected legacy capture paths and symlinked session directories
  for read/write/delete, without changing the external fixture file.
- Geometry/panel standalone typechecks and changed production-file syntax checks passed.
- Independent cross-review covered the coordinator lifetime wiring, current-turn image binding, and
  full-screen selection cleanup. No confirmed issue remained in those reviewed paths.
- Integration review found a text-request versus new-screenshot serialization conflict; its fix and
  regression test are part of the implementation, not an unrelated scope expansion.

## Required remaining verification

- Remote Core conversation tests and Mac app tests on the exact new commit.
- Successful arm64 app build and artifact verification.
- Local install and launch of that artifact.
- Interactive acceptance: Option+Q inside a full-screen app; repeated capture in one open card;
  drag in both axes, resize, close/reopen boundaries and retry/skip behavior.

## Installation identity

The currently installed `/Applications/Peekaboo.app` has an ad-hoc CDHash designated requirement.
The local keychain reports no valid code-signing identity. Replacing this binary can require renewed
screen-recording consent. Keeping the same installation path alone does not guarantee TCC identity
continuity; do not claim the new build preserves permission grants until verified.
