# Plan — `Features/Code/` (Batch 1; 2 owners: Store+Launcher+Workspace+Navigator+Export · Editor+Preview+Console+AI+Diff; also `Localization/Strings+Code.swift`)

Interfaces: `INTERFACES.md` → `CodeLauncherView`, `CodeWorkspaceView`, `CodeStore`. Design:
`design-brief.md §7.9, §8`. Delete `CodeScreen.swift`, `CodeStrings.swift`, `Code.xcstrings`.

| File | Purpose | Behaviour | Read |
|---|---|---|---|
| `Features/Code/CodeLauncherView.swift` | home | Hero, create card (name, brief, attachments via `ChatAttachmentProcessor`), recent projects grid (2 / 3–4 columns) from `code.projects` + cache, delete with undo, "still building" accessory strip while a codebuild is live. | `web-code-ux.md §2`, `design-brief.md §7.9` |
| `Features/Code/CodeWorkspaceView.swift` | IDE shell | iPhone `TabView` Files/Code/Preview/AI (`tabBarMinimizeBehavior(.onScrollDown)` on 26 inside `#available`) + build strip (indeterminate + `srvKeep` copy, elapsed, no cancel); iPad three columns: `FileNavigator` 200 pt (collapsible), editor `1.1fr`, right pane `1fr` with segmented `المعاينة/الطرفية/المساعد`; diff review as `.inspector` on iPad, sheet on iPhone; `⌘S ⌘F ⌘/`. | `web-code-ux.md §3.7, §5.1`, `design-brief.md §7.9, §8` |
| `Features/Code/FileNavigator.swift` | file rail | Folders collapsed by path prefix, icons by extension, swipe rename/delete, `+` new file with path validation (120 chars), active file highlight. | `web-code-ux.md §5.2` |
| `Features/Code/CodeEditorView.swift` | editor | `UIViewRepresentable` `UITextView`: smart quotes/dashes off, `autocorrectionType .no`, `.asciiCapable` keyboard, mono 13, line-number gutter, active-line tint, `CodeHighlighter` applied on a 150 ms debounce, 900 ms commit debounce → `code.updateFile`; coordinator `@MainActor`; buffer separate from the store (audit C4). | `web-code-ux.md §5.3`, `audit-ios-agent-code.md §B.3 C3–C4` |
| `Features/Code/CodeEditorTheme.swift` | skins | Dark/light token hexes from the web editor CSS; consumed by `CodeHighlighter`. | `web-code-ux.md §5.3` |
| `Features/Code/PreviewWebView.swift` | preview | `WKWebView` with non-persistent data store, `WKURLSchemeHandler` for `firas-proj://` serving project files (css/js inlined per `projPreviewHtml` rules, module import map), console hook script injected after `<head>` → `WKScriptMessageHandler` (`__fcw`) → `ConsoleView`; navigation policy blocks external navigation (opens Safari); device presets; auto-reload on file commit (debounced). | `web-code-ux.md §5.4`, `server-code-brainask.md §2.9`, `audit-ios-agent-code.md §B.3 C7` |
| `Features/Code/ConsoleView.swift` | console | Level chips (log/warn/error), filter, clear, `أصلحه بالذكاء` → `CodeAIBar` with the error text. | `web-code-ux.md §5.5` |
| `Features/Code/CodeAIBar.swift` | command bar | Instruction field, `@` file mentions (autocomplete from paths), attachments, send → `code.askAI` → `DiffReviewSheet`; questions (no edit verbs) render as chat answers in the thread. | `web-code-ux.md §6.1–6.2, §6.4` |
| `Features/Code/CodeAskAI.swift` | routing helper | Builds the `cwAskAI` prompt (verbatim rules: file blocks contract, DELETE/RENAME lines, no placeholders), tier `max` for edits / `pro` for questions, `nomem:true`, continuation when the answer is cut. | `web-code-ux.md §6.2–6.3, §6.6` |
| `Features/Code/DiffReviewSheet.swift` | review | Per-file checkboxes with before/after (line diff), apply selected → `code.apply`, undo affordance. | `web-code-ux.md §6.5` |
| `Features/Code/CodeExport.swift` | export | ZIP via ZIPFoundation (off-main) → share sheet; share link via `ShareController`-style `createShare`; open preview in Safari from a temp file. | `web-code-ux.md §8–§9` |

Strings: `Strings.Code` — launcher, `srvKeep/srvFail/srvDone/srvReady`, IDE chrome, caps toasts
(`web-code-ux.md §2, §3.7, §5, §6.5`; `server-code-brainask.md §2.6–2.7`).
Rules: build = server job, no cancel; project files are PUT by the client, never by the worker;
`chatId` is `""` on the build request; caps enforced before every save.
