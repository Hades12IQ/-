# Native Code repair and security findings

Scope: the native iOS release based on `ios-latest` (`72ef8bd`), plus a read-only inspection of the existing chat-job server contract. No production database, server or web bundle was modified. This is a source audit with executable simulator regression checks, not a completed penetration test.

## Findings fixed

| Priority | Trigger and impact | Change / source |
| --- | --- | --- |
| P1 privacy | Code projects, thread messages and the offline index used a shared cache namespace. Switching account on one device could expose the previous identity's cached project data. | `Stores/CodeProjectCache.swift`: every project/thread/index operation now requires an owner and uses a SHA-256 owner namespace. `CodeStore.identityDidChange` clears visible state immediately; asynchronous operations check owner and project after suspension. |
| P1 privacy | A project named `..`, `.`, or `../` passed `CodeExport.folderName`. ZIP staging could resolve to the parent temporary directory and include unrelated temporary files. | `Features/Code/CodeExport.swift:32`: dot-directory names now resolve to `project`. Generated source and preview exports use complete file protection. |
| P2 privacy | Automatic repository context could read and forward `.env`, signing keys and service-account files to a model. | `CodeEngineeringGuidance.isSensitivePath` filters common credential paths before automatic reads; private-key bodies are also excluded from model context. These filters do not claim to detect every possible secret in arbitrary source. |
| P2 integrity | Changing project/account while an AI call or cache read was awaiting could apply the previous project's reply or files to the newly open session. | `CodeStore.ask`, `repositoryContext`, `open`, `save` and background landing capture identity/project and recheck after suspension. Explicit sign-out hands work to the old account's queue before credentials change; unexpected identity loss retains owned build tickets without submitting them as the next account. |
| P2 data loss | Saving/build completion used `shrunkToFit`, cutting files at 60,000 characters and repeatedly deleting 20% of the largest file until the project fit the cloud cap. Valid source could become broken code without an error. | The shrinking loop is removed. The complete project is cached and remains exportable. Cloud limits produce a clear local-only message. Cache write failure now prevents a successful landing acknowledgement. |
| P2 functionality | Native, CLI, backend and other software briefs could be converted to an HTML website, especially after the app moved a foreground build to the old specialized worker. | Runtime detection, planner/editor guidance and fallback manifests now cover native apps, CLI, services, libraries, data and configuration. `CodeBuildHandoff` uses the existing generic durable worker for nonbrowser builds. |
| P2 data loss | A syntactically valid but incomplete project array could overwrite completed foreground source and be announced as done. | Persisted `plannedPaths` and `completedPaths`, strict fence/JSON decoding, path checks and required nonempty files gate terminal landing. Failed/partial jobs do not replace the project. Completed checkpoint source is merged unchanged, including files omitted from model context for privacy or size. |
| P3 correctness | Preview reload signatures used only file paths and byte lengths, so an edit such as `red` → `tan` could leave the old preview visible. | `PreviewWebView.signature` includes file contents and project identity. |
| P2 navigation | Generated preview scripts could request an HTTP(S) navigation and open Safari without the user tapping a link. | `PreviewWebView` now opens external URLs only for `.linkActivated` navigation; programmatic redirects remain cancelled inside the preview. |

The Code conversation also uses stable turn identities, Chat-style user bubbles, unboxed assistant responses, a smooth latest-message arrow and keyboard dismissal on send. Its existing composer styling is preserved. Shared native word selection and “Ask Firas” provide a quoted composer context without treating the quoted passage as an edit instruction.

## Compatibility and legacy data

Legacy `CodeProjects/*.json` files are kept untouched. They contain no reliable owner, so the app does not assign them to whichever account signs in next. A successful authorized project fetch writes the server's canonical project into the current owner's namespace. Older unowned, local-only guest projects are preserved on disk but cannot safely be shown automatically without a separate owner-confirmed recovery flow.

Existing tickets decode with empty plan/completion arrays. Owner IDs and queue `cid` values retain their existing meaning. No migration deletes server projects or local legacy files.

## Verified durable handoff contract

The inspected `server.mjs` worker dispatches `codebuild` to `runCodeBuildJob` and ordinary `chat` to `handleChat` using the stored request body. `handleChat` accepts the submitted system/user messages. The native `ChatJobDriver` polls the same `/api/chat/job?id=…` endpoint for both, while `JobManager.startChatQueueJob` retains the local pointer's kind. The contract is also recorded in `server-chat-jobs-chats.md` and `server-code-brainask.md`.

`CodeBuildHandoff.request` therefore uses:

- Wire `kind: "chat"` for native/software requests, and for requests exceeding the specialized worker's 8,000-character task budget.
- Local `JobPointer.kind: .codebuild`, so progress and completion return to Code rather than creating a Chat reply.
- The same owner and idempotent `cid`; `chatId: ""`, so raw project JSON is never appended by the worker as an ordinary visible chat message.
- `tier: ultra`, `nomem: true`, `nokb: true`, matching internal Code helper behavior and avoiding personal memory in generated source.
- Original request, attached text, persisted manifest, and complete finished source files within the context budget. Source files are never sliced to fit this prompt. Omitted completed files remain authoritative on disk and are merged unchanged at landing.

The result must decode as a complete `firas-project` JSON fence and satisfy the persisted manifest. An invalid result leaves prior source intact and produces a failed-build message. This uses an existing queue route; no backend deployment is required for the native routing fix.

## Backend follow-up proposal

The generic queue is one model response, so exceptionally large projects can exceed a model's output budget. Such a response is rejected instead of being saved as a partial project. For reliable larger projects, extend the specialized durable worker to accept a requested runtime plus a persisted manifest, write each file as a checkpoint, resume unfinished files after restart, and emit a final manifest with content hashes. Keep the existing owner authorization, `cid` idempotency, terminal-DB-over-memory precedence and stop-versus-leave behavior.

The native app edits and exports source and previews browser HTML. It does not currently install dependencies, execute arbitrary commands, compile native apps or run generated tests. Stronger instructions are not model training. A future execution tool needs a genuine isolated server runner, explicit resource limits, protected credentials and recorded command/test results before the assistant may report a successful build. This repair does not invent such capabilities or deploy a runner.

Foreground builds still use the existing ticket-to-queue handoff architecture. Ordinary backgrounding submits the durable request. If iOS kills the app before that request reaches the server and network delivery never occurred, the persisted ticket can be resumed on the next launch; no client code can promise server execution before acceptance.

## Validation

`Features/Code/CodeReliabilityChecks.swift` runs inside the DEBUG simulator smoke app using the actual request builders, parser, models and protected cache. It checks worker/pointer routing, runtime selection, malformed/truncated JSON rejection, missing/empty planned files, preservation of completed source, owner isolation for projects/threads/indexes, complete oversized-source round trips, common credential filters and unsafe ZIP names. It makes no external model request and charges no account.

Windows checks: changed Swift syntax parsed with `tree-sitter-swift`; `git diff --check` passed. Xcode compilation and simulator results are supplied by the GitHub Actions run for the final commit. A live generated native/CLI project, device scroll/keyboard behavior, revoked-account transitions and signing must still be judged from their actual run results; the source checks alone do not prove those interactions.
