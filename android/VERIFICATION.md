# Android preview verification — 2026-09-13

## Reproduced checks

The final local build passed `:app:testDebugUnitTest :app:connectedDebugAndroidTest :app:lintDebug` with JDK 21 and the included Gradle wrapper.

- **64 JVM tests passed**, zero failures: request receipts/recovery, current API/model contracts, counted PDF continuation/revision, document source handling, Code workspace path/size/stale-edit checks, math scanning, speech chunking and worker/companion policy. The final five regressions cover quantity parsing with adjective phrases, Arabic/Persian digits, and rejection of page/row quantities and ambiguous ranges.
- **5 instrumentation tests passed**, zero failures, on an Android 15/API 35 Pixel 7 emulator. These mount the actual production Compose screens, select a model and submit text, open file/media cards without leaking hidden prompts, render a two-page PDF and close its viewer, and render bundled integral/chemistry glyphs with visible pixels and cache reuse.
- **Android lint: zero errors**. Dependency-update and deprecated-API warnings remain; these are not a claim of testing every Android version.
- The final chat screenshot was visually inspected: centered rendered integral, readable Arabic, native message controls and composer, no WebView scrollbar. The PDF screenshot visibly contains both pages.
- Staged source was checked for credential artifacts. The bundled Firebase configuration is public client configuration; no provider secret or Telegram bot token is included.
- A real guest session signed in to the existing live server, submitted `Reply only with OK` using nova 1, and displayed the returned `OK` in native Chat. `qa/android-live-guest.png` records this smoke test. It verifies basic live request/reply, not all model tiers or media generation.
- A real three-integral request produced a two-page PDF with rendered equations and solutions at the end. It opened inside the app, saved through Android's document picker (43,914 bytes), closed correctly and remained available from history after process restart. `qa/android-live-generated-pdf.png` shows that actual file. A separate counted-job request for three integrals also completed and returned a native four-page artifact. Neither smoke test represents a 1,000-item run.

## Screenshots

The files in `qa/` are actual screenshots from the Android emulator running production UI with explicit **local test fixtures**. They are not conceptual mockups and do not claim live model output:

| File | Evidence |
| --- | --- |
| `android-chat-dark.png` | Arabic chat, local KaTeX integral, native glass composer |
| `android-models.png` | All five model options |
| `android-code.png` | Code conversation surface |
| `android-agent.png` | Agent conversation surface |
| `android-brain.png` | Brain conversation surface |
| `android-chat-light.png` | Light theme content (test Activity status-bar style is not the MainActivity theme handler) |
| `android-file-media-cards.png` | Native saved PDF/media entry points |
| `android-pdf-viewer.png` | Real two-page PDF rendered by Android PdfRenderer |

## Companion verification

The independently packaged Windows companion passed **80 tests**, its source checks and a package audit of 56 intended entries plus eight Electron security switches. Its identity and user-data paths are separate from the existing desktop app. Source/backend files and private runtime state are excluded. Actual desktop sign-in and a paired physical phone/PC control session have **not** been tested.

## Release boundaries

Android 8/API 26 is the configured minimum; runtime testing above used API 35. A signed debug preview is for direct installation and is not a Play Store production release. GitHub build results are additional evidence for the exact published commit.

Provider-specific paid generation, a 1,000-item document run, real Telegram bot linking, microphone quality and physical-device worker operations remain acceptance tests. Instant FCM server push is not active because the current backend has no Android registration/sending endpoints. WorkManager reconciliation notifications may be delayed. Word/Excel/PowerPoint authoring/export and full-duplex voice do not yet have complete iPhone parity. The README describes these boundaries and the implemented behavior.
