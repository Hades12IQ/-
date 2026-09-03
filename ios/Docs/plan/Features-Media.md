# Plan — `Features/Media/` (Batch 1, one owner; also `Stores/MediaStore.swift`, `Localization/Strings+Media.swift`)

Interfaces: `INTERFACES.md` → `MediaStudioScreen`, `MediaStore`, `MediaAssetRepository`. Design:
`design-brief.md §7.11–7.12, §8`. Delete `MediaStrings.swift`, `Media.xcstrings`; the old
`MediaStudioScreen.swift` is rewritten in place (keep `MediaKindPicker`, `AspectPresetButton`,
`durationPicker` pieces).

| File | Purpose | Behaviour | Read |
|---|---|---|---|
| `Features/Media/MediaStudioScreen.swift` (rewrite) | fifth product `الاستوديو` | `TabView` `المكتبة/إنشاء` on iPhone (`tabBarMinimizeBehavior` on 26 inside `#available`); iPad: grid + create form as `.inspector`; "still rendering" strip while media jobs are live; guests see the upsell card. | `web-media-ux.md §12.2`, `design-brief.md §7.11, §8` |
| `Features/Media/MediaLibraryGrid.swift` | library | 3 / 5 columns from `media.creations` (all conversations), sticky conversation headers, kind chips filter, skeleton tiles for running jobs, tap → `router.cover = .mediaViewer`, context menu open-in-chat/save/share/edit/regenerate/delete. | `web-media-ux.md §7, §12.2` |
| `Features/Media/MediaCreateForm.swift` | create | Kind picker image/edit/video/song; prompt; image: shape (square/tall/wide); edit: source picker (library or Photos); video: first-frame photo picker + duration 2–30 s (default from `quota.seconds`); song: "use my lyrics" toggle + genre chip; target conversation picker (new by default); quota panel (`imageQuota` used/limit/remaining; video/music window rule + `freesInMin` after a 429). No count control. | `web-media-ux.md §12.2, §3.1, §5.1, §6.1–6.3`, `server-media.md §1.5, §2.4` |
| `Features/Media/MediaViewer.swift` | full-screen | Pinch-zoom image, `AVPlayer` for video (local file), song player, caption `note`, actions save (Photos add-only permission) / share / open in chat / edit / regenerate; swipe between creations. | `web-media-ux.md §3.8`, `design-brief.md §7.11` |
| `Features/Media/MediaPromptPipeline.swift` | prompt shaping | Image: English rewrite via `POST /api/chat {nomem:true}` with the verbatim rewrite prompt + shape inference (server clamps 1280); video: rewrite + first frame JPEG ≤ 2048 px; music: `musicStyleFor` regex table (English tags), lyric author call unless user lyrics, `STYLE:` line composition; regenerate = changed input. | `web-media-ux.md §3.1, §5.1, §6.1–6.3`, `server-media.md §1.6, §3.4` |
| `Features/Media/SongPlayer.swift` | audio | Single `AVPlayer` under `AudioSessionArbiter.acquire(.playback)`, scrubber, LTR elapsed/total, pauses `TTSPlayer`, stops when a call starts. | `web-media-ux.md §6.4`, `design-brief.md §5.2` |
| `Features/Media/MediaAssetRepository.swift` | files | `media/<key>.<ext>` under Application Support (excluded from backup), relative filenames only, trim to newest 200, `.playback`-ready URLs. | `audit-ios-brain-media.md §B.3` |

Strings: `Strings.Media` — loader words, outcome/error sentences per kind, upsell texts
(`web-media-ux.md §3.5, §3.7, §5.2, §6.4, §11`; `server-media.md §1.8, §2.7, §3.6, §5`).
Rules: every creation lands in a conversation as a fence (that is what keeps gallery/share/reattach/
notifications working); never present a cancel for media; job ids are cache keys — never invent ids.
