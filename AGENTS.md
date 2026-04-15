# AGENTS.md — CB File Hub

## Project layout

This is **not** a standard single-package Flutter app. The repo root is a workspace with two packages and a build system:

```
cb_file_manager/   ← main Flutter app (all flutter/dart commands run here)
mobile_smb_native/ ← local FFI plugin (SMB/CIFS via libsmb2, path dependency)
Makefile           ← primary build orchestrator (requires Git Bash on Windows)
scripts/           ← build, version, and CI helper scripts (bash)
installer/         ← Windows installer configs (Inno Setup, WiX)
```

**All `flutter` and `dart` commands must be run from `cb_file_manager/`**, not the repo root.

## Flutter version

Pinned to **3.41.5 stable** (`build.config`, CI workflows). Use this exact version.

## Developer commands

Run from repo root via Makefile (requires Git Bash on Windows):

| Task | Command |
|------|---------|
| Install deps | `make deps` |
| Unit/widget tests | `make dev-test mode=unit` |
| E2E tests (parallel) | `make dev-test mode=e2e` |
| E2E single suite | `make dev-test mode=e2e TEST=Navigation` |
| E2E single file | `make dev-test mode=e2e TEST_FILE=video_thumbnails_e2e_test` |
| Rerun failed E2E only | `make dev-test mode=e2e RERUN=1` |
| E2E plain output (debug) | `make dev-test-e2e-only` |
| Analyze | `make analyze` |
| Format | `make format` |
| Format + analyze | `make verify` |
| Clean | `make clean` |
| Deep clean (rebuild) | `make deep-clean` then `make deps` |

Or run Flutter directly from `cb_file_manager/`:

```bash
flutter pub get
flutter test                           # unit/widget tests
flutter test --reporter expanded       # verbose test output
flutter analyze
dart format --output=none --set-exit-if-changed .   # format check (CI uses this)
flutter test integration_test -d windows --dart-define=CB_E2E=true  # E2E
```

## CI pipeline order

CI runs: **format check -> analyze -> unit tests -> E2E (Windows) -> build**. Match this locally with `make verify` before pushing.

## Architecture notes

- **State management:** BLoC (`flutter_bloc`) + Provider + GetIt (service locator in `lib/core/service_locator.dart`)
- **Design system:** Fluent UI on desktop, Material on mobile. Controlled by `DesignSystemConfig` feature flags. The app can run as either `FluentApp` or `MaterialApp`.
- **Localization:** Custom delegate-based (Vietnamese + English) in `lib/config/languages/`. Does **not** use Flutter's `gen-l10n` / ARB files.
- **Navigation:** Tab-based via `TabMainScreen` (`lib/ui/tab_manager/`), not standard Flutter routing.
- **Database:** SQLite via `sqflite` / `sqflite_common_ffi`. On Windows, uses system `winsqlite3.dll` (no bundled DLL).
- **Video:** `media_kit` (primary) + `flutter_vlc_player` (fallback).
- **Streaming:** Built-in HTTP media server via `shelf` (`lib/services/streaming/`).
- **Network browsing:** SMB/CIFS via local `mobile_smb_native` FFI plugin, plus FTP support.
- **Windows native:** Uses `win32` FFI, acrylic backdrop, native tab drag-drop, PiP windowing.

## Feature flags (compile-time)

Passed via `--dart-define=FLAG=value`:

- `CB_E2E=true` — enables E2E test mode (required for integration tests)
- `CB_SHOW_DEV_OVERLAY=true` — shows developer debug overlay
- `CB_ENABLE_FLUENT_DESKTOP_SHELL` — Fluent UI shell toggle

## Key conventions

- **`avoid_print` is disabled** in `analysis_options.yaml` — `print()` is intentionally used in dev/debug code.
- **`main.dart` is 900+ lines** — contains app initialization, window setup, service bootstrap, and the root widget. It is the real wiring diagram of the app.
- **No code generation** — `build_runner` is a dev dependency (for MSIX packaging) but there is no `build.yaml` and no generated Dart code to worry about.
- **Entry point for tests:** unit/widget tests in `cb_file_manager/test/`, E2E in `cb_file_manager/integration_test/`. E2E tooling (parallel runner, Allure adapter, dashboard) lives in `cb_file_manager/tool/`.

## Windows build gotchas

- If Windows build fails with `MSB3073` / `cmake_install` / `INSTALL.vcxproj`: run `make dev-test-e2e-clean` (or `make deep-clean && make deps`).
- The `scripts/build.sh` auto-retries CMake race conditions and patches pdfx CMake compatibility.
- MSI builds require WiX Toolset. MSIX signing requires `MSIX_CERT_BASE64` and `MSIX_CERT_PASSWORD` secrets.

## Release workflow

- Version lives in `cb_file_manager/pubspec.yaml`. Use `make release-patch`, `release-minor`, or `release-major`.
- Tags matching `v*.*.*` trigger the release CI pipeline (GitHub Actions + GitLab CI).
- Build number is auto-incremented in CI.
