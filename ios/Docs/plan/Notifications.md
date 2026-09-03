# Plan — `Notifications/` (Batch 0, one owner)

Interfaces: `INTERFACES.md` → Jobs/ and Notifications/. Delete `PushRegistrationClient.swift`
(no APNs) and rewrite `NotificationCoordinator.swift` as `NotificationManager.swift` (keep the
`NotificationDestination`-style nested-key decoding inside `NotificationRouter`).

| File | Purpose | Behaviour | Read |
|---|---|---|---|
| `Notifications/NotificationManager.swift` | permission + local posts | `requestIfNeeded` (`.alert, .sound`); called by `JobManager` after the first accepted job and only after `prefs.notificationsExplained` (the explainer sheet sets it). `postJobTerminal`: title/body from `Strings.Notify` by `pointer.kind`/`product`/`mediaKind` and success/failure in `lang`; `sound = UNNotificationSound(named: "FirasComplete.wav")`; `categoryIdentifier = "FIRAS_JOB_COMPLETE"`; `threadIdentifier = "firas-<product>-<chatId|jobId>"` ≤ 64; `userInfo` from `NotificationRouter.userInfo`; request id = job id (dedupe); trigger nil (immediate). `postCallEnded`: body = reason string. `clearDelivered` removes the delivered notification when the user opens the result. | `server-auth-session-account.md §6.5–6.6`, `audit-ios-shell-settings-design.md §2.1 F1–F2, §2.2 F17–F18` |
| `Notifications/NotificationRouter.swift` | `userInfo` ↔ `AppRoute` | Nested `firas.{type,product,jobId,phase,chatId,mediaKind}` (+ flat `firas_*` fallbacks); product `ai` → `.chat(chatId)` (jobId when no chatId → open the product's latest), `agent` → `.agent(chatId)`, `code` → `.code(chatId)`, `brain` → `.brain`, media kinds → `.studio(creationID: jobId)`. | `server-auth-session-account.md §6.5` |
| `Notifications/CompletionCue.swift` | pre-reveal cue | `prepare()` = `UIImpactFeedbackGenerator(.soft).prepare()`. `fire`: no-op when key already consumed, app not active, or `callActive`; success → impact 0.32, sleep 160 ms, impact 0.48, sleep 140 ms; failure → `.error` notification haptic; Reduce Motion → single `.success`; `FirasSound.play(.done)` on the same frame as the first pulse; consumed-key history capped at 64. Total ≤ 320 ms — never the Codex 3 s. | `design-brief.md §5.3`, `audit-ios-shell-settings-design.md §2.1 F4` |
| `Notifications/FirasAppDelegate.swift` (keep, trim) | delegate | Drop APNs callbacks. `didFinishLaunching`: `BackgroundRefresh.register` (handler forwards to `lifecycle?.env.jobs.refreshOnce(budgetSeconds: 20)`), `UNUserNotificationCenter.current().delegate = self`. `willPresent` → `.banner, .sound` unless the target conversation is on screen (ask `lifecycle`); `didReceive` → `lifecycle?.handleNotificationTap(userInfo:)`; cold-start `launchOptions` remote/local notification payload forwarded the same way. Delegate methods hop with `Task { @MainActor in }`. | `audit-ios-shell-settings-design.md §1 Notifications, §2.1 F2` |

Rule: copy strings live in `Strings.Notify` and are identical to the server's APNs table so a future
APNs path needs no client change.
