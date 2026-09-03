# Plan — `Features/Settings/` (Batch 1, one owner; also `Localization/Strings+Settings.swift`, `Stores/AnnouncementStore.swift`, `Stores/MemoryStore.swift`)

Interfaces: `INTERFACES.md` → `SettingsView`. Design: `design-brief.md §7.15–7.16, §7.18, §8`.
Delete `PreferenceSettingsViews.swift` (split into Appearance/Chat/Voice). Keep
`AccountSettingsView.swift`, `DataSettingsView.swift`, `ChatBackupDocument.swift` (drop `@concurrent`),
and the `SettingsPanel/ToggleRow/ValueRow/SubmitButton/NoticeBanner` components from the old
`SettingsView.swift` on flat `SurfaceCard`s.

| File | Purpose | Behaviour | Read |
|---|---|---|---|
| `Features/Settings/SettingsView.swift` (rewrite container) | container | iPhone: `NavigationStack` + `List` with five sections pushing pages; iPad: split (sections / page), `.presentationSizing(.form)`; large detent; `.sheet` glass; opens at `section`. | `web-auth-account-settings.md §6`, `audit-ios-shell-settings-design.md §2.2 F13` |
| `Features/Settings/AccountSettingsView.swift` (keep, fix) | account | Identity hero, plan card (`✦ مجاني بالكامل` copy; unmetered counters collapsed), change email/password (Google-account hint on 400), danger zone (delete with password), redeem code (admin/legacy), guest CTA; errors via `session.errorText`. | `web-auth-account-settings.md §6.1, §3.9, §10`, `audit-ios-shell-settings-design.md §2.2 F15, F23, F24` |
| `Features/Settings/AppearanceSettingsView.swift` | appearance | Theme grid (3-swatch tiles `[bg, surface, accent]`, ring, 0.25 s colour animation), text size, reading width, motion (`مخفّفة`), language (instant switch). Order: Theme → Text size → Width → Motion → Language. | `web-auth-account-settings.md §6.2`, `web-chat-ux.md §16`, `design-brief.md §6` |
| `Features/Settings/ChatSettingsView.swift` | chat | Default tier rows, response style (auto/plan), thinking (hidden on mini), web search, send-on-return, sharpen images. | `web-auth-account-settings.md §6.3`, `web-chat-ux.md §3.3–§6` |
| `Features/Settings/VoiceSettingsView.swift` | voice | Call voice (5, toast `صوت المكالمة: {name} — يُطبَّق على المكالمة القادمة`), barge-in, dialect (14), UI sounds [new, default off]. | `web-auth-account-settings.md §6.4`, `web-voice-call-mic.md §9`, `design-brief.md §5.2` |
| `Features/Settings/DataSettingsView.swift` (keep, fix) | data | Backup export (dated filename) / import (partial report), clear preferences, storage line, About (version via `/api/version` + build), What's new → announcements. | `web-auth-account-settings.md §6.5`, `audit-ios-shell-settings-design.md §2.2 F20–F23` |
| `Features/Settings/NotificationSettingsView.swift` | notifications | Authorization state, request button, explainer copy ("usually within minutes"), link to system settings when denied; sets `prefs.notificationsExplained`. Also used as `AppSheet.notificationExplainer`. | `audit-ios-shell-settings-design.md §2.1 F2, §2.2 F22` |
| `Features/Settings/MemorySettingsView.swift` | memory | List entries with per-row delete and clear all; members only (guests see the sign-up prompt). | `web-auth-account-settings.md §7`, `server-auth-session-account.md §5.5` |
| `Features/Settings/AnnouncementsSheet.swift` | bell feed | Pinned first, then newest; builtin launch post merged; marks seen on open; row → reader. | `web-auth-account-settings.md §8.2–8.3`, `server-misc.md §9` |
| `Features/Settings/AnnouncementReader.swift` | reader | Markdown body, inline `AVPlayer` for `video`, image, translate (members). | `web-auth-account-settings.md §8.4` |
| `Features/Settings/ChatBackupDocument.swift` (keep) | `FileDocument` | Drop `@concurrent`; per-chat size guard. | `audit-ios-shell-settings-design.md §2.2 F16, F21` |

Strings: `Strings.Settings` (`web-auth-account-settings.md §6–§8`, `web-chat-ux.md §14, §16`).
Rules: settings pages are flat opaque surfaces inside a glass sheet; every toggle writes
`PreferencesStore` directly (no local copies).
