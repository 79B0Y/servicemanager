# Contributing

Thanks for helping improve this project! This guide summarizes how to contribute effectively. For full repo practices, see AGENTS.md.

## Getting Started
- Use Android Studio; ensure JDK and Android SDK installed.
- Build once locally: `./gradlew assembleDebug`.
- Run checks: `./gradlew testDebugUnitTest lint ktlintCheck detekt`.

## Branching
- Base branch: `main`.
- Create feature branches: `feat/<scope>-<short-description>` (e.g., `feat/device-swipe`).
- Bugfix branches: `fix/<scope>-<short-description>`.

## Commit Messages
- Follow Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `build:`.
- Subject in imperative mood, ≤72 chars.
- Include rationale or context in body when useful.

## Pull Requests
- Keep PRs focused and small; link issues (e.g., `Closes #123`).
- Describe behavior/impact; include screenshots/GIFs for UI changes.
- Note tests added/updated and any coverage considerations.
- Update docs when behavior or public APIs change.

## Pre-Push Checklist
- `./gradlew testDebugUnitTest` passes; add tests for new logic.
- Static analysis clean: `./gradlew lint ktlintCheck detekt`.
- Build succeeds: `./gradlew assembleDebug`.
- No secrets committed; review `.gitignore` and configs.

## Where Things Live
- App code: `app/`.
- Shared logic: `modules/core/`.
- Device control/ADB: `modules/device/`.
- Scripts: `scripts/`; Tests resources: `tests/`; Docs: `docs/`.

By contributing, you agree to follow repository guidelines in `AGENTS.md`.

