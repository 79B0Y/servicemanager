# Repository Guidelines

## Project Structure & Module Organization
- `app/`: Android entry module (activities, UI, DI, wiring).
- `modules/core/`: Shared business logic and utilities.
- `modules/device/`: ADB/device control (shell, input, screen capture).
- `scripts/`: Local/CI helper scripts (setup, lint, release).
- `tests/`: Test resources and fixtures shared across modules.
- `docs/`: Architecture notes and design decisions.
- Packages live under `com.yourorg.androidcontrol`. Add new features as modules under `modules/` to keep concerns isolated and testable.

## Build, Test, and Development Commands
- `./gradlew assembleDebug`: Build debug APK.
- `./gradlew testDebugUnitTest`: Run JVM unit tests.
- `./gradlew connectedDebugAndroidTest`: Run instrumented tests (device/emulator required).
- `./gradlew lint ktlintCheck detekt`: Static analysis (Android Lint, ktlint, Detekt).
- `adb devices`: Verify device connectivity.
- `adb install -r app/build/outputs/apk/debug/app-debug.apk`: Install debug build.

## Coding Style & Naming Conventions
- Language: Kotlin preferred (Java allowed for legacy integrations).
- Indentation: 4 spaces; soft wrap >100 columns when reasonable.
- Naming: Classes `PascalCase`; methods/vars `camelCase`; constants `UPPER_SNAKE_CASE`.
- Packages: lowercased, dot‑separated (e.g., `com.yourorg.androidcontrol.device`).
- Linting/formatting: ktlint + Detekt; Android Lint. Auto-fix with `./gradlew ktlintFormat`.

## Testing Guidelines
- Frameworks: JUnit, Mockito/Kotlin, AndroidX Test/Espresso for UI.
- Location: Unit tests in `src/test`; instrumented in `src/androidTest` (mirror source packages).
- Conventions: Suffix with `Test` (e.g., `DeviceControllerTest`), Arrange‑Act‑Assert.
- Coverage: Aim ≥80% for `modules/core` and `modules/device`.

## Commit & Pull Request Guidelines
- Commits: Conventional Commits (e.g., `feat: add swipe gesture`). Subject imperative, ≤72 chars; include rationale in body.
- PRs: Link issues, describe behavior/impact, add screenshots for UI, note tests/coverage changes, update docs if behavior changes. Ensure CI green before merge.

## Security & Configuration Tips
- Never commit secrets, keystores, or `local.properties`. Use Gradle properties or environment variables.
- Ensure `.gitignore` excludes `/build`, `*.keystore`, and local configs.
- Prefer debug configs that run without secrets; keep device IDs and ADB settings out of VCS.

