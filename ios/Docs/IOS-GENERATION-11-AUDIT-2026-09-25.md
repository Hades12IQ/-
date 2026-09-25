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

## Implementation delivered for verification

Native source commit: `45832b25c444e883d127259f48406adb30f29e92` on `codex/ios-generation-11-20260925`.

- Generation 1.1 is carried on Chat, Code, Brain and Omnix requests and saved with answers, alternatives and retries. New preferences choose 1.1; historical messages retain their original generation. Agent retains its existing server-managed Manus contract.
- Native model pickers and default-model settings expose current and previous generations without replacing the app's visual theme.
- Chat and Code retain real tool steps through streaming, background-job recovery and history. Omnix interleaves speech and tool events, uses the website's action vocabulary, and distinguishes dispatched sub-tasks from confirmed completion.
- HTML workspace projects use a private multi-file preview with local CSS, JavaScript, images and fonts. The preview has no authenticated cookies or native bridge. Publishing remains server-owned and uses existing confirmed receipts and links. Existing GitHub account/repository linking is retained.
- Account skills can be imported by URL. Multiple green inline skill tokens and the existing library remain available. `/prompteng` provides Arabic/English output, streaming, Stop, a deadline and restoration of the original request when no output arrived. Draft epochs and account identity prevent a response from writing into a different conversation.
- The native semantic router uses the website's pinned `router:true, nomem:true` helper contract and shipping instruction, with a bounded timeout and the established native fallback. It does not call `/api/intent`. Current-generation Omnix receives a confirmed `kind` for its conversational fast path; work retains durable receipt reconciliation.
- Server-owned long-answer continuation is retained. No duplicate client continuation or replay of a publishing submission was added.

## Verification boundaries

Build 102 passed the native simulator stage and produced passing modern and forced-legacy gallery reports; its model-picker screenshot was inspected. It was superseded before publishing. Final build 104 also passed the complete simulator stage with the later semantic Chat routing, Code step persistence and prompt-draft lifecycle changes included. Both normal and compatibility smoke reports have `status: passed` and no errors; both native galleries passed. Its actual model-picker screenshot was inspected.

The complete build-104 evidence archive was downloaded and locally CRC-verified. The independent final-PDF inspection found all 200 problem/solution labels and integral symbols across 32 pages, no fully clipped characters, no characters outside the printable margin tolerance, no missing/out-of-order entries and no blank trailing page. The generated-image viewer close action and native word selection also passed their existing regressions. These are deterministic simulator fixtures, not claims about a model's mathematical correctness or real-server response latency.

The Windows host cannot run Xcode. CI uses an iOS 26.4.1 Simulator; the forced-legacy gallery exercises compatibility branches on that runtime, **not an actual iOS 15 device**. The deployment target remains iOS 15. Authenticated live account imports, model calls and real publishing were not exercised from the guest browser. No measured production-latency improvement is claimed.

Private previews support built/static HTML projects with up to 64 eligible files and 20 MB. External network resources are blocked in that private preview; projects requiring a build or a live backend still require their published preview or downloadable sources.

## Verified release

- GitHub Actions [run 104](https://github.com/Hades12IQ/-/actions/runs/36096185265) completed successfully, including the Release device build and publication.
- [Download the unsigned IPA](https://github.com/Hades12IQ/-/releases/download/ios-build-104/FirasAI-unsigned.ipa). Release source is exactly `45832b25c444e883d127259f48406adb30f29e92`.
- The complete 12,615,654-byte IPA was downloaded locally. Every ZIP entry passed CRC verification; its local SHA-256 matches both the published checksum and GitHub's asset digest: `a5b24d9bdc25237bb3f7c7d3ff9c3e8d0e75cca8ac84b4348e38c42857ba7d58`.
- Package metadata confirms bundle `org.firasai.FirasAI`, build `104`, minimum iOS `15.0`, a native ARM64 executable, bundled document fonts and no signature/provisioning profile. The owner must sign it before installation.
- Published normal/compatibility smoke reports, final-PDF inspection and both native galleries all passed with no reported errors. Local verification record: `D:/tmp/firas-ios-qa/run104/verified.json`.

The live-account and runtime limitations above remain applicable; successful fixture tests are not represented as a real authenticated publishing run.
