# Firas AI — native iOS / iPadOS design brief

Scope: the look, structure, motion, type, haptics and per-screen behaviour of the native rewrite. The
north star is the polish and structure of Anthropic's Claude app on iPhone/iPad, rendered in Apple's
Liquid Glass (iOS 26) with a **more transparent** glass than the system default, carrying the six Firas
web themes natively. Every product fact below is cross-checked against the web code or the sibling
reports in `ios/Docs/` (which carry the `app.js:` / `server.mjs:` line citations); every design
decision is opinionated on purpose so an engineer can build without re-deciding.

Sources used (worktree root `D:\Programming\Projects\FirasAI\.claude\worktrees\firasai-ios-app-development-64ca7e`):
`styles.css:11-391` (theme tokens), `styles.css:6420-6620` (chat column / bubble tokens),
`styles.css:12500-12720` (UI 2.0 material notes), `styles.css:7300-7330` (call background),
`app.js:2464-2483` (`THEMES`), `ios/Docs/web-chat-ux.md`, `web-plan-mode.md`, `web-voice-call-mic.md`,
`web-agent-ux.md`, `web-code-ux.md`, `web-brain-ux.md`, `web-media-ux.md`, the existing Swift in
`ios/FirasAI/DesignSystem/*.swift` and `Features/Shell/FirasAppShell.swift`, and the repo playbooks
`.claude/skills/apple-design`, `reduced-motion-and-comfort`, `rtl-layout-mechanics`,
`arabic-typography-web`, `empty-states`, `streaming-ui-patterns`.

Arabic strings are verbatim from the web STR tables (as cited in the reports). Where the web has no
equivalent (Media Studio, iPad shortcuts) the brief says so and proposes copy marked **[new]**.

---

## 0. Ten decisions that shape everything

1. **Chat-first, one product at a time.** The root is the Firas AI chat with a drawer/sidebar; Agent,
   Code, Brain and Media Studio are *destinations reached from the sidebar product switcher*, not tabs
   competing for the home screen. This is the Claude app shape (one chat, one drawer) and it matches
   the web's `state.product` switcher (`web-chat-ux.md §2`). No bottom tab bar on iPhone for the four
   products; a `TabView` is used **inside** Code (Files / Code / Preview / AI) and Media Studio only.
2. **Shell is fixed LTR; content islands are bidirectional.** Exactly like the web
   (`applyShellLang` forces `html.dir="ltr"`, `web-chat-ux.md` conventions). The sidebar is on the
   left in Arabic and English. Every message body, composer field, chat title and card text decides its
   own direction from its first strong character. The existing shell already does
   `.environment(\.layoutDirection, .leftToRight)` at the root (`FirasAppShell.swift:60`) — keep it.
3. **Glass is the chrome, never the page.** Glass lives on the composer, the sidebar, toolbars, sheets,
   pickers, the orb controls and floating chips. Message prose sits on the theme ground with no card
   behind it (UI 2.0's "a document, not a messenger", `styles.css:12620-12660`). The one exception is the
   user bubble, which is a *solid* accent-deep fill — glass on a bubble reads as a button.
4. **Transparency tier: `.clear` glass with a thin tint, not `.regular`.** The owner wants more
   see-through than the system default. Recipe in §2.4; it is one `FirasGlass` enum with three levels
   so nobody hand-tunes opacities per view.
5. **Six themes, one palette struct.** `FirasTheme` already carries the exact hex tokens from
   `styles.css` (verified in §6). Add the glass-tint / overlay / stroke derivations to `FirasPalette`
   rather than sprinkling `.opacity(0.05)` through views.
6. **Default theme is dark, default language is Arabic, default tier is Pro** (web:
   `firas_ai_theme` → `dark`, boot language `ar` unless `navigator.language` starts with `en`,
   `CONFIG.DEFAULT_TIER = "pro"`). The existing `PreferencesStore` already defaults to these.
7. **Motion is critically damped by default.** `.spring(response: 0.35, dampingFraction: 0.85)` is the
   house spring; overshoot only after a real gesture (drawer flick, sheet throw). Reduce Motion and the
   in-app "مخفّفة" toggle are one switch (`PreferencesStore.motionEnabled && !reduceMotion`).
8. **Haptics fire before the reveal, not after.** Send = light impact on the frame the bubble appears;
   completion = the soft double pulse already in `FirasCompletionCue`, but with the reveal delay cut
   from 3 s to ≤ 180 ms (§5.3 — the current 3 s `Task.sleep` is a defect for this brief's purposes).
9. **Every long job survives leaving the screen and the app.** Agent, Code builds, image/video/song,
   long chat turns are server jobs with pointers; the UI shows a "still working" dot in the sidebar and a
   `tabViewBottomAccessory`-style strip in Code/Media. Never present a cancel for media (server has none).
10. **Arabic type is SF Arabic through the system font, never a custom family, never tracked.** Latin
    display may use SF Pro with tight tracking; Arabic never gets `.kerning`/`.tracking` (§4).

---

## 1. Information architecture — Claude app anatomy mapped to Firas

### 1.1 The Claude iPhone app, as the structural reference

What to reproduce (structure, not branding):

| Claude iPhone element | Behaviour to copy | Firas mapping |
|---|---|---|
| Chat-first home: greeting line, empty canvas, composer pinned at bottom | Opening the app lands you in a fresh chat with a greeting, no dashboard | Welcome (§7.1): halo + mark + `صباح الخير يا {first}` (web `greetingText`), composer at bottom |
| Top-left menu button → drawer slides in from the leading edge over the chat, dimming it | Drawer = New chat, search, recents; account row at the bottom | Sidebar (§7.2) with product switcher on top, `محادثة جديدة`, `ابحث في المحادثات`, grouped history, usage row, account pill |
| Model name as a pill in the title position, tap → picker sheet | The header title *is* the model picker | Tier pill `فِراس برو ⌄` in the principal toolbar slot → Model/Tier sheet (§7.4); Agent shows `Firas Agent` (locked to Max), Brain/Code show their own titles |
| Composer: `+` (Camera / Photos / Files, tools), text field, mic, send | `+` opens an action sheet; send morphs to stop while streaming | Composer (§7.3) + Add sheet (§7.3.2); mic = dictation; phone = call (Firas AI only) |
| Streaming answer with a completion haptic, markdown, code blocks with copy | Text streams token-by-token; a haptic lands right before the final paint | §7.5 message rendering; `FirasCompletionCue` |
| Long-press a message → context menu (copy, retry, select text, share) | Actions are hidden behind a long-press, a small always-visible row for the last answer | Message actions (§7.7): long-press menu + a compact 4-button row under the latest answer |
| Artifacts open in a full-screen sheet with Preview / Code segmented control | Code and HTML deliverables leave the thread | `firas-code` card → full-screen Code viewer with `معاينة` / `الكود`; `firas-project` → Code IDE |
| Voice mode: full-screen, morphing orb, mute + end, captions | Dedicated screen, not an inline widget | Call screen (§7.13) — orb 176 pt, phases `connecting/listening/thinking/speaking` |
| Settings via the account avatar in the drawer | Account → settings list | Settings tree (§7.15) with tabs `الحساب / المظهر / المحادثة / الصوت / البيانات` |

### 1.2 The Claude iPad app, as the structural reference

- `NavigationSplitView` with a persistent sidebar in regular width; the conversation is a wide reading
  column centred with a max measure; the composer is centred to the same measure, not stretched.
- Keyboard: `⌘N` new chat, `⌘K`/`⌘F` search, `⌘↩` send, `⇧⌘,` settings, `esc` stop/close. Pointer:
  hover lifts list rows and message action buttons; trackpad scroll keeps the reading position.
- Full addendum in §8, including 3-column layouts for Code and Brain.

### 1.3 Firas surfaces and where each lives

| Surface | Reached from | Root container (iPhone) | Root container (iPad) |
|---|---|---|---|
| Firas AI chat | default | `NavigationStack` detail + overlay drawer | split-view detail |
| Firas Agent | sidebar product switcher | same chat shell, message cells grow into mission cards | same, wide card |
| Firas Code | sidebar product switcher | launcher → workspace with 4-tab `TabView` (Files / Code / Preview / AI) | 3 columns: files 200 pt / editor 1.1fr / preview-console-chat 1fr |
| Firas Brain | sidebar product switcher | library (sources rail as a sheet) + reader/ask | 3 columns: sources / ask thread / passage reader |
| Media Studio **[new native surface]** | sidebar product switcher (fifth entry, `الاستوديو` **[new]**) | `TabView`: `المكتبة` / `إنشاء` **[new]** | split: library grid / create form |
| Call | phone button in the Firas AI composer only | `fullScreenCover` | `fullScreenCover` |
| Dictation | mic button (Firas AI composer, Brain ask box, Agent composer) | overlay that replaces the composer's action row | same |
| Settings | account pill → gear; or the avatar | `.sheet` (large detent) | `.sheet` sized 720×860 max |
| Announcements | bell in the sidebar header / Settings → Data → About | `.sheet` | popover from the bell |
| Onboarding / Auth | first run / logged out | `fullScreenCover` sequence | centred card 520 pt |

---

## 2. Liquid Glass cheat-sheet (SwiftUI, iOS 26) with iOS 18 fallbacks

Everything in this section that is iOS 26-only must be wrapped in `if #available(iOS 26, *)`. Deployment
target stays iOS 18 (per `ios/` project); write each glass surface once as a `ViewModifier` with both
branches so screens never branch themselves.

### 2.1 Exact signatures (iOS 26)

```swift
// Glass material on any view, clipped to a shape. Default shape is Capsule.
func glassEffect(_ glass: Glass = .regular,
                 in shape: some Shape = Capsule(),
                 isEnabled: Bool = true) -> some View

struct Glass {
  static var regular: Glass   // adaptive: lightens/darkens against content, blurs, refracts edges
  static var clear: Glass     // much more transparent; for media-rich backgrounds; needs a dimming layer for legibility
  static var identity: Glass  // no glass — use to *remove* the effect conditionally without changing view identity
  func tint(_ color: Color?) -> Glass          // colour wash; pass low-alpha colours (0.04–0.12)
  func interactive(_ isEnabled: Bool = true) -> Glass  // press scale + shimmer + haptic-like bounce on touch
}

// Groups glass shapes so they can merge/morph; spacing = distance at which shapes start blending.
struct GlassEffectContainer<Content: View>: View {
  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content)
}
func glassEffectID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View
func glassEffectUnion(id: some Hashable & Sendable, namespace: Namespace.ID) -> some View
func glassEffectTransition(_ transition: GlassEffectTransition) -> some View   // .matchedGeometry, .identity

// Buttons
.buttonStyle(.glass)            // GlassButtonStyle
.buttonStyle(.glassProminent)   // GlassProminentButtonStyle — filled with tint (accent) — the "send" look
.buttonBorderShape(.capsule)    // or .circle / .roundedRectangle(radius:)

// Tab bar
func tabBarMinimizeBehavior(_ behavior: TabBarMinimizeBehavior) -> some View  // .automatic, .never, .onScrollDown, .onScrollUp
Tab(role: .search) { ... }      // iOS 18 API; on iOS 26 it renders as the separate glass search pill
func tabViewBottomAccessory<Content: View>(@ViewBuilder content: () -> Content) -> some View   // "now playing" strip above the bar
@Environment(\.tabViewBottomAccessoryPlacement) var placement  // .inline (beside minimized bar) / .expanded

// Toolbars — items are glass automatically on iOS 26
ToolbarSpacer(.fixed)  /  ToolbarSpacer(.flexible)
ToolbarItem(placement: .principal) { ... }         // the model pill lives here
ToolbarItem(...) { ... }.sharedBackgroundVisibility(.hidden)   // detach one item from the group's glass slab
func navigationSubtitle(_ subtitle: Text) -> some View          // second line under the title (new on iOS 26 for iOS)

// Scroll edges
func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View  // .automatic, .soft, .hard
func scrollEdgeEffectHidden(_ hidden: Bool = true, for edges: Edge.Set = .all) -> some View

// Extending content under glass chrome / sidebars
func backgroundExtensionEffect() -> some View      // mirrors + blurs the view's edges into the safe area / behind the sidebar

// Bars that participate in scroll-edge effects (unlike safeAreaInset)
func safeAreaBar<V: View>(edge: VerticalEdge, alignment: HorizontalAlignment = .center,
                          spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View

// Concentric corners (a control inside a rounded container keeps a matching inner radius)
.rect(corners: .concentric, isUniform: true)       // RoundedRectangle-like shape that follows the container corner
ConcentricRectangle(corners: .concentric, isUniform: true)

// Sheets — glass sheet background is automatic on iOS 26. Setting a solid presentationBackground turns it OFF.
.presentationBackground(_ style: some ShapeStyle)  // iOS 16.4+; use ONLY on iOS 18 fallback
.presentationDetents([.medium, .large]); .presentationCornerRadius(_:)   // iOS 16.4+
```

Also available and used below (iOS 16–18 era, safe everywhere): `NavigationSplitView`,
`.navigationSplitViewColumnWidth(min:ideal:max:)`, `.toolbarBackground(.hidden, for:)`,
`.containerRelativeFrame`, `.scrollTargetBehavior(.viewAligned)`, `.contentTransition(.numericText())`,
`.sensoryFeedback`, `Material` (`.ultraThinMaterial … .ultraThickMaterial`), `ShapeStyle.opacity(_:)`
(iOS 17), `.hoverEffect(.lift)`, `.keyboardShortcut`.

### 2.2 Which modifiers exist only on iOS 26

iOS 26-only: `glassEffect`, `Glass`, `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`,
`glassEffectTransition`, `.glass` / `.glassProminent` button styles, `tabBarMinimizeBehavior`,
`tabViewBottomAccessory`, `ToolbarSpacer`, `sharedBackgroundVisibility`, `navigationSubtitle` (on
iOS), `scrollEdgeEffectStyle`, `scrollEdgeEffectHidden`, `backgroundExtensionEffect`, `safeAreaBar`,
`.concentric` corners, `ConcentricRectangle`.

Available on iOS 18 already: `Tab(role: .search)`, `NavigationSplitView`, `presentationBackground`,
`sensoryFeedback`, `Material`, `ShapeStyle.opacity`.

Gate pattern (do this once, in `DesignSystem/FirasGlass.swift`):

```swift
struct FirasGlassModifier: ViewModifier {
  let level: FirasGlass.Level; let shape: AnyShape; let palette: FirasPalette
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  func body(content: Content) -> some View {
    if #available(iOS 26, *), !reduceTransparency {
      content.glassEffect(level.glass(palette), in: shape)
             .overlay(shape.stroke(palette.glassStroke, lineWidth: 0.5))   // see §2.4 for why
    } else {
      content.background(level.fallback(palette, reduceTransparency), in: shape)
             .overlay(shape.stroke(palette.glassStroke, lineWidth: 1))
    }
  }
}
```

Note: iOS 26 already renders glass more opaque when *Reduce Transparency* is on; the explicit check
above is still needed so the fallback branch (solid `surface`) is used for the custom overlays, which
the system does not know about.

### 2.3 Three glass levels (the only three the app uses)

| Level | Where | iOS 26 | iOS 18 fallback |
|---|---|---|---|
| `.chrome` | navigation bar, toolbars, tab bar, system search pill | leave to the system (no modifier) | `.toolbarBackground(.ultraThinMaterial, for: .navigationBar)` |
| `.floating` | composer, sidebar drawer, dictation bar, floating chips (scroll-to-bottom, "still working", tier pill), orb controls | `Glass.clear.tint(palette.glassTint).interactive()` + 0.5 pt stroke `palette.glassStroke` + overlay `palette.glassWash` | `.ultraThinMaterial.opacity(0.62)` over `palette.surface.opacity(0.28)` + 1 pt stroke + wash |
| `.sheet` | settings, model picker, add sheet, passage reader, announcements, plan card | `Glass.regular.tint(palette.glassTint)` (system sheet glass, tint only) | `.ultraThinMaterial` + `palette.surface.opacity(0.55)` |

The user bubble, cards inside prose (image/video/song/agent/code cards), code blocks and the Code editor
are **not** glass — they are `palette.surface` / `palette.surfaceSunken` solids so text contrast is
measurable (the web's contrast audit comments in `styles.css:20-33` are the reason; AA on glass cannot
be guaranteed over moving content).

### 2.4 Making glass *more* transparent than the default (the owner's ask)

`Glass.regular` on a dark theme reads as a frosted grey slab; the owner wants the conversation to stay
visible through the composer and the drawer. The recipe, tuned per theme family:

1. **Use `Glass.clear`, not `.regular`, for `.floating`.** Clear removes most of the adaptive backing so
   the blurred content shows through. Apple's guidance: clear needs a *dimming layer* for legibility —
   we supply it as a very thin wash rather than a full scrim.
2. **Tint at 0.04–0.06 alpha, never higher.** `palette.glassTint = accent.opacity(0.05)` on dark
   families, `accent.opacity(0.035)` on light. A 0.12+ tint turns the composer into a coloured pill.
3. **Wash overlay (`palette.glassWash`)** on top of the glass shape, `.blendMode(.plusLighter)` on dark
   and `.normal` on light: white at 0.04 (dark, graphite, midnight, amber), white at **0.06 on
   `black`** (pure black behind clear glass otherwise shows *nothing*, and the composer vanishes), black
   at 0.025 on light.
4. **Hairline (`palette.glassStroke`)**: white 0.10 on dark families (0.14 on black), black 0.08 on
   light — 0.5 pt on iOS 26 (the system already draws a refractive rim; ours is only for contrast
   against the ground), 1 pt on iOS 18.
5. **Text on floating glass** is `textPrimary` at full alpha, weight `.medium` for labels ≤ 13 pt (the
   web's vibrancy note: heavier, never grey, on translucent surfaces).
6. **On iOS 18** the equivalent transparency is `.ultraThinMaterial.opacity(0.62)` (Material is a
   `ShapeStyle`; `.opacity` is iOS 17+) layered over `surface.opacity(0.28)`. Do not use
   `.thinMaterial`/`.regularMaterial` — both are visibly heavier than what the owner asked for.
7. **What sits behind the glass matters more than the glass.** `FirasBackground` (existing) paints
   ground + an accent radial at 0.16 (0.08 on black) + a subtle bottom darkening. Keep it; add the web's
   grain only if it can be a static 128 px tile at `--grain-opacity` (0.03 light / 0.042 dark / 0 black /
   0.035 midnight / 0.03 graphite / 0.05 amber) — never animate it.
8. **Reduce Transparency**: fall to solid `surface` with the stroke; keep corner radii and shadows so
   layout does not change.

Verified against the existing code: `GlassSurface.swift` uses `.regular.tint(accent.opacity(0.08))` —
change it to the level enum above (`.floating` = clear/0.05 wash, `.sheet` = regular). The composer
(`ChatComposer.swift:20`) uses `tintStrength: 0.045` — that number survives as the floating tint.

### 2.5 Shapes, radii and elevation

- Composer: `RoundedRectangle(cornerRadius: 24, style: .continuous)` (existing 25 → 24 to match the
  Claude composer's proportions at 44 pt row height). Chips / pills: `Capsule()`. Sheets: system
  (`.presentationCornerRadius(34)` on iOS 18 only — iOS 26 sheets already use the device corner).
- Cards inside prose keep the web's *machined* radii: 9 pt (`--radius-xl`), 7 pt for nested elements.
  The user bubble is 20 pt (`--soft-radius`) with the bottom-trailing corner at 7 pt.
- Shadows: floating glass gets `.shadow(color: .black.opacity(0.18), radius: 24, y: 8)` on dark, 0.08 on
  light; sheets none (system); cards `--shadow-sm`-equivalent `.shadow(color: .black.opacity(0.05), radius: 3, y: 1)`.
- Never stack two `.floating` surfaces (a glass chip on a glass composer): put chips *inside* the
  composer's `GlassEffectContainer(spacing: 12)` so they merge into one slab instead.

---

## 3. Motion

### 3.1 House springs (SwiftUI)

| Use | Animation | Notes |
|---|---|---|
| Default state change (toggle, chip select, badge) | `.spring(response: 0.35, dampingFraction: 0.85)` | the house spring; assign once as `FirasMotion.standard` |
| Sheet / drawer programmatic open | `.spring(response: 0.42, dampingFraction: 0.86)` | system sheets animate themselves; this is for the custom compact drawer |
| Drawer after a flick (gesture carried velocity) | `.interactiveSpring(response: 0.32, dampingFraction: 0.78)` with the drag's `predictedEndTranslation` | the only place with overshoot < 0.8 |
| Composer grow/shrink, send→stop morph | `.spring(response: 0.28, dampingFraction: 0.9)` | never let the field bounce |
| Model pill / tier change pop | `.spring(response: 0.3, dampingFraction: 0.7)` scale 1 → 1.06 → 1 | mirrors the web's 0.42 s `tierPop` |
| Streaming text | none — text appends; only the caret pulses (`opacity 0.3↔1`, 1 s `repeatForever`) | `.animation(nil)` on the text body |
| Completion reveal (action row, quick replies) | `.spring(response: 0.4, dampingFraction: 0.85)` + `.transition(.opacity.combined(with: .offset(y: 6)))` | fires right after the completion haptic |
| Orb (call) | `TimelineView(.animation)`; level eased with rise 0.45 / fall 0.10 per frame; rotation `0.30 + level × 2.4` rad/s | copied from `orbAudioLevel` (`web-voice-call-mic.md §2.3`) |
| Welcome entrance | halo bloom 0 → 1 opacity over 0.6 s ease-out, mark scale 0.96 → 1 spring, greeting word-by-word 40 ms stagger | web `animateWelcome` |

Sheet presentation uses the system; do not wrap `.sheet` in `withAnimation`. The existing
`ModelSelectionSheet` fades/scales its content in with `.snappy(duration: 0.42, extraBounce: 0.035)` —
keep that as the "sheet content" entrance so every sheet feels the same.

### 3.2 Interruptibility

Every drawer/sheet gesture must be grabbable mid-flight: drive the compact drawer with a `@GestureState`
offset and animate *from the current offset* (`withAnimation(.interactiveSpring…)` on release), never
from a boolean toggled after the animation. Momentum projection for the drawer close/open decision:
`projected = translation + velocity × 0.998 / (1 − 0.998) / 1000` (Apple's deceleration form), open if
`projected > width/2`.

### 3.3 Reduce Motion and the in-app toggle (two switches, one contract)

`motionOn = preferences.motionEnabled && !accessibilityReduceMotion`. When off:
- entrances become 120 ms opacity cross-fades (`.transition(.opacity)`, `.animation(.easeOut(duration: 0.12))`),
- **busy indicators keep reporting**: the streaming caret, thinking dots and activity sweep become a
  1.5 s opacity pulse (`0.32 ↔ 1`) with no translation/scale — exactly the web's `rm-working` rule;
  never freeze a spinner (a frozen spinner reads as a hung app),
- the orb stops rotating and scaling and only changes brightness with level,
- welcome halo appears static at 55 % (already in `FirasBackground`),
- the tier pop and send pulse are skipped,
- autoscroll during streaming becomes `scrollTo(..., anchor: .bottom)` without animation.

Reduce Transparency: §2.4 item 8. Also add `@Environment(\.accessibilityDifferentiateWithoutColor)`:
tier Max's purple and Ultra's dot get a text badge (`الأقوى` / `للأكواد`) when set.

---

## 4. Typography and RTL

### 4.1 Faces and scale

- **System font everywhere.** `Font.system(.body)` resolves to SF Pro for Latin and SF Arabic for Arabic
  glyphs automatically, with correct joining, `rlig` lam-alef, vertical metrics for tashkeel. Never ship
  Noto/Reem Kufi natively; never use `.design(.rounded)` or `.design(.serif)` on Arabic (they fall back
  to a different face mid-word). `.rounded` is allowed for **digits-only** labels (badge counts).
- **Dynamic Type** is mandatory: use text styles, not point sizes, for all reading text; `@ScaledMetric`
  for icon sizes and paddings that must scale (composer min height 44 → `@ScaledMetric(relativeTo: .body)`).
  Settings → `حجم النص` (`fsSmall/Medium/Large`) applies `preferences.fontScale.factor` (0.92 / 1 / 1.10)
  through `.dynamicTypeSize` clamping or a custom `Font` multiplier — do **not** fight the OS setting;
  compose them (OS size × factor).
- Scale (matches the web `--text-*` at default OS size): caption 12/16 (`.caption`), meta 13/20
  (`.footnote`), UI 15/24 (`.subheadline`), body 16–17 (`.body`), title 21 (`.title3`), 26 (`.title2`),
  32 (`.largeTitle` only on Welcome and Brain hero).
- **Assistant prose**: `.body` at 17 pt with `lineSpacing` giving ≈ 1.9 line-height for Arabic
  (`.lineSpacing(9)` at 17 pt ≈ 32 pt lines) and ≈ 1.7 for Latin (`.lineSpacing(6)`). Decide per
  paragraph from its resolved direction. Paragraph spacing 20 pt; headings `.title3.weight(.semibold)`
  with 32 pt above / 12 pt below (web `styles.css:6553-6566`).
- **Tracking**: Latin display (`Firas AI` wordmark, English headings) may use `.tracking(-0.3)`; Arabic
  **never** gets tracking or kerning — it tears the joins. Implement as `Text.firasTracking()` that
  checks the string's script before applying.
- **Weight**: Arabic looks lighter than Latin at equal weight; UI labels on glass are `.medium`
  (`.semibold` for the 12–13 pt meta on floating chips). Never `.light`/`.thin` for Arabic.
- **Mono**: `.system(.body, design: .monospaced)` (SF Mono) for code, paths, model ids, timers.

### 4.2 Numerals

- Arabic UI counts and quotas use Arabic-Indic digits (the web does this for `quotaLimitText`, the
  mic timer, credits): format with `Locale(identifier: "ar-IQ-u-nu-arab")` —
  `Text(n, format: .number.locale(...))` or `n.formatted(.number.locale(...))`.
- Timers (`MM:SS` call timer, `m:ss` mission elapsed), code, versions, model ids, file sizes in the Code
  IDE stay **Latin digits and LTR**: `Locale(identifier: "en_US_POSIX")` and
  `.environment(\.layoutDirection, .leftToRight)` on that `Text`.
- Never use Eastern Arabic-Indic (۰۱۲) — that is Persian/Urdu; `ar-IQ` gives ٠١٢.
- Plurals: use `String(localized:)` with `.stringsdict` plural rules for `zero/one/two/few/many/other`
  (Arabic has all six). Web strings like `الحد الأقصى ١٠ صور` are fixed text — keep them verbatim.

### 4.3 RTL rules in SwiftUI (LTR shell, bidirectional islands)

1. Root shell: `.environment(\.layoutDirection, .leftToRight)` (already in `FirasAppShell`). Sidebar
   left, chevrons point right to open, toolbar order fixed. The user does not get a mirrored app when
   they switch to Arabic — same as the web.
2. **Islands** (message body, composer field, chat title row, card body, plan card, passage viewer,
   Brain answer): wrap in `.environment(\.layoutDirection, dir)` where
   `dir = BidiDirection.firstStrong(text)` (scan scalars: U+0590–08FF, FB1D–FDFF, FE70–FEFF → `.rightToLeft`;
   Latin/Greek/Cyrillic letters → `.leftToRight`; digits/punctuation/emoji skipped; empty → UI language).
   Inside the island use **leading/trailing only** (`.frame(maxWidth: .infinity, alignment: .leading)`,
   `.multilineTextAlignment(.leading)`, `.padding(.leading, …)`) so the same view works both ways.
3. The composer field re-evaluates direction while typing (web `syncComposerDir`): empty → UI language;
   with text → first strong. Placeholder direction follows the UI language.
4. Force-LTR islands: code blocks, inline code, file paths, URLs, model ids, timers, math
   (`.environment(\.layoutDirection, .leftToRight)` + `.multilineTextAlignment(.leading)`).
5. Symbols: SF Symbols with `.forward`/`.backward` names mirror with the environment; in the fixed-LTR
   shell nothing mirrors, which is intended. Inside an RTL island use `chevron.forward` so a "next" chevron
   points left for Arabic content. Never use `chevron.right` for "next".
6. Sheets and pickers inherit the shell's LTR; their *content rows* that carry Arabic labels align text
   with `.multilineTextAlignment(.leading)` — text alignment is per-row, layout is per-shell. The existing
   `ModelSelectionSheet` sets `.environment(\.layoutDirection, preferences.language.layoutDirection)` —
   that mirrors the sheet's chrome in Arabic and contradicts rule 1; change it to the row-level rule.
7. `Text` containing mixed script: SwiftUI applies the Unicode bidi algorithm per `Text`; a neutral
   trailing full stop lands on the correct side only if the paragraph direction is right — rule 2 makes it
   right. For chat titles in the sidebar list, wrap in an island too (a Latin-leading Arabic title otherwise
   parks its `؟` on the wrong end).
8. Gradients that should not flip (the user-bubble sheen) use absolute `startPoint: UnitPoint(x:0, y:0)`;
   directional ones (the activity sweep) run leading→trailing inside the island.

---

## 5. Haptics and sound

### 5.1 Vocabulary

| Moment | API | Parameters |
|---|---|---|
| Send | `UIImpactFeedbackGenerator(style: .light)` / `.sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: sendCount)` | fire on the frame the user bubble is inserted, not on button release |
| Stop | `.sensoryFeedback(.impact(weight: .medium, intensity: 0.5))` | |
| Chip / tier / mode selection, drawer snap | `UISelectionFeedbackGenerator` / `.sensoryFeedback(.selection, trigger:)` | |
| Attachment added | `.sensoryFeedback(.impact(weight: .light))` | one per file, coalesced within 120 ms |
| Tool step reached (search started, thinking opened, agent step done) | `.sensoryFeedback(.impact(weight: .light, intensity: 0.35))` | only if the screen is visible; never for silent searches |
| Completion (answer done, image landed, build done, mission done) | `FirasCompletionCue` — soft impact 0.32 → 160 ms → 0.48 | **before** the final paint; see §5.3 |
| Error / quota / refusal | `UINotificationFeedbackGenerator().notificationOccurred(.error)` / `.sensoryFeedback(.error)` | alongside the red toast |
| Undo taken | `.sensoryFeedback(.success)` | |
| Long-press menu open | system (context menu haptic is automatic) | do not add another |
| Call: connect, speech start, hang up | `.start`, `.impact(.light)`, `.stop` | `.sensoryFeedback(.start, trigger: phase == .listening)` |
| Recording start / stop (dictation) | `.start` / `.stop` | |
| Drawer edge reached / rubber-band | none | motion is the feedback |

Rules: prepare generators before the moment (`generator.prepare()` when the stream reaches its last
chunk / job phase turns `completing`), never fire in the background (`UIApplication.shared.applicationState == .active`),
never fire twice for one job (the `FirasCompletionCue` consumed-key history already guards this), and
skip the "theatrical" double pulse under Reduce Motion (existing behaviour) while keeping the single
`.success` notification so the moment is still marked.

### 5.2 Sound

- Two UI sounds only: `send.caf` (≈ 60 ms tick) and `done.caf` (≈ 180 ms soft chime). Off by default;
  Settings → `الصوت` → `أصوات الواجهة` **[new]** switch. Announcement bell has no sound.
- Player: one preloaded `AVAudioPlayer` per sound, `prepareToPlay()` at launch, `volume 0.6`.
- Session: UI sounds play under `AVAudioSession.Category.ambient` (mixes with others, obeys the silent
  switch). **Never touch the session while a call is active** — `LiveVoiceController` owns
  `.playAndRecord` + `.voiceChat`; check `voice.isActive` and simply skip the sound. Songs / Listen (TTS)
  use `.playback` so a locked phone keeps playing (web media spec §12.1 item 5).
- Completion sound plays on the same frame as the completion haptic (harmony rule).

### 5.3 The pre-reveal cue (fix required in `FirasCompletionCue.swift`)

The intent ("haptic just before the reveal, like Claude") is right; the implementation waits
`Task.sleep(for: .seconds(3))` after the second pulse before returning `true`, which holds a finished
answer off-screen for three seconds. Change to `.milliseconds(140)` after the second pulse (total
≈ 300 ms from first pulse to reveal). Keep the 160 ms gap between pulses, the consumed-key history, the
foreground check and the Reduce Motion skip. Callers must paint the *final* state on the frame after the
cue returns; the streaming text must already be on screen before the cue starts (the cue marks the
transition to "done", it is not a loading spinner).

---

## 6. Theme tokens (six themes, verified against `styles.css:11-391`)

`FirasTheme.swift` already carries these exact values; the table below is the reference, plus the
derived glass tokens the palette must gain. Light is the only light-family theme; the other five are
dark-family (`THEMES[].dark`), which also drives `preferredColorScheme`.

### 6.1 Base tokens (hex)

| token | light `نهاري` | dark `ليلي` | black `أسود` | midnight `نيلي` | graphite `كربوني` | amber `عنبري` |
|---|---|---|---|---|---|---|
| bg | #FAF9F5 | #262624 | #000000 | #0F1522 | #171719 | #1B1713 |
| bgSubtle | #F0EEE6 | #1F1E1D | #0A0A0A | #0A0E19 | #101012 | #141110 |
| surface | #FFFFFF | #30302E | #161616 | #182133 | #202023 | #241F19 |
| surfaceSunken | #F0EEE6 | #1F1E1D | #0A0A0A | #0A0E19 | #101012 | #141110 |
| sidebar | #F5F4EE | #1F1E1D | #000000 | #0A0E19 | #101012 | #141110 |
| textPrimary | #1A1A18 | #ECEAE3 | #F2F2F0 | #E6ECF5 | #ECECEE | #F0E7D8 |
| textSecondary | #6B6A63 | #A6A39A | #ABABA6 | #9FACC2 | #A5A5AA | #B3A793 |
| textMuted | #6E6C64 | #9A978E | #8C8C87 | #8695AE | #8B8B90 | #9C907C |
| border (hairline) | #E6E4DA | #3A3A36 | #232323 | #232E44 | #2A2A2E | #332C23 |
| borderStrong | #D8D6CB | #46453F | #343432 | #33405A | #3A3A3F | #453C30 |
| accent | #237A68 | #57AE9C | #5FBBA7 | #5AA9E6 | #57AE9C | #D9A05B |
| accentHover | #1A6253 | #6BC0AE | #74CFBB | #7CBEF0 | #6BC0AE | #E8B475 |
| accentDeep | #14544A | #2F6F62 | #2F6F62 | #2C6394 | #2F6F62 | #8A6234 |
| accentSoft (rgba) | 44,138,120 @ .08 | 87,174,156 @ .14 | 95,187,167 @ .15 | 90,169,230 @ .15 | 87,174,156 @ .14 | 217,160,91 @ .15 |
| accentRing (rgba) | 44,138,120 @ .40 | 87,174,156 @ .45 | 95,187,167 @ .45 | 90,169,230 @ .45 | 87,174,156 @ .45 | 217,160,91 @ .45 |
| onAccent | #FFFFFF | #1F1E1D | #000000 | #0A0E19 | #101012 | #1B1713 |
| success | #2E7D5B | #4BA784 | #4BA784 | #4BA784 | #4BA784 | #8FBF6F |
| error | #B3261E | #E06A60 | #E06A60 | #E06A60 | #E06A60 | #E06A60 |
| grain opacity | .030 | .042 | 0 | .035 | .03 | .05 |
| status-bar / meta colour | #FAF9F5 | #262624 | #000000 | #0F1522 | #171719 | #1B1713 |

Settings tile swatch = `[bg, surface, accent]` (`THEMES[].sw`). Names: ar `نهاري / ليلي / أسود / نيلي / كربوني / عنبري`,
en `Light / Dark / Black / Midnight / Graphite / Amber`. Section title `الثيم` · `ستة أمزجة` / `six moods`.

Note for `FirasTheme.swift`: `accentSoft` and `accentRing` are not in `FirasPalette` yet — add them (used
by the Ultra tier pill background and focus rings).

### 6.2 Derived glass and message tokens (add to `FirasPalette`)

| derived | light | dark | black | midnight | graphite | amber |
|---|---|---|---|---|---|---|
| glassTint | accent @ .035 | accent @ .05 | accent @ .05 | accent @ .05 | accent @ .05 | accent @ .045 |
| glassWash | black @ .025 | white @ .04 | white @ .06 | white @ .04 | white @ .04 | white @ .035 |
| glassStroke | black @ .08 | white @ .10 | white @ .14 | white @ .10 | white @ .10 | white @ .09 |
| glassShadow | black @ .08 r24 y8 | black @ .18 r24 y8 | black @ .30 r24 y8 | black @ .20 | black @ .20 | black @ .20 |
| userFill | mix(accentDeep 90%, surface) = #2A6055 | mix(accentDeep 94%, surface) = #2F6D60 | #2E6C5F | #2B5F8E | #2E6C5F | #866032 |
| userInk | #FFFFFF | #FFFFFF | #FFFFFF | #FFFFFF | #FFFFFF | #FFFFFF |
| userEdge | accent @ .40 | accent @ .40 | accent @ .40 | accent @ .40 | accent @ .40 | accent @ .40 |
| userSheen (inner top hairline) | white @ .16 | white @ .16 | white @ .16 | white @ .16 | white @ .16 | white @ .16 |
| maxTier text / dot | #7C3AED / #8B5CF6 | #A78BFA / #8B5CF6 | same as dark | same | same | same |
| maxTier active bg | rgba(139,92,246,.13) | same | same | same | same | same |
| planGold / planDiamond | #B8862A / #3E7CB1 | #D8B45A / #8FB4E0 | same as dark | same | same | same |
| callBackground | radial(accent @ .26 at 50%,12%, 120%×80%) over bg | radial(accent @ .30) over **#14201D** | radial over #000 | radial over bg | radial over bg | radial over bg |
| codeWarn / codeOk (console) | #B3261E / #2E7D5B | #E3B341 / #6FC48B | #E3B341 / #6FC48B | #E0B45C / #6FC48B | #DDB45F / #77C191 | #E8B552 / #7CC596 |

`userFill` values are the `color-mix` results computed in sRGB from `styles.css:6448-6455` (90 % / 94 %
accent-deep into surface); the exact mix formula may be reproduced at runtime instead of hard-coding.
Colour tags (sidebar rows, fixed across themes): red #C0503F, amber #B0842C, green #4E8A46, teal #2E8A82,
blue #4A72B8, purple #8A5FB0 (keys `tagRed … tagPurple`).

Contrast rule carried from the web: `textMuted` is the placeholder colour and must clear 4.5:1 on both
`bg` and `surface` — the values above already do; do not lighten them for "softness".

---

## 7. Screen-by-screen spec

Common: every screen sits on `FirasBackground`; toolbars are system glass; the reading column is
`min(width − 32, preferences.contentWidth.maxWidth)` (760 normal / 980 wide — the web is 704/920 for prose
inside a 744 column; the Swift values already exist) centred; 16 pt gutters on iPhone.

### 7.1 Home / Chat (Firas AI)

Layout (iPhone): toolbar — leading `sidebar.left` (opens drawer), principal **tier pill**
(`bolt` icon + `برو` + `chevron.down`, `.floating` capsule; Agent: static `Firas Agent`), trailing
`square.and.pencil` (new chat, `محادثة جديدة`) and, only when the chat has generated images,
`photo.on.rectangle.angled` (gallery). Bell lives in the drawer, not here. Subtitle
(`.navigationSubtitle`, iOS 26) shows the chat title once it exists; before that nothing.

Body: `ScrollView` of turns, `scrollEdgeEffectStyle(.soft, for: .top)`; composer as `safeAreaBar(edge: .bottom)`
(iOS 26) / `safeAreaInset` (iOS 18) so the last turn scrolls under it. Scroll-to-bottom chip
(`arrow.down`, `.floating` circle 40 pt) appears when the reader is > 240 pt above the end and hides while
they are at the edge; autoscroll only when they are at the edge (streaming-ui rule).

Empty state (new chat): halo (accent radial), the Firas mark (`FirasBrandMark`), one greeting line:
`صباح الخير` (< 12 h) / `مساء الخير` (< 18 h) / `مساءً سعيدًا`, with first name → `{base} يا {first}`
(en `{base}, {first}`). No suggestion chips (the web deliberately shows none). Agent empty state: title
`Firas Agent`, sub `وكيل ذكي للمهام الكبيرة: يخطّط، ينفّذ خطوة بخطوة، يراجع عمله بنفسه، ثم يسلّمك ملفات ومشاريع جاهزة.`
and a saved-templates strip.

Loading states: opening a chat from the list shows a three-row skeleton (two assistant-shaped, one
user-shaped) for ≤ 400 ms then content; never show the "never had one" empty state while a fetch is in
flight. Thread-loading dots: three 6 pt dots `textMuted → accent` pulse.

Error states: connection failure = inline strip under the last turn `تعذّر الاتصال.` + `إعادة المحاولة`;
offline send = outbox strip in the answer slot `لم تُرسَل رسالتك — لا يوجد اتصال. سنرسلها فور عودته.` → on reconnect
`عاد الاتصال — رسالتك لم تُرسَل بعد.` + button `أرسلها الآن`; 429 = assistant-styled message with the
quota text (§7.16); session expiry = toast `انتهت جلستك. الرجاء تسجيل الدخول من جديد.` then Auth.

### 7.2 Sidebar / drawer

iPhone: overlay from the leading edge, width `min(360, max(286, screen − 44))`, `.floating` glass
(clear + wash) with the chat still visible behind a 30 % black scrim (`FirasAppShell.compactLayout`
already draws this — swap its solid `sidebar` background for the floating glass; keep the shadow).
Interactive edge-swipe to open (20 pt edge zone), drag to close, momentum projection §3.2.
iPad: `NavigationSplitView` column 270–360 pt (existing widths), `backgroundExtensionEffect()` on the
detail so the conversation bleeds under the floating sidebar.

Sections, top to bottom (web `renderHistory` order, trimmed to what a phone needs):
1. Header row: brand lockup, bell (`bell` + 9 pt accent dot when `announcement.ts > seen`), close.
2. **Product switcher** — a segmented list of five rows with icon, title, one-line subtitle:
   `Firas AI · المحادثة الذكية`, `Firas Agent · وكيل ينفّذ المهام الكبيرة`,
   `Firas Code · بيئة تطوير بالمتصفح مع مساعد ذكي` (native subtitle should drop "بالمتصفح" —
   **[new]** `بيئة تطوير كاملة مع مساعد ذكي`), `Firas Brain · اسأل ملفاتك — بإجابات موثّقة بالصفحة`,
   `الاستوديو · صور وفيديو وأغاني` **[new]**. A product with a live job shows a pulsing accent dot or count
   (`railActivity`).
3. `محادثة جديدة` prominent row (`.glassProminent` capsule, `plus`), then search field
   `ابحث في المحادثات` (`Tab(role:.search)`-style pill on iOS 26 is *not* used here — it's a plain
   `TextField` inside the drawer; ≥ 3 chars also searches loaded message text, group `msgHits`, offer
   `ابحث في كل المحادثات`).
4. Saved shelves `محفوظاتي` / `قصاصاتي` (counts hidden until non-zero).
5. History, filtered to the current product: `المثبّتة`, then `اليوم / أمس / آخر ٧ أيام / آخر ٣٠ يومًا / أقدم`
   (keys `today/yesterday/previous7/previous30/older`). Row: colour stripe (tag), live dot
   (`ما زالت تشتغل` accessibility label) when a job pointer exists, title (bidi island), swipe actions:
   leading pin/unpin, trailing delete (no confirm; 7 s undo toast `chatDeleted` + `تراجع`; if a reply was
   streaming the toast is `chatDeletedStream`). Context menu: `إعادة تسمية`, `تثبيت`, colour tag, `حذف`.
   Rename inline with `TextField` (Enter commits, blur commits, Esc cancels).
6. Usage row `استخدامك` (7-day conversation counts per product, computed locally).
7. Guest slot (guests only): `guestLocalNote` + bilingual CTA `سجّل الآن` / `Sign up now`.
8. Account pill: avatar = first letter uppercased (`F` fallback) on accent, name (user name / email
   local-part / `Firas`; guest `ضيف`), buttons `الإعدادات` (gear) and `تسجيل الخروج`. No plan or quota here.

Empty states (five, per the empty-states playbook): never-had-one `emptyHistory` (+ per product
`emptyHistoryAgent/Code/Brain`), filtered-to-zero `noResults`, tag-filtered `tagEmpty`, load error
`chatsLoadError` + `إعادة المحاولة`, and the skeleton while loading (never the words). Rows animate in
once with a 20 ms stagger (skip under reduced motion).

### 7.3 Composer

`.floating` glass, radius 24, max width = reading column, 8 pt inner padding, two rows:

Row 1: multiline field, placeholder `اسأل فِراس...` (Agent: `كلّف فِراس بمهمة صعبة`; Brain ask box:
`اسأل عن ملفاتك…` / `ارفع ملفًا أولًا` when no source), 1–6 lines (web caps at 152 px ≈ 6 lines), min
height 44, direction per §4.3 item 3. Attachment tray above the field when non-empty: image thumbs
64 pt (skeleton while decoding, × badge), file chips with kind tag `PDF / DOC / PPT / XLS / IMG / TXT` and
`...قراءة` while reading; a truncated file gets an orange corner and the tooltip
`الملف كبير — أُرسل نحو {pct}٪ من محتواه فقط. للمستند الكامل استخدم فِراس Brain.`

Row 2 (leading → trailing): `plus` (Add sheet; shows a count badge and `has-active` accent ring when web
search or thinking is on), **mode pill** `تلقائي` ⚡ / `تخطيط` 📋 (menu, §7.5), spacer, `mic` (dictation;
`إدخال صوتي`, long-press 450 ms → dialect picker), `phone` (call; Firas AI only, hidden in Agent/Code/Brain),
send (`arrow.up` in a `.glassProminent` circle 36 pt; disabled until text or a ready attachment exists and
no attachment is still reading; becomes `stop.fill` while streaming; `send-pulse` = scale 1 → 0.92 → 1
over 440 ms).

Below the composer, 11 pt `textMuted`: `قد يخطئ فِراس. تحقّق من المعلومات المهمة.` — always, both products
(Brain shows its own hero instead).

Length meter (silent under 400 chars): `{chars} حرف · {tokens} رمز`; near cap (≥ 80 % of
`mini 4000 / pro 16000 / ultra 16000 / max 24000` tokens) turns `accent` with `lenmNear`; over turns
`error` with `lenmOver`; hard cut 200 000 chars.

Keyboard: Return inserts a newline unless Settings → `الإرسال بمفتاح Enter` is on (`sendOnReturn`),
`⌘↩` always sends; hardware `esc` = stop while streaming. Drafts: per chat and per `new:<product>`
sentinel, saved 400 ms after typing and on scene background, restored on open, LRU 30, 20 000 chars.

Slash menu: typing `/` at the start opens `أوامر سريعة` with four rows (Summarize / Translate / Explain /
Review) as a small `.sheet`-level glass popover anchored above the composer.

#### 7.3.2 Add sheet (`+`)

Presented as a **medium-detent sheet** (system glass), two groups:

- Attach: `الكاميرا` (`camera`) **[new — web has no camera button; the OS picker decides]**,
  `الصور` (`photo.on.rectangle`), `الملفات` (`folder`). Limits from the web: ≤ 10 images (`الحد الأقصى ١٠ صور`),
  longest edge 1568 px JPEG q 0.85, thumbs 256 px; ≤ 5 documents (`الحد الأقصى ٥ ملفات`), 120 000 chars each,
  300 000 total (`حجم الملفات كبير جداً`); PDF first 60 pages; unsupported → `نوع ملف غير مدعوم`; unreadable →
  `تعذّر قراءة الملف`; empty → `ما كدرت أقرأ نص من الملف`. Accepted types: image/*, PDF, docx/pptx/xlsx/xlsm,
  and the text/code extension list in `web-chat-ux.md §7.3`. Agent variant title `agentAttachHint`.
- Tools (switch rows): `بحث الويب` (subtitle on: `بحث الويب مُفعّل — يبحث في كل رسالة`, off:
  `بحث الويب تلقائي — يبحث عند الحاجة`), `التفكير` (`التفكير مُفعّل — دقة أعلى` / `التفكير مُعطّل — استجابة أسرع`;
  hidden on Mini), `لغة الإملاء` (opens the dialect list, §7.14). Brain adds `اقرأ بالرؤية (أدق للملفات
  العربية والمصوّرة — أبطأ)`.

Selection haptic on each toggle; the sheet stays open after toggling, dismisses after picking a file.

### 7.4 Model / tier picker

Reached from the principal tier pill. Medium-detent sheet, system glass (remove the solid
`.presentationBackground` in `ModelSelectionSheet` on iOS 26), title `النموذج` **[new; web has no sheet
title]**. Four rows (radio):

| key | icon | label | tagline | badge |
|---|---|---|---|---|
| mini | `bolt.fill` (web `zap`) | `فِراس ميني` | `سريع للأسئلة اليومية` | — |
| pro | `bolt` | `فِراس برو` | `متوازن وذكي` | — |
| ultra | `star` | `فِراس أولترا` | `قويّ جدًا — الأفضل للأكواد` | `للأكواد` (accent pill + 6 pt dot) |
| max | `crown` | `فِراس ماكس` | `الأقوى — أعلى ذكاء وتفكير` | `الأقوى` (purple #7C3AED / #A78BFA on rgba(139,92,246,.13), pulsing dot) |

Short names for the pill: `ميني / برو / أولترا / ماكس`. Nothing is locked — no padlocks, no plan copy in
this sheet. Selecting fires the tier pop and toast `تم تعيين النموذج الافتراضي ✓` **only from Settings**
(the sheet applies silently). Per-chat pin ("tpin") is desktop-only on the web — omit natively.

Second card in the same sheet: **Response style** row `أسلوب الردّ` with the two modes as a segmented
control `تلقائي` / `تخطيط` and hints `ذكي ومباشر — يجيب فورًا.` / `يسأل ويضع خطة، ثم ينفّذ بعد موافقتك.`
(web taps toggle; native shows both explicitly). Mode is global per device, not per chat; a call forces
`auto` and restores after.

### 7.5 Response style — Plan card and `firas-ask`

Composer pill menu (`النمط`): two `menuitemradio` rows with icon, label, hint, check.

Plan mode turn: the reply streams as prose; when finished (not a `firas-ask` turn, not the delivery turn),
show the **Start pill** under the answer: `.glassProminent` capsule with `play.fill` + `ابدأ التنفيذ`,
accessibility hint `موافقة على الخطة وبدء التنفيذ`; tapping sends `ابدأ التنفيذ ونفّذ الخطة.` as a user
message (haptic `.impact(.medium)`), and the pill dissolves.

`firas-ask` card (clarifying questions, ≤ 4 questions, 2–5 options each): a solid `surface` card, radius 9,
stepper header `سؤال {n}/{total}`, options as radio/check rows (multi when `multi`), `موصى به` badge on the
recommended option, footer `السابق` / `متابعة` / last step `تأكيد الاختيارات`, free-text row
`أو أضف تفصيلاً…`. While the block is streaming show `جاري تحضير الأسئلة…` with the dots. After submit the
card collapses to `تم الإرسال` + `اختياراتي: …` summary and the answers go as one user message. State
machine and defects: `web-plan-mode.md §7` — implement that, not the web.

### 7.6 Message rendering

**User turn**: bubble on the trailing edge, `max 78 % / 520 pt`, fill `userFill` with a 160° gradient
(white 9 % → fill → black 7 %), inner top hairline `userSheen`, 1 pt edge `userEdge`, radius 20 with the
bottom-trailing corner 7, shadow tinted accentDeep 42 % `r24 y10`; ink white; contents: image grid → file
chips → text (`pre-wrap`, clamp at 12 lines with `عرض المزيد` / `عرض أقل`) → inline math. Long-press → copy
menu (no edit-and-resend, no reactions — the web has none).

**Assistant turn** (no bubble, a document): head = 20 pt circular Firas mark + `FIRAS` in 12 pt uppercase
tracked small caps (Latin only) `textSecondary` + tier badge (`ميني/برو` muted; `أولترا` accent pill with
dot; `ماكس` purple pill) — Agent chats show `Firas Agent` and no badge. Then, in order: retry-pair strip
(`أُعيد هذا الجواب بنموذج أقوى` + `قارن الجوابين`), thinking disclosure (`التفكير`, chevron rotates 90°, plain
text body, closed by default, only when `tier.showThinking && reasoning non-empty`), body markdown, card
by fence (`firas-agent`, `firas-deck`, `firas-project`, `firas-image`, `firas-music`, `firas-video`,
`firas-code`, file-request → collapsed `عرض المحتوى` disclosure), plan Start pill, quick-reply chips
(from headings/bullets; each inserts `اشرح لي «{q}» بتفصيل أكثر`; hidden on card turns / truncated / plan
turns), action row. Turns are separated by 32 pt (40 pt on iPad) and a hairline `border` between turns,
never above the first.

Streaming: text appends into an `AttributedString` built incrementally (settled prefix frozen, live tail
re-rendered), a 2 pt accent caret pulses at the end, code fences and `$$` that are still open render as
plain text until closed, math typesets only for newly settled blocks. Indicators above the body:
`يبحث في الإنترنت…` (explicit search only), `فِراس يفكّر…` while reasoning streams with the panel closed.

Markdown: headings, lists, tables (horizontal scroll inside their own container), blockquote in
`textSecondary`, inline code `bgSubtle` + hairline radius 2, code blocks = §7.10 card style with a copy
button (`نسخ` → `تم النسخ`), math via a native KaTeX-equivalent (SwiftMath/`MTMathUILabel` or a WKWebView
KaTeX island — decision belongs to the math slice), links open in `SFSafariViewController`.

### 7.7 Message actions

Latest assistant turn: a compact row of four 32 pt ghost buttons `نسخ`, `إعادة التوليد`, `استمع`
(`listen` ↔ `listenStop`), `تصدير` (`download` menu), plus `المزيد` (`ellipsis`) — the rest live in the
long-press context menu on every assistant turn, in the web's order:
`نسخ` · `حفظ في محفوظاتي` (`shelfSave`) · `استمع` · `اقرأ الباقي` (`rqStart`) · `قُلها أبسط` (`simplify`, sheet
`simplifyChild / Beginner / Exam`) · `إعادة التوليد` · `اسأل مجددًا` (`askAgainBtn`) · `اسأل في مكان آخر`
(`askXBtn` → Brain/Agent; `لا ملف مختار في فِراس Brain — افتحه واختر ملفًا أولًا`) · `أكمل` (only when the
answer looks truncated) · `أعد بـ فِراس ماكس` (only when `msg.tier != max`; keeps both answers, links them)
· `مشاركة هذا الجواب` (members only) · export submenu (`PDF — بالهوية المحفوظة`, `PDF — اختيار الهوية…`,
PDF, image, print, Word, Excel, PowerPoint, HTML, Markdown, text) · `قارن جوابين` (`cmpTwo`) · `وضع القراءة`
(`focusRead`) · `تكبير النص` (`bigText`) · `جملة جملة` (`paceRead`) · `تثبيت الرسالة` (max 12:
`ما تقدر تثبّت أكثر من ١٢ رسالة بالمحادثة الوحدة`) · `ملاحظة خاصة` (max 40).

Copy success = `تم النسخ` for 1.4 s in place + `.selection` haptic; failure toast `تعذّر النسخ — جرّب مرة أخرى`.
Regenerate keeps versions with a pager `‹ 2/3 ›` above the turn.

### 7.8 Agent mission screen

Same chat shell; the assistant cell for a mission grows into the **mission card** (UI 2.0 "a timeline,
not a box"): a solid `surface` card with a 3 pt accent spine on the leading edge (60 % alpha while live,
85 % when done), radius 0/9/9/0 (mirrored in RTL islands), background accent 4 % over surface.

Inside, top to bottom (`web-agent-ux.md §7, §15`):
1. Header: brand mark · `Firas Agent` · status pill (phase → `يقرأ / يخطّط / ينفّذ / يراجع / يحسّن / يجمّع /
   يختبر / تمّت / متوقّفة / تعذّرت` per the report's §8 mapping) · elapsed `m:ss` LTR.
2. Speech line (last `says`), animated in with the house spring.
3. Plan disclosure `خطة التنفيذ` · `done / total`; rows = status glyph (`circle` todo / pulsing `circle.dotted`
   running / `checkmark.circle.fill` done / `xmark.circle` failed) + title + kind; expanding a row shows its
   markdown output.
4. Activity list (events with kind icons, detail, "open source" link); sources group; files: image grid,
   document list opening an in-app viewer (QuickLook for PDF, sandboxed `WKWebView` for html/md/json,
   plain text otherwise) fetched **with the session cookie** from `/api/agent/artifact`; share via `download=1`.
5. `النتيجة` (markdown + math) when `final` exists.
6. Footer actions: `▶ استئناف المهمة` (only `stopped`/`fail` with unfinished steps and not blocked —
   it starts a **new** charged mission), `فتح المهمة الجارية ←` (blocked with `activeChatId`),
   `⬇ تصدير Markdown` (share sheet; toast `تم تنزيل ملف المهمة ✓`). Omit steer, save-as-template, fix-what's-left.

Live states: a 44 pt `tabViewBottomAccessory`-style strip is *not* used in the chat (the card is the
status); instead the sidebar row gets the live dot and the product switcher row a count. Blocked/credit
states render the report's §9 sentence with no steps and a credits chip (`٥٠٠ كريديت` Arabic-Indic).
Credits chip in the Agent toolbar trailing slot (`creditcard` + count) opens the credits dialog (§14 of
the agent report). Guests: the sign-up sheet, mission never starts. One live mission at a time — the
busy toasts from `app.js:44441-44449`.

Completion: `FirasCompletionCue` when the phase turns terminal while the screen is visible; push
notification (`firas.type == "job-terminal"`) otherwise; tapping it opens the chat and fetches a snapshot.

### 7.9 Code IDE screen

**Launcher** (Code home): hero (`Firas Code`, one line), **create card** on `.sheet` glass: name (≤ 60),
description (≤ 1500), attachments, two `.glassProminent` buttons `مشروع فارغ` / `ابنِ بالذكاء` (strings per
`web-code-ux.md §2`), then the project grid (2 columns iPhone, 3–4 iPad) with context-menu delete. Empty
state: the create card *is* the empty state (state 1 — never had one); after deleting the last project show
the grid area's "had some, now none" line from §2.

**Workspace** (iPhone): `TabView` with `tabBarMinimizeBehavior(.onScrollDown)` and four tabs
`الملفات` (`doc.on.doc`), `الكود` (`chevron.left.forwardslash.chevron.right`), `المعاينة` (`play.rectangle`),
`المساعد` (`sparkles`); `tabViewBottomAccessory` shows the **build strip** while a server build runs
(`يبني… {n} ملف` + progress; tap → the log) — in the `.inline` placement it collapses to the spinner + count.
Top bar: back, project name (`navigationSubtitle` = `saved / editing / saving` pill state), trailing menu:
Run, Improve, History, New file, Find, Share, ZIP.

- **Files**: rail with folders collapsed by default, file rows (icon by extension, name LTR mono),
  swipe delete/rename, `+` new file; cap 30 files, 120-char paths (refusal toasts from `§1`/`§5.2`).
- **Code**: editor is a **solid** `surfaceSunken` panel (no glass — text must be crisp), SF Mono 13 pt,
  LTR forced, syntax colours = the web's dark editor skin (`tag #E08B66`, `attribute #6FB8AB`,
  `string #8FC9A8`, `keyword #E39A72`, `def #9BA8E8`, `number #E0B35E`, `comment #7A776A`,
  `builtin #C4A7F5`, cursor `#E39A72`, gutter `#242422`, active line `#282824`, selection `#3A382E`) on
  dark families and the light skin on `light`. Autosave 900 ms, 60 000 chars per file at save.
  Hardware keyboard: `⌘S` save now, `⌘F` find, `⌘/` comment.
- **Preview**: `WKWebView` with the assembled single document (§5.4 of the code report) and the console
  hook as a `WKScriptMessageHandler`; device presets `390×844`, `834×1112`, fluid, rotate; auto-reload
  toggle (700 ms / CSS live push 2500 ms); reload; open in Safari (temp file); run-status pill; empty
  state `أنشئ index.html` **[new wording; web §5.4]**. Console segment below: level chips with counts
  (error `error` colour, warn `codeWarn`, ok `codeOk`), filter, clock toggle, clear, and "أصلحه بالذكاء"
  that feeds the error buffer to the AI bar.
- **AI**: command bar with `@` file mentions and attachments; answers arrive as a **diff review sheet**
  (per-file checkboxes, apply on approval — `web-code-ux.md §6.5`), thread persisted in `messages[1]`.

Build lifecycle: `POST /api/chat/job` `kind:"codebuild"`, poll 4 s, 2 h ceiling, land files before
forgetting the pointer, reattach on foreground/launch/online, APNs deep link by `jobId`. Completion cue on
land. Members unmetered; guests 60 units/day.

**Chat-side code card** (`firas-code` in Firas AI): a `surface` card with header (file name LTR mono +
language chip), first ~14 lines visible with a fade, buttons `نسخ` · `تنزيل` · `معاينة` · `أكمل` and a wrap
toggle; `معاينة` opens the full-screen viewer with a `معاينة / الكود` segmented control (the Claude artifact
pattern).

### 7.10 Brain library and reader

iPhone: the product opens on the **ask thread** (a chat shell filtered to `brainNb` notebooks) with a
`.floating` **sources chip row** above the composer: pinned/selected source chips (`doc.text` + title,
`checkmark` when active, `pin.fill` when pinned), a range chip `صفحة ١٢–٣٠` when set, and a `المصادر`
button opening the **library sheet** (large detent).

Library sheet: hero `اسأل ملفاتك` / `ارفع ملفاتك واسأل عنها — كل معلومة في الجواب موثّقة بالصفحة اللي جات منها.`,
`إضافة ملفات` prominent button with hint `PDF، Word، PowerPoint، Excel، نصوص، وصور`, source rows (kind tag,
title, `N صفحة`, meta `يفهرس / يقرأ / يقرأ الصفحات المصوّرة / يرفع / تمّت الفهرسة` with a determinate bar
during extraction), toggle `اقرأ بالرؤية (أدق للملفات العربية والمصوّرة — أبطأ)`, quota line from
`limits`. Empty: `ما في مصادر بعد` / `ارفع أول ملف لتبدأ` with the add button *inside* the empty state.
Errors: `نوع ملف غير مدعوم`, `تعذّرت قراءة الملف`, `ما لقيت نص في هذا الملف`, `وصلت الحد الأقصى للمستندات`,
`وصلت حدّ الصفحات اليومي`. Extraction runs on-device (PDFKit + Vision OCR) per `web-brain-ux.md §15.1`.

Answer rendering: markdown with inline **citation chips** `[S1]` → tappable capsule (`1`, accent soft
bg); tapping opens the **passage reader** sheet: source title, `صفحة N`, before / **hit** (highlighted
accent 18 %) / after text, `فتح المصدر`, copy; deleted-source fallback text. Sources list under the
answer (`المصادر`). Compare mode renders two columns on iPad, stacked on iPhone.

Composer placeholder: `اسأل عن ملفاتك…`; with zero active sources the field is disabled with
`ارفع ملفًا أولًا` and the send button hidden. Send/stop labels `إرسال` / `إيقاف`. Guest: 120 questions/day,
no whole-document call.

### 7.11 Media Studio (native-only surface)

Two tabs (`TabView`, minimize on scroll): `المكتبة` and `إنشاء` **[new]**.

**المكتبة**: a 3-column (iPhone) / 5-column (iPad) grid of every `firas-image` / `firas-video` /
`firas-music` fence found across conversations, kind chip on each tile (`photo` / `video` / `music.note`),
grouped by conversation with a sticky header (conversation title, date). Tap → full-screen viewer (pinch
zoom, `AVPlayer` for video via `/api/video/file?id=` with cookie, audio player card for songs) with
`حفظ في الصور` / `مشاركة` / `افتح في المحادثة` / `تعديل` (images only) and `إعادة التوليد`. Empty (never):
`ما زال الاستوديو فارغًا — اكتب «اصنع لي صورة…» في المحادثة أو ابدأ من هنا` **[new]** + a button to the
`إنشاء` tab. Loading: tile skeletons; a job in flight shows its placeholder tile with the web loader copy
(`web-media-ux.md §3.5 / §5.2 / §6.4`, verbatim) and `tabViewBottomAccessory` "still rendering" strip.

**إنشاء**: kind picker segmented `صورة / تعديل / فيديو / أغنية`; prompt field (same composer component);
per kind: image → shape override chips `مربّع 1024² / طولي 1024×1536 / عرضي 1536×1024`; edit → source picker
(photos or a library image); video → first-frame photo picker + duration slider 2–30 s (default from
`quota.seconds`, 10); song → `كلماتي` toggle (bypasses the author) + genre chips. No count control (every
route returns one). Submitting writes a user message into a chosen/new conversation and runs the
in-chat branch with `intent` forced, then jumps to that turn. Quota panel: images `used/limit/remaining`
from `POST /api/image/quota` (limit 8, Baghdad-midnight reset) in Arabic-Indic; video/music show the
window rule (6 clips / 10 songs per 2 h) and, after a 429 `rate_window`, `freesInMin`.

Guests: every create action opens the sign-up sheet with the web's four verbatim upsell texts. Failure
plates per kind from `web-media-ux.md §11`; never a cancel button.

### 7.12 In-chat media cards

Image ≤ 420 pt wide at natural ratio, radius 20 (`--soft-radius`, shared with the user bubble), loader
words verbatim, remaining-count toast when bytes decode; failure plate = sentence + one 44 pt button
(free reload first, then paid regenerate). Video 16:9 ≤ 520 pt with `AVPlayer`, save/share. Song =
full-width `surface` card: title, play/pause, scrubber, `elapsed/total` LTR, download, regenerate; only one
song audible at a time; pause TTS when a song starts.

### 7.13 Call screen

`fullScreenCover`, background = `callBackground` (radial accent 26 % / 30 % on `#14201D` for dark) with
`.ultraThinMaterial` at 0.35 over the *chat* (the web blurs the page 6 px behind it) so the conversation is
faintly present. Content, centred, max width 460:
- `فِراس` name (`Firas` in en), timer `MM:SS` LTR starting when the screen opens.
- **Orb** 176 pt: Metal/`TimelineView` shader or the CSS-fallback equivalent (three rings + core), states
  `is-listening` (breathes), `is-thinking` (slow inner swirl), `is-speaking` (level-driven bloom). No halo
  outside the circle (the owner removed it — rectangular blur edge artefact).
- Status line: `جارٍ الاتصال…` / `أستمع… تكلّم الآن` / `فِراس يفكّر…` / `فِراس يتحدّث…` / muted
  `الميكروفون مكتوم`. Caption (three-hop only): `اضغط الدائرة لمقاطعته` / `اضغط للتحدث` /
  `أستمع… اضغط عند الانتهاء` or the transcript (≤ 240 chars).
- Controls: `.floating` glass circles 56 pt in a `GlassEffectContainer(spacing: 20)`: mute (`mic.slash`,
  `كتم`), end (`phone.down.fill`, red `#E06A60` prominent, `إنهاء المكالمة`). Consent state: card
  `للتحدث في المكالمة، اسمح باستخدام الميكروفون` + `السماح بالميكروفون والبدء`, controls at 50 % opacity.
- Errors: `تعذّرت المكالمة — تأكد من إذن الميكروفون.` toast + close; guest cap spoken then closed:
  `عذرًا، بدون حساب المكالمة محدودة بـ {secs} ثانية — سجّل لتكمل بلا حدود`; `المكالمة الصوتية غير مدعومة…` only
  when no engine at all.
- Voice picker (Settings → الصوت): `cedar / ash / verse / echo / ballad`, toast
  `صوت المكالمة: {name} — يُطبَّق على المكالمة القادمة`.
- A call forces `auto` mode, `think=false`, caps tier to `pro` (never slows Mini); all restored at hang-up.
  `esc` and the end button both call `callEnd`; the teardown checklist in `web-voice-call-mic.md §2.1` is
  mandatory (stop every input track first).

### 7.14 Dictation overlay

Replaces the composer's row 2 in place (the field stays visible above): cancel (`xmark`, `إلغاء التسجيل`),
red dot, 32-bar waveform in `accent` (time-domain), status `micStatus`, timer `m:ss` (Arabic-Indic in
Arabic UI), dialect chip (🌐 + short label, tap → picker), done (`checkmark`, `إيقاف وتحويل`, prominent).
Composer gets a 1 pt accent ring while recording. Max 300 s → auto-finish; backgrounding → auto-finish.

Dialect picker (sheet, radio list, persisted `dictationLanguage`, default `auto`): `تلقائي — يتعرّف على لغتك من كلامك`,
`العربية الفصحى`, `عراقية`, `خليجية`, `مصرية`, `شامية`, `مغاربية`, `الإنجليزية`, `الفرنسية`, `التركية`, `الألمانية`,
`الإسبانية`, `الأردية`, `الفارسية` with the flags from the table in `web-voice-call-mic.md §7.2`. The existing
`DictationDialect` enum has only `automatic/arabic/english` — extend to the 14 keys.

Results **append** with one space, never replace, never auto-send. Strings: transcribing
`جارٍ تحويل كلامك…`, too short `التسجيل قصير جدًا — تكلّم ثم اضغط ✓.`, empty `لم أسمع كلامًا واضحًا — حاول مجددًا.`,
failed `تعذّر تحويل الصوت — حاول مرة أخرى.`, denied `اسمح بالوصول إلى المايكروفون من إعدادات المتصفح ثم أعد المحاولة.`
(native should say `من الإعدادات` **[edit]**), listening (on-device fallback) `جارٍ الاستماع… تكلّم الآن`.

### 7.15 Settings tree

`.sheet` (large detent; iPad 720 × 860), system glass, a **segmented header** with the five tabs
`الحساب / المظهر / المحادثة / الصوت / البيانات` (iPad: sidebar list instead). Grouped `List` with
`.scrollContentBackground(.hidden)` so the glass shows.

- **الحساب**: identity hero (avatar, name, email); members: plan card `الاشتراك` · `✦ مجاني بالكامل` ·
  `كل مزايا فِراس متاحة للجميع مجانًا. يحصل كل حساب على ٥٠٠ كريديت في Firas Agent تتجدد يوميًا.` (gold/diamond
  tokens exist but the card is neutral today), change email / password, danger zone (`dangerH`, `delBtn`,
  `delConfirmP`, `delFinal` — two-step, destructive red, `.error` haptic); guests: `أنت تتصفّح كضيف` +
  `أنشئ حسابًا مجانيًا`.
- **المظهر**: theme grid `الثيم` · `ستة أمزجة` — six 3-swatch tiles (ground/surface/accent) with the
  names, selection ring `accentRing`, `.selection` haptic, theme changes animate colours over 0.25 s
  (`withAnimation(.easeInOut(duration: 0.25))`) — no UI 2.0 switch natively (this brief *is* UI 2.0);
  `حجم النص` (`صغير / متوسط / كبير`), `عرض القراءة` (`عادي / عريض`), `الحركة` (`كاملة / مخفّفة`),
  `لغة الواجهة` (`العربية / English`, toast `تم تغيير لغة الواجهة ✓`).
- **المحادثة**: `النموذج الافتراضي` · `للمحادثات الجديدة` (same four rows as §7.4, toast
  `تم تعيين النموذج الافتراضي ✓`), `أسلوب الردّ`, switches `التفكير العميق` · `أبطأ وأدقّ في المسائل الصعبة`,
  `البحث في الويب` · `يبحث قبل كلّ ردّ`, `الإرسال بمفتاح Enter` · `و Shift+Enter لسطر جديد` (native:
  `و ⇧↩ لسطر جديد` on hardware keyboards; hide on iPhone without one), `شحذ الصور تلقائيًّا` (off).
- **الصوت**: `صوت المكالمة` (5 voices), `لهجة الإملاء` · `حين تُملي كلامك نصّاً` (14 dialects),
  `أصوات الواجهة` **[new]**.
- **البيانات**: export / import backup JSON (`exportBtn`, `importBtn`, `importConfirm`), clear device
  prefs (`clearBtn`, `clearConfirm`; guests `guestStorageSub`), About (version, `عرض آخر التحديثات` → §7.18),
  links `/terms`, `/privacy`.

### 7.16 Account, quotas and limit messages

No plan or quota in the account pill. Quota 429 bodies render as an assistant-styled message:
guest `انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير.` (+ sign-up sheet
after 200 ms); member `🚦 بلغت الحدّ اليومي من {name} ({lim}/يوم). يتجدّد تلقائيًا بعد منتصف الليل.\n\nفِراس مجاني
بالكامل — هذا السقف موجود ليبقى المحرّك متاحًا للجميع، وهو مرتفع لدرجة أن الاستخدام الطبيعي لا يبلغه.` with
`{name}` ∈ `رسائل فِراس AI / طلبات فِراس Code / مهام فِراس Agent / أسئلة فِراس Brain` and `{lim}` in
Arabic-Indic. Generic 429: `طلبات كثيرة بسرعة — انتظر لحظة ثم حاول مجددًا.` Toasts last 3.2 s, bottom,
`.floating` capsule above the composer, one optional button (`تراجع`, `إعادة المحاولة`, `أرسلها الآن`).

### 7.17 Onboarding and Auth

1. **Consent screen** (first run, Arabic only, full screen on ground, no glass): H1 `أهلًا بك في فِراس AI`,
   lede `منصّة ذكاء اصطناعي عربية أولًا من شركة مِنترونكس العراقية — مبنية للطلبة في العراق والعالم العربي.`,
   `أربعة منتجات بحساب واحد` with the four bullets, `ليش فِراس مختلف`, `أسئلة سريعة` (all verbatim in
   `web-chat-ux.md §1.1`), checkbox `أوافق على شروط الاستخدام وسياسة الخصوصية.` (never pre-ticked),
   `.glassProminent` `متابعة` disabled until ticked, note `قد يخطئ فِراس. تحقّق من المعلومات المهمة.`
2. **MentronX intro** (`MentronXEntryView` exists): monochrome line-drawn `M X` + `BY MentronX`, minimum
   3150 ms, 900 ms under reduced motion, cancelled in 80 ms on failure; plays on the two doors and on a
   returning launch while `/api/auth/me` runs.
3. **Landing**: mark + `Firas AI`, about text, primary `ابدأ الآن — بدون حساب` (guest session), secondary
   `لديك حساب؟ تسجيل الدخول`, hint `landingGuestHint`, the four-mark scale `AI — محادثة · Agent — مهام كبيرة ·
   Code — برمجة · Brain — وثائقك`, seven feature cards, image badge `تجريبي`. No fabricated counters.
4. **Auth**: email / password, Google (`GoogleOAuthProvider` exists), 6-digit code field, forgot / resend /
   back; errors `تعذّر الاتصال بالخادم. تحقّق من اتصالك.` / `تعذّر إتمام العملية. حاول مرة أخرى.`; cookie banner
   is a web artefact — omit. After sign-up from guest: migrate local chats, toast `تم نقل محادثاتك إلى حسابك ✓`.
   Guest exit: confirm `guestExitConfirm` then `DELETE /api/guest`.

Loading: the intro *is* the loading state; never show a spinner over it. Error: landing + toast.

### 7.18 Announcements

Bell in the drawer header with the 9 pt accent dot when unseen. Sheet (medium → large): title
`تحديثات Firas AI`, sub `آخر أخبار وتحديثات المنصّة.`, rows = thumbnail, badges `مثبّت` / `فيديو`, title, body
excerpt, date+time, chevron; opens a reader (full markdown, inline `AVPlayer` for video). Built-in launch
post `فِراس AI — منصة عربية واحدة، أربعة منتجات` (pinned, 2026-08-05, trailer `/media/firas-trailer.mp4`) merged
with `GET /api/announcements`, pinned first then newest. Opening stores the newest `ts` and clears the dot.
Empty: `لا توجد تحديثات بعد.` Loading: the sheet opens immediately with a spinner. No admin compose.

---

## 8. iPad addendum

- **Container**: `NavigationSplitView(columnVisibility:)` with `.balanced` style; sidebar 270–360 pt (as
  coded); on iPadOS 26 the sidebar floats as glass automatically — apply `backgroundExtensionEffect()` to
  the detail's background so the conversation continues under it. Do not treat `.regular` width as
  "iPad": iPadOS 26 windows resize freely; layout on `horizontalSizeClass` and re-evaluate on change
  (the existing shell already switches on size class).
- **Chat**: reading column centred at 760 / 980 pt; composer the same width; toolbar principal tier pill;
  `⌘N` new chat, `⌘⇧O` open drawer toggle, `⌘K` search conversations (focuses the drawer field), `⌘↩` send,
  `esc` stop, `⌘⇧C` copy last answer, `⌘,` settings, `⌘1…⌘5` products, `⌘⇧M` start a call. Pointer:
  `.hoverEffect(.highlight)` on list rows, `.hoverEffect(.lift)` on chips and message action buttons;
  message action row is hover-revealed at 55 % → 100 % opacity like UI 2.0.
- **Code**: three columns — files 200 pt (collapsible), editor `1.1fr`, right pane `1fr` with a top
  segmented `المعاينة / الطرفية / المساعد`. Editor supports hardware keyboard fully; the diff review is a
  trailing inspector (`.inspector(isPresented:)`) instead of a sheet.
- **Brain**: three columns — sources (the library, persistent, 280 pt), ask thread (centre), passage reader
  as an inspector on the trailing edge; compare mode = two answer columns in the centre.
- **Media Studio**: library grid 5 columns; the create form as a trailing inspector (`.inspector`) so the
  grid stays visible.
- **Agent**: mission card at full column width (up to 980 pt); plan and activity side-by-side in two
  columns when ≥ 900 pt.
- **Sheets**: settings 720 × 860 centred (`.presentationSizing(.form)` iOS 18+); model picker as a
  popover from the tier pill (`.popover` with `.presentationCompactAdaptation(.sheet)` for compact).
- **Drag and drop**: files and images dropped onto the chat or composer attach (`.dropDestination(for: Data.self)`),
  text drops insert; dragging a message's code block out yields a file.
- **Multitasking**: Stage Manager windows down to 320 pt collapse to the iPhone layout; the call screen
  is a `fullScreenCover` in its window only.

---

## 9. Reconciliation with the existing Swift (what to change, file by file)

| File | Keep | Change |
|---|---|---|
| `DesignSystem/FirasTheme.swift` | all six palettes (exact), `PreferencesStore` defaults, keys | add `accentSoft`, `accentRing`, `glassTint`, `glassWash`, `glassStroke`, `userFill`, `userInk`, `userEdge`, `maxTier*`, `callBackground` derivations (§6.2); extend `DictationDialect` to the 14 keys; add `uiSoundsEnabled` |
| `DesignSystem/GlassSurface.swift` | structure, fallback branch, `GlassIconButton`, `FirasBackground` | replace `tintStrength` with `level: FirasGlass.Level` (`.floating` = `Glass.clear` + wash + 0.5 pt stroke; `.sheet` = `Glass.regular`); iOS 18 fallback per §2.3; drop the 0.9-alpha border on iOS 26 |
| `DesignSystem/FirasCompletionCue.swift` | history, foreground and Reduce Motion guards, two-pulse pattern | reveal delay `3 s → 140 ms` (§5.3) |
| `DesignSystem/FirasActivityLabel.swift` | sweep, reduced-motion static text | under reduced motion use the 1.5 s opacity pulse instead of static text (busy must keep reporting) |
| `Features/Shell/FirasAppShell.swift` | size-class switch, fixed-LTR root, overlay drawer geometry | drawer becomes `.floating` glass with edge-swipe + momentum; add Media Studio to `ProductKind` (or a parallel `ShellDestination`) |
| `Features/Chat/ChatComposer.swift` | two-row layout, `ViewThatFits`, badge on `+` | radius 24, add mode pill, mic, call, dictation overlay, length meter, tray, attach limits and toasts |
| `Features/Chat/ModelSelectionSheet.swift` | content entrance `.snappy(0.42)`, two cards | remove `.presentationBackground(palette.background)` on iOS 26 (kills glass); remove the sheet-level RTL `layoutDirection` (§4.3 item 6); Max/Ultra badges and colours |
| `Features/Chat/VoiceCallView.swift` | — | conform to §7.13 phases/strings, orb 176 pt, no halo, controls in a `GlassEffectContainer` |

---

## 10. Open questions for the owner

1. Media Studio is native-only: confirm the fifth product name `الاستوديو` and whether it appears in the
   product switcher or only from the gallery button.
2. Camera capture in the Add sheet: the web has no camera path (the OS picker decides). Confirm a native
   `الكاميرا` entry is wanted.
3. Keyboard-shortcut map (§8) is proposed; the web only defines desktop-specific ones (`kmTab`).
4. `Glass.clear` on the `light` theme is nearly invisible over the cream ground; the brief compensates
   with a black 0.025 wash and a 0.08 stroke — confirm that reads as "glass" enough on light, or allow
   `.regular` for light only.
5. UI sounds (`أصوات الواجهة`) are new; default off — confirm.
