# Plan — `Rendering/` (Batch 0 parsers + views; Cards may land in Batch 1 by the same owner)

Interfaces: `INTERFACES.md` → Rendering/. Design: `ARCHITECTURE.md §2.11`. No packages. KaTeX is
deferred; math is `MathText` Unicode.

| File | Batch | Purpose | Behaviour | Read |
|---|---|---|---|---|
| `Rendering/MarkdownBlocks.swift` | 0 | block splitter + block parser | Line scanner: ATX headings, paragraphs, `-`/`*`/`1.` lists (nested by indent), `>` quotes, pipe tables, fenced code (``` and ~~~; language tag), `---` rules, `$$` display math, ```` ```firas-* ```` / `plot` fences → `.fence`; while `streaming`, an unclosed fence/`$$` is returned as `.raw` text. `split` returns chunk strings so the renderer can cache by index. | `web-chat-ux.md §8.3–8.4`, `design-brief.md §7.6` |
| `Rendering/MarkdownInline.swift` | 0 | inline → `AttributedString` | `MathScanner.protect` → `AttributedString(markdown:options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))` (fallback: plain text on throw) → restore math spans as `MathText.unicode` in mono with `bgSubtle` background → link colour `accent`, inline code mono on `surfaceSunken`. | `design-brief.md §7.6` |
| `Rendering/MathScanner.swift` | 0 | the ONE math scanner | Protects `$$…$$`, `\[…\]`, `\(…\)`, `$…$` (no space after opening `$`, not followed by a digit-only currency pattern `$5 for tea`), PUA sentinels U+E000+; unbalanced → left as text. | skill `math-rendering` rules as summarised in `design-brief.md §7.6` |
| `Rendering/MathText.swift` | 0 | `texToUnicode` port | Superscripts/subscripts, Greek, `\frac{a}{b}` → `a⁄b`, roots, operators, `\text{}`; unknown macros kept verbatim. | `web-chat-ux.md §8.3` |
| `Rendering/CodeHighlighter.swift` | 0 | tokenizer | Keywords/strings/comments/numbers/tags/attrs for html/css/js/ts/json/py/swift/bash; colours from `CodeEditorTheme` values (web editor skin); linear scan, no catastrophic regex. | `web-code-ux.md §5.3` |
| `Rendering/MarkdownRenderer.swift` | 0 | cache + entry point | `NSCache<NSString, ParsedBlocks>` keyed by messageID (cost = char count); settled prefix reused when the chunk strings are unchanged; only the tail re-parses; `invalidate` on regenerate/version switch. | `audit-ios-chat.md §Critical C5` |
| `Rendering/MarkdownView.swift` | 0 | `[MDBlock]` → SwiftUI | Per-block `bidiIsland`; headings spacing per brief; lists with hanging indent respecting direction; quotes with accent bar; `.code` → `CodeBlockView`; `.table` → `TableBlockView`; `.mathDisplay` → centred LTR `MathText`; `.fence` → `onFence` result or code block; `.raw` → plain `Text`; 2 pt caret appended to the tail while streaming (opacity pulse). | `design-brief.md §7.6`, `web-chat-ux.md §8.3–8.4` |
| `Rendering/CodeBlockView.swift` | 0 | code block | LTR, mono 13, language label, copy button (`Strings.Common.copied` feedback), horizontal scroll, `collapsible` 14-line fade in cards, Preview button for html/svg → `CodeViewerSheet` via `onFence`-style callback. | `web-chat-ux.md §8.6`, `server-code-brainask.md §4.7` |
| `Rendering/TableBlockView.swift` | 0 | tables | `Grid` inside `ScrollView(.horizontal)`; header row bold on `surfaceSunken`; per-cell direction. | `design-brief.md §7.6` |
| `Rendering/QuickReplies.swift` | 1 | chips | Derive ≤ 4 chips from headings/bullets of the answer; hidden when a Start pill or ask panel is present. | `web-chat-ux.md §8.2` |
| `Rendering/Cards/CodeCard.swift` | 1 | `firas-code` | Title/name, language chip, `CodeBlockView(collapsible: true)`, actions Copy / Download (share sheet with temp file) / Preview / Continue (callback); wrap toggle. | `server-code-brainask.md §4.6–4.7`, `web-chat-ux.md §8.6` |
| `Rendering/Cards/FileCard.swift` | 1 | `firas-file` | Format icon + name + pages; open (share sheet) when the artifact is downloadable; progress stages for the streaming file loader. | `web-chat-ux.md §8.5`, `server-chat-jobs-chats.md §4.3` |
| `Rendering/Cards/LongFileCard.swift` | 1 | longfile progress | Stage copy (`يخطط هيكل الملف…` / `يكتب صفحات الملف…` / `يراجع ويجمّع الملف…` + `done / total`), percent bar, Stop (cancel allowed), then Open → `LongFileViewer`. | `server-chat-jobs-chats.md §4.2, §4.4` |
| `Rendering/Cards/ImageCard.swift` | 1 | `firas-image` | ≤ 420 pt, r20, `ImageCache` thumbnail, caption `note`, tap → `MediaViewer`, actions save/share/edit/regenerate (callbacks), skeleton while rendering. | `web-media-ux.md §3.5–3.8`, `design-brief.md §7.12` |
| `Rendering/Cards/VideoCard.swift` | 1 | `firas-video` | 16:9 `AVPlayer` from the local file (downloaded on demand), poster while loading, save/share. | `web-media-ux.md §5.2` |
| `Rendering/Cards/SongCard.swift` | 1 | `firas-music` | Full width, title/style line, `SongPlayer` scrubber (LTR digits), lyrics disclosure. | `web-media-ux.md §6.4` |
| `Rendering/Cards/AgentCard.swift` | 1 | `firas-agent` | Compact summary (title, status, steps done/total, files count) → tap opens the mission; live state fed by `AgentStore.missions`. | `web-agent-ux.md §6.3, §7` |
| `Rendering/Cards/SourcesCard.swift` | 1 | `firas-sources` | Numbered list `[Sn] title · page`, tap → passage reader callback. | `web-brain-ux.md §11.2` |

Rule: no `WKWebView` inside transcript rows; previews open in sheets. Every card is opaque
`SurfaceCard`; cards receive `palette`/`lang` explicitly (no environment reads inside `Rendering/`).
