# Plan — `Features/Brain/` (Batch 1; 2 owners: Store+Asker+Screen+Thread · Import pipeline+Extractors+Library; also `Localization/Strings+Brain.swift`)

Interfaces: `INTERFACES.md` → `BrainScreen`, `BrainStore`, `BrainAsker`. Design: `design-brief.md
§7.10, §8`. Delete `BrainStrings.swift`, `Brain.xcstrings`. Keep both extractors (fix).

| File | Purpose | Behaviour | Read |
|---|---|---|---|
| `Features/Brain/BrainScreen.swift` (rewrite) | the Brain product | Ask thread (`ChatScreen` shell with `brainNb` conversations), `SourceChipsRow` above the composer, composer chips (scope/summarize/compare), library button (sheet on iPhone, persistent 280 pt column on iPad), passage reader as trailing inspector on iPad; guests allowed (3 docs / 120 pages) with the quota line; `brain_whole` upsell for guests. | `web-brain-ux.md §5.2, §5.2a, §10, §14`, `design-brief.md §7.10, §8` |
| `Features/Brain/BrainLibrarySheet.swift` | library | Hero, add (Files picker: pdf/docx/pptx/xlsx/txt/md/images), rows with kind/pages/OCR badge/phase progress + Stop, pin/exclude toggles (pinned rows ignore taps), OCR toggle, quota line, error banners; delete with confirm. | `web-brain-ux.md §5.1–5.3, §6.4`, `server-brain.md §5, §7` |
| `Features/Brain/BrainThreadView.swift` | thread rendering | Pending notices (`Strings.Brain` pending copy), streamed answer via `BrainAnswerView`, stopped/failed states (append `engineFail`, never replace), copy bar. | `web-brain-ux.md §5.2a, §7.8–7.9, §11.3` |
| `Features/Brain/BrainAnswerView.swift` | answer + citations | `MarkdownView` with `[Sn]` replaced by `CitationChip`s (custom attribute → tap → passage), `SourcesCard`, two-column compare layout when the answer splits. | `web-brain-ux.md §11.1–11.2, §7.7` |
| `Features/Brain/SourceChipsRow.swift` | scope chips | Active/pinned doc chips, range chip (drops when selection changes), compare chip, `المصادر` button. | `web-brain-ux.md §10` |
| `Features/Brain/CitationChip.swift` | `[Sn]` capsule | Accent-soft capsule, LTR digits. | `web-brain-ux.md §11.1` |
| `Features/Brain/PassageReaderSheet.swift` (keep `BrainPassageSheet` pieces) | passage | before/hit/after with highlight, `فتح المصدر`, copy, deleted-source fallback (`s` then `gone`). | `web-brain-ux.md §11.4`, `server-brain.md §9` |
| `Features/Brain/BrainImportPipeline.swift` | extraction orchestration | Kind detection → extractor → OCR rule (Vision on-device first; server vision only when < 20 chars on an inked page, within `visionLeft`, even stride, 300/doc cap, 2–3 concurrent) → `splitParts` (700 000 chars / 1 000 records, groups intact) → sequential POST with `ocr` on part 1 only (server-vision pages only) → progress `reading/ocr/uploading`; cancel; `BackgroundHold` around upload; zero text → `noText`. | `web-brain-ux.md §6, §15.1`, `server-brain.md §6.1–6.9` |
| `Features/Brain/BrainDocumentExtractor.swift` (keep, fix) | PDF/images/text | PDFKit text with line reassembly quality gate, Vision `.accurate` `["ar","en-US"]` at 2 200 px, 3 000-char blocks unit `page`, 1256 decoding for legacy text, O(n) chunking, language guard. | `audit-ios-brain-media.md §B.2, §C`, `web-brain-ux.md §6.2, §17` |
| `Features/Brain/OfficeDocumentExtractor.swift` (keep, fix) | docx/pptx/xlsx via ZIPFoundation | Selective entry extraction, rels-ordered slides/sheets, headings + 4 000-char sentence-aware sections, notes, placeholders dropped, shared-string runs, date styles, 700-char row groups with repeated header. | `web-brain-ux.md §6.2`, `audit-ios-brain-media.md §B.2` |

Strings: `Strings.Brain` = the `brainT()` table verbatim (`web-brain-ux.md §5.1, Appendix A`,
`server-brain.md §15`). Error → copy per `web-brain-ux.md §8`, `server-brain.md §14.7`.
Rules: the answer pipeline is `BrainAsker` (Stores); this folder never calls the API except through
`BrainStore`; one `cid` per turn; `ocr` counts server-vision pages only.
