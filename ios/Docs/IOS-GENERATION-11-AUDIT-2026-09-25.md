# Website → native iOS audit, 25 September 2026

Baseline: native build 99 (`f2d1660`, documentation HEAD `2f8c486`).
Target: the current website working tree, verified against the public model picker at firasai.org. Source snapshots and SHA-256 manifest are retained in `D:/tmp/firas-ios-qa/generation11-audit/`. The website working tree is under active development; it is not to be overwritten or deployed by this app change.

## Findings before implementation

| Area | Website contract | Native gap / required work |
| --- | --- | --- |
| Model generations | `mini/pro/ultra/max` plus `mgen: "1.1"`; old requests omit generation. New selection defaults to 1.1; old history stays generation 1. | Current native requests omit generation entirely. Add explicit selection, snapshots, persistence, retry/version metadata and a separate previous-generation section. A label-only change would still run generation 1. |
| Capabilities | Generation 1.1 enables tools, skills and execution steps. Nova deep thinking excludes tools. Omnix manages its own effort. | Centralize native capability projection and preserve server authority. Do not transplant provider/model names into the app. |
| Execution display | `step` frames update rows by stable ID, retain start offsets and `say`, and persist with the answer and its alternatives. | Decode, merge and retain steps across streaming, polling, reload and answer versions. Render real events, not invented progress. |
| Omnix 1.1 | Generation travels on `/api/omnix/runs`. Classified plain chat can take the fast path; work uses the durable workspace. | Submission currently has neither `mgen` nor `kind`. Preserve request-key reconciliation, owner binding, cancellation and no-replay behavior. |
| Omnix timeline | `timelineVersion: 1`, speech/tool events, dropped-speech fallback, delegation outcomes and confirmed child identities. | Existing UI groups raw tool titles in one disclosure above the answer. It does not weave speech/events or expose child outcomes. |
| Website preview | Private HTML projects resolve CSS, scripts, images and fonts from authorized workspace inventory, inside an isolated preview. | Current Omnix file viewer uses Quick Look for every file. HTML alone is insufficient for multi-file projects. Preview must not inherit authenticated cookies or publish private files. |
| Publishing | `publish_site` and `publish_to_github` run server-side; actual receipts distinguish success, failure and unknown outcome. | Allow the 1.1 worker path and display confirmed links/results. Opening a preview is not permission to publish; reconnect must not replay publishing. |
| File delivery | Partial files remain downloadable; thumbnails are lazy; updated workspace identity prevents opening an overwritten file as an older result. | Preserve authenticated downloads and ownership checks; improve native preview and file presentation without discarding partial output. |
| Skills | Account CRUD/library already present; website now imports a skill through `POST /api/skills/import {url}`. | Add import with localized server error codes, retaining library and multiple editable green tokens. |
| Prompt engineering | `/prompteng`, Arabic/English choice, helper request `promptEng:true, nomem:true`, streaming draft replacement, 60-second deadline, stop and original restoration on no output. | Missing in native. Share behavior across composers and retain build-99 keyboard focus fix. |
| Intent | Server has `/api/intent` with bounded history, attachment context and structured decision. Website router helpers use the pinned router. | Native deterministic routing is older. Integrate actual contract, retain safe fallback and never promote an unconfirmed classification to a destructive action. |
| Long answers | Server continues truncated answers inside the same stream/job; output budgets recover at the provider ceiling. | Do not add a duplicate client replay. Keep server-owned completion, visible partial results and resume semantics. |
| Other surfaces | Code model/depth controls, in-chat code preview, saved snippets/conversations, Brain sources, Agent jobs, settings/Telegram. | Review existing native equivalents separately; do not mistake an existing native feature for missing functionality or transplant web-only layout. |

## Evidence so far

- Read-only live UI: new generation picker confirmed, including Omnix 1.1, four tiers, previous-generation group, Auto/Plan. Browser is a guest; authenticated account-only workflows have not been exercised live.
- 78 source-contract tests passed: model generation, Omnix generation, work-step capture, publishing receipt behavior and private-preview path resolution.
- These are website contract checks, **not** a claim that the iPhone update has been implemented or tested.
- Native simulator/build verification is still required. Local host is Windows; macOS CI supplies Xcode and Simulator.

## Delivery gates

Keep iOS 15 compatibility and native theme; prove old history is not relabelled; prove generation follows each request and alternative; exercise start/update/fail/unknown step states; verify private multi-file preview and account change cleanup; test keyboard focus during slash selection and prompt editing; run native smoke checks and archive only after those pass. No release is considered complete before the produced IPA and build evidence are checked.
