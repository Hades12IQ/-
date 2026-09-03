# Plan — `Features/Auth/` (Batch 1, one owner; also `Localization/Strings+Auth.swift`)

Interfaces: `INTERFACES.md` → `AuthView`, `LandingView`, `ConsentView`, `SignUpPromptSheet`.
Design: `design-brief.md §7.17`. Keep `AuthView.swift` shell (focus order, RTL email field, iPad
form sizing).

| File | Purpose | Behaviour | Read |
|---|---|---|---|
| `Features/Auth/ConsentView.swift` | first run | Verbatim consent copy, checkbox never pre-ticked, `متابعة` prominent; sets `prefs.consentAccepted`. | `web-chat-ux.md §1.1`, `web-auth-account-settings.md §1` |
| `Features/Auth/LandingView.swift` | logged-out hero | Guest CTA (`session.continueAsGuest`), sign-in link (`router.cover = .auth(.login)`), seven feature cards, no counters; glass only on the CTA bar. | `web-chat-ux.md §1.3–1.4`, `web-auth-account-settings.md §2` |
| `Features/Auth/AuthView.swift` (keep shell, redesign fields) | login / signup | Email/password/name, Google button (`GoogleOAuthProvider`), forgot link, terms link, mode switch; fields `.glassEffect(.regular.interactive())` on 26 via `firasGlass(.sheet)` fallback; errors from `session.errorText` announced to VoiceOver; per-operation busy states; signup → `VerificationCard`. | `audit-ios-networking-auth.md §B2 F8–F10, §C`, `web-auth-account-settings.md §3` |
| `Features/Auth/VerificationCard.swift` | verify | 3 s `.task(id:)` loop calling `session.pollVerification` while visible; resend with 30 s countdown; expired/gone copy; stops on background. | `server-auth-session-account.md §4.2–4.4`, `web-auth-account-settings.md §3.5` |
| `Features/Auth/ForgotPasswordSheet.swift` | forgot / reset | forgot → "check inbox"; reset form (from `?reset=&uid=` route) → `session.resetPassword`. | `server-auth-session-account.md §4.13–4.14`, `web-auth-account-settings.md §3.6–3.7` |
| `Features/Auth/SignUpPromptSheet.swift` | upsell | Feature-keyed copy (image vs generic), CTA → save guest state and `router.cover = .auth(.signup)`, `لاحقًا` dismiss. | `web-auth-account-settings.md §5.4` |

Strings: `Strings.Auth` (`web-auth-account-settings.md §2, §3.1, §5.4, §5.6`).
Rules: never show a server sentence verbatim; a 500 on login means "wrong credentials or Google
account"; Google-account limitation hints on change-* 400s.
