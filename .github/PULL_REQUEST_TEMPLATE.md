## Summary

<!-- What does this change and why? Link any related issue: Closes #123 -->

## Checklist

- [ ] `swift test` passes
- [ ] `swift build -c release` succeeds
- [ ] Assertion-affecting changes were smoke-tested (`./scripts/smoke.sh`)
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` (or `skip-changelog` label applied for no user-facing impact)
- [ ] `README.md` / `PLAN.md` updated if behavior or status changed
- [ ] Respects the `CLI → Core → IOKit` boundary (no IOKit outside `Power/PowerManager.swift`)

## Verification

<!-- Commands run and their observed result. Paste relevant output. -->
