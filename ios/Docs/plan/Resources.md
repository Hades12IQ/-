# Plan — `Resources/` (deletions Batch 0; `Info.plist` Batch 2)

| File | Batch | Purpose | Behaviour | Read |
|---|---|---|---|---|
| `Resources/Info.plist` (keep, extend) | 2 | plist | Add `UIBackgroundModes` = `[audio, fetch, processing]`; `BGTaskSchedulerPermittedIdentifiers` = `[$(PRODUCT_BUNDLE_IDENTIFIER).jobs]`; `NSSpeechRecognitionUsageDescription` (ar/en via `InfoPlist.strings`); `ITSAppUsesNonExemptEncryption` = false; `UIApplicationSceneManifest` with `UIApplicationSupportsMultipleScenes` = true (no per-window state work); keep the Google custom URL scheme and add a `firasai` scheme for `?share/?verify/?reset` links; `UILaunchScreen` colour `LaunchBackground` = `#262624`. Existing camera/mic/photo usage strings stay. | `audit-ios-shell-settings-design.md §2.2 F25–F26, §3`, `audit-ios-voice.md §E`, `ARCHITECTURE.md §2.5` |
| `Resources/ar.lproj/InfoPlist.strings`, `Resources/en.lproj/InfoPlist.strings` (keep, extend) | 2 | OS strings | Add the speech-recognition description in both languages. | — |
| `Resources/FirasComplete.wav` (keep) | 0 | notification sound | Referenced by `NotificationManager`. | `server-auth-session-account.md §6.5` |
| `Resources/Sounds/send.caf`, `Resources/Sounds/done.caf` (optional) | 2 | UI sounds | If not produced, `FirasSound` stays a no-op; never reference them from code by force. | `design-brief.md §5.2` |
| `Resources/Assets.xcassets` (keep) | 0 | icons, `AccentColor`, `LaunchBackground` | `LaunchBackground` = `#262624`. | `audit-ios-shell-settings-design.md §2.2 F26` |
| `Resources/Localizable.xcstrings` | 0 | **delete** | All app copy lives in `Localization/`. | `ARCHITECTURE.md §2.9` |

Also delete at the `ios/` level (Batch 0): `ExportOptions.plist`, `export-ipa.sh`, `IPA-EXPORT.md`
(they contradict the unsigned CI pipeline — `audit-ios-shell-settings-design.md §2.2 F35`).
