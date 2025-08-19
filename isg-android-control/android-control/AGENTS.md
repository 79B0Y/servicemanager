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
- Build: `./gradlew assembleDebug` — assembles the debug APK.
- Unit tests: `./gradlew testDebugUnitTest` — runs JVM tests.
- Instrumented tests: `./gradlew connectedDebugAndroidTest` — requires device/emulator.
- Static analysis: `./gradlew lint ktlintCheck detekt` — Android Lint, ktlint, Detekt.
- Format: `./gradlew ktlintFormat` — auto-fixes Kotlin formatting.
- Device: `adb devices` — verify connectivity; install: `adb install -r app/build/outputs/apk/debug/app-debug.apk`.

## Coding Style & Naming Conventions
- Language: Kotlin preferred (Java allowed for legacy).
- Indentation: 4 spaces; soft-wrap >100 cols when reasonable.
- Naming: Classes `PascalCase`; methods/vars `camelCase`; constants `UPPER_SNAKE_CASE`.
- Packages: lowercased, dot-separated (e.g., `com.yourorg.androidcontrol.device`).
- Linting: ktlint + Detekt + Android Lint. Keep code warning-free.

## Testing Guidelines
- Frameworks: JUnit, Mockito/Kotlin, AndroidX Test/Espresso for UI.
- Location: Unit tests in `src/test`; instrumented in `src/androidTest` (mirror source packages).
- Conventions: Test classes end with `Test` (e.g., `DeviceControllerTest`), use Arrange–Act–Assert.
- Coverage: Aim ≥80% for `modules/core` and `modules/device`.

## Commit & Pull Request Guidelines
- Commits: Conventional Commits (e.g., `feat: add swipe gesture`), imperative subject ≤72 chars; include rationale in body.
- PRs: Link issues, describe behavior/impact, add screenshots for UI, note tests/coverage changes, update docs if behavior changes.
- CI: Ensure `assembleDebug`, tests, and static analysis pass before merge.

## Security & Configuration Tips
- Never commit secrets, keystores, or `local.properties`. Use Gradle properties or env vars.
- `.gitignore` must exclude `/build`, `*.keystore`, and local configs.
- Prefer debug configs that run without secrets; keep device IDs and ADB settings out of VCS.

