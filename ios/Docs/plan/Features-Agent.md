# Plan — `Features/Agent/` (Batch 1, one owner; also owns `Stores/AgentStore.swift` and `Localization/Strings+Agent.swift`)

Interfaces: `INTERFACES.md` → `AgentScreen`, `AgentStore`. Design: `design-brief.md §7.8`, spec
`web-agent-ux.md §15`. Delete `AgentStrings.swift`, `Agent.xcstrings`.

| File | Purpose | Behaviour | Read |
|---|---|---|---|
| `Features/Agent/AgentScreen.swift` (keep shell, rewrite body) | the Agent product | `ChatScreen`-like shell: welcome (Agent variant + templates strip), transcript where the latest assistant turn is a `MissionCard`, composer **always visible** (follow-ups allowed after terminal; while running the send is queued with a toast), credits chip in the toolbar → `CreditsSheet`, guest → landing copy + sign-up CTA, blocked/credits states rendered by the card. Attachments allowed per §11. | `web-agent-ux.md §1, §2, §11, §15`, `audit-ios-agent-code.md §B.2` |
| `Features/Agent/MissionCard.swift` | the living card | Header: mark · `Firas Agent` · status pill (phase → `queued/يعمل/اكتمل/فشل/متوقف`) · elapsed `m:ss` LTR from `surface.startedAt`; speech line (last `says`, animated in); plan disclosure `خطة التنفيذ · done/total` with step rows; `MissionTimeline`; `MissionFiles`; `النتيجة` (`MarkdownView` of `final`; `presentation == conversation` → plain bubble, no card); footer: `▶ استئناف المهمة` (only `fail`/stopped with unfinished steps, not blocked), `فتح المهمة الجارية ←` (blocked with `activeChatId`), `⬇ تصدير Markdown`; blocked/credits states show the verbatim sentence + credits chip; never shorten on an older snapshot; `Haptics.toolStep()` when a step completes while visible. | `web-agent-ux.md §6.2, §7–§9, §12, §14`, `server-agent.md §6, §11` |
| `Features/Agent/MissionTimeline.swift` | events | Rows from `surface.events` (kind icon: status/message/tool, `Firas Browser` label, status word, arg, `url` → open source in Safari), sources group (unique urls), `live[]` in a disclosure "سجل النشاط"; diff by `id` for insert animation. | `server-agent.md §6.2–6.6` |
| `Features/Agent/MissionFiles.swift` | files | Image grid (fetch with cookie via `agent.artifactURL(download: false)` into `ImageCache`) + document list; tap → `ArtifactViewer`; share via `download: true` temp file. | `server-agent.md §6.5, §12.4`, `web-agent-ux.md §4.6` |
| `Features/Agent/ArtifactViewer.swift` | viewer | `QLPreviewController` wrapper for pdf/docx/pptx/xlsx/images; sandboxed `WKWebView` for html/md/json (`loadFileURL` with read access to the temp dir only); share button. | `web-agent-ux.md §15 (files)` |
| `Features/Agent/CreditsSheet.swift` | credits | `remaining/allowance`, `held`, `resetAt` (Arabic-Indic), `configured == false` → hidden feature copy. | `web-agent-ux.md §14`, `server-agent.md §10.1` |

Strings: `Strings.Agent` — statuses, blocked/credits sentences and the failure copy table verbatim
(`web-agent-ux.md §9`, `server-agent.md §11.2`). Error codes map per `server-agent.md §5.5`.
Rules: the mission runs on the server; the screen is a viewer; no Stop button for missions.
