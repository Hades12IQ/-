# Plan — `Core/` (Batch 0, one owner; Foundation only, everything `Sendable`)

Interfaces: `INTERFACES.md` → Core/.

| File | Purpose | Behaviour to get right | Read |
|---|---|---|---|
| `Core/DiskStore.swift` | `actor DiskStore` JSON files under `Application Support/FirasAI/` | Atomic write (`Data.write(options: .atomic)`), `.completeFileProtection`, `isExcludedFromBackup = true` on the root folder; `read` returns nil (never throws) and logs decode failures; paths are relative and created on demand; encoder/decoder without date strategies. | `audit-ios-chat.md §Major M14`, `audit-ios-brain-media.md §B.3` |
| `Core/NetworkMonitor.swift` | `NWPathMonitor` → `isOnline` + `AsyncStream<Bool>` | Start on a background queue, hop to main to publish; initial value from the first path update (assume online until told otherwise). | `audit-ios-networking-auth.md §B3` |
| `Core/BackgroundExecutor.swift` | `beginBackgroundTask` scope | `hold(name:)` returns a `BackgroundHold` whose `end()` is idempotent; expiration handler ends the task itself; never leaks. | `audit-ios-shell-settings-design.md §2.1 F2` |
| `Core/Deadline.swift` | `withDeadline`, `Backoff`, `DeadlineError` | Task-group race between body and `Task.sleep`; cancels the loser; the only permitted "never hang" pattern. `Backoff(initial:max:factor:)` with jitter ≤ 20 %. | `audit-ios-voice.md §B` |
| `Core/IDs.swift` | cid / local id / sanitisers | `cid()` 16 chars `[A-Za-z0-9_-]`; `sanitizedCid` = server regex `[^A-Za-z0-9_-]` removed, ≤ 64; `sanitizedMediaKey` = `[^a-f0-9]` removed, ≤ 64; local conversation id `ios_` + UUID lowercase. | `server-chat-jobs-chats.md §1.2 cid`, `server-media.md §0.6` |
| `Core/BidiText.swift` | first-strong direction | Scan scalars: Arabic/Hebrew/Syriac blocks → `.rightToLeft`; Latin/Greek/Cyrillic letters → `.leftToRight`; digits/punctuation skipped; nil when nothing strong. `isArabicDominant` = more Arabic letters than Latin. | `design-brief.md §4.3` |
| `Core/ArabicText.swift` | normalisation, numerals, timer, plurals | `normalize`: strip U+064B–U+0652 and U+0670, tatweel U+0640, fold `أإآٱ→ا`, `ى→ي`, `ة→ه`, trim, lowercase Latin. `count` uses `Locale(identifier: "ar-IQ-u-nu-arab")` NumberFormatter for `.arabic`, plain for `.english`. `timer` = `m:ss` Latin digits, wrapped LTR by callers. `ArabicPlurals.count` picks zero/one/two/few (3–10)/many (11–99)/other (100+) for `.arabic`; one/other for `.english`; result via `fmt` with `%ld`. | `web-plan-mode.md §7.6`, `design-brief.md §4.2` |
| `Core/Log.swift` | `os.Logger` categories | Redact `firas_session`, `firas_guest`, `ek_`, `auth_tokens/` values before logging. | — |

No SwiftUI import except `LayoutDirection` in `BidiText` (import SwiftUI there only).
