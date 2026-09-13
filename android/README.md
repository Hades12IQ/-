# Firas AI — native Android preview

This is a Kotlin/Jetpack Compose application, not the website inside a WebView. Its warm charcoal, sage accents, floating glass controls, six themes and fixed-position navigation follow the native iPhone app. Arabic and English content retain their own reading direction. A separate, restricted local WebView renders bundled mathematics; conversation text and controls remain native and selectable.

## Build and install

- Android 8.0/API 26 or newer; compile/target SDK 36.
- JDK 21, Android SDK 36 and Gradle 8.13 (included wrapper).
- Set `ANDROID_HOME`, or create an ignored `local.properties` with the SDK location.
- Run `./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug`.
- Install `app/build/outputs/apk/debug/app-debug.apk` for local testing.
- GitHub workflow `Build native Firas AI Android` publishes a signed **preview** APK and SHA-256 checksum in `android-build-<run>` prereleases. Production Play signing is not configured. Preview signing now requires the encrypted repository secret `FIRAS_ANDROID_PREVIEW_KEYSTORE_B64`; missing or invalid material stops the build. The dedicated private key has an owner-restricted local backup outside this repository. Never regenerate or rotate it for an ordinary update.
- Previews 2 and 3 used different ephemeral runner keys because the old cache path did not exist. Those private keys were not retained, so they cannot update directly to the new stable signing identity. Preserve/export local files before any reinstall; do not assume local-only data survives uninstall. The stable key's public SHA-256 certificate fingerprint is `BB:F0:AA:40:0A:81:46:28:DF:63:94:39:53:B2:7A:C6:AC:C2:A5:DD:8E:8A:88:92:0B:EA:99:A7:9B:6F:BF:2D`.

## Implemented paths

- Native authentication, guest mode, account-owned conversation history, Chat/Code/Agent/Brain, five current model choices (luma 1, nova 1, titan 1, atlas 1, omnix 1), temporary conversations and native theme settings.
- iPhone-style native glass sheets for models and the plus menu: individual model symbols, descriptions and selection marks; real Photos, Files and full-size Camera attachments; supported-tier thinking control. Sheets preserve the draft, dismiss with native gestures, and adapt to the selected theme. Camera capture uses the system app without adding camera/storage permissions; attachment results are scoped to the current account, session and conversation.
- Durable server jobs with persisted request receipts, account checks, submission recovery without duplicate generation, explicit cancellation and reconnect polling. Closing the app does not cancel accepted cloud jobs.
- Bundled KaTeX and chemistry rendering, incomplete-formula previews while streaming, per-account glyph caching, native text selection, Ask Firas, translation language selection and floating navigation to the latest message.
- Authenticated PDF/media downloads, native PDF/image/audio/video viewing, working close controls, Android Share/Open with and Save to Files. Internal media/document prompts are not shown as conversation answers.
- Counted PDF requests use the server's durable document job, including 100/1,000-item requests, explicit continuation of partial work and revisions that preserve the original count. A valid partial PDF can be viewed, saved and shared; cards report completed and remaining items. This routing is contract-tested; a paid 1,000-item run has not been performed as a release test.
- A Code text workspace beside a saved Code conversation: create/edit files, import UTF-8 ZIPs, inspect changed files before applying them, reject stale replacements, export ZIP and submit the current project to the selected model. This is a source editor, not an arbitrary compiler. Limits: 30 files, 60,000 characters per file, 180,000 serialized project characters, 2 MB compressed ZIP.
- Omnix account access, cloud-session/job/approval/file contracts and native Telegram connection settings use existing authenticated endpoints. Only server-advertised approvals are actionable; a truncated command cannot be approved.
- Real media studio, document/text attachments and Brain library import. PDF extraction requires a text layer; this preview does not claim OCR for every scanned PDF. Office attachment extraction preserves text, not original visual layout.
- Push-to-talk voice recognition followed by Firas speech playback. Closing the call stops local recording/playback while accepted cloud work continues in Chat. This is not a full duplex realtime call implementation.

## Notifications and workers

Enable notifications in Settings; Android 13+ asks for notification permission. Local completion notifications cover cloud jobs, the phone worker and observed PC tasks, with account/task deduplication. Background reconciliation uses WorkManager and can be delayed by Android. The Firebase client receiver is present, but the current web server does **not** expose the Android push registration/sending endpoints. Instant server push is therefore not operational or claimed in this preview.

For phone control, open Worker → **This phone** → **Enable control**, then enable Firas Worker in Android Accessibility settings. **Share screen** separately opens Android's screen-sharing consent dialog. Each action or screenshot upload requires **Allow once**, and the overlay provides **Stop**. Phone work is local, limited to 24 steps/10 minutes, and does not replay actions after process/account loss.

For PC control, use the separately packaged **FirasCompanion-Portable-2.0.0-x64.exe** for Windows. It has its own app identity and storage; the ordinary desktop build cannot pair. Use the same account, a reachable private network and an awake PC. On the PC choose **Android → Pair or manage Android phone… → Create pairing code**; paste the code into Android **Worker → Windows PC** and confirm on the PC. The connection pins the certificate; losing the heartbeat pauses further actions until explicitly resumed. A paired physical PC/phone session remains a separate acceptance test. The portable is not Authenticode-signed.

## Preview boundaries

This release is not a claim that every iPhone feature has completed Android acceptance testing. Live provider generation, paid model permissions, Telegram bot pairing, microphone quality and phone/PC control depend on an actual account/device setup. General-purpose Word/Excel/PowerPoint authoring/export is not yet at iPhone parity; the app must not claim a downloadable Office artifact from a filename or hidden fence alone. No provider keys or Telegram bot tokens are bundled in the APK.

## Verification

The project includes JVM contract/security tests and Android instrumentation tests that mount the production composables, exercise the bundled renderer, model selection, sending, real native PDF close behavior and artifact/media opening. Screenshot text in those tests is explicitly local fixture content, not a fabricated live model response. Current release results and real emulator evidence are recorded in `VERIFICATION.md`.
