# iPhone account skills and pasted text

Published source: `b8ee85f7a979d5db9b963ad013f9b427df760264`.
Build: [97](https://github.com/Hades12IQ/-/actions/runs/34895258931).
Status: build 97 succeeded, was published, and the downloaded IPA and evidence were independently verified.

## Behavior

- Settings has a native Skills page, search, account skills, create/edit, enable/disable, delete and the website's library. It uses the existing account-authenticated `/api/skills` service. No separate catalogue is shipped in the app; library entries can be reviewed and edited before saving to the account.
- Chat, Agent, both Code composers and Brain share the caret-aware slash picker. Up to three enabled skills can be selected. Names are ordinary editable text, highlighted with the existing sage accent. Changing or deleting a name removes its binding. URLs, file paths, inline code and fenced code do not trigger the picker.
- Selected IDs travel with normal chat requests. The existing durable and Omnix job routes also receive the selected rules as user guidance because those runners do not forward IDs to `handleChat`. Internal title/search helpers are excluded; document/code authoring opts in. Selection belongs to the send task, not a global current selection.
- A paste of at least 1,600 UTF-16 units or 20 newlines becomes a document card. Tapping it opens the complete selectable text; its remove control removes the staged card. Chat, Agent and Code use their attachment path; Brain combines the original text with its question at send time. The clipboard is read only for an explicit paste action.
- Cards preserve the original UTF-8 bytes and do not silently shorten a paste. Oversized pastes are refused with a localized explanation and remain on the clipboard. Existing product-specific input and attachment budgets still apply. A card does not increase the downstream model's context window or remove the Agent/Code attachment processing limits.
- Brain checks the complete question including selected skill guidance against the whole-read endpoint's 4,000-unit cap. An oversized request uses its existing retrieval/answer path, whose final model request carries the full question, instead of silently losing the end of the question or skill rules. Source retrieval itself retains the service's existing search-query limit.
- Omnix foreground polling is one second, matching the website, with ten-second background polling unchanged. Independent account-access and cloud-readiness reads start together. Standard model responses retain the existing immediate received-chunk presentation; model reasoning settings and provider selection are unchanged. This is an app-side latency change, not evidence of faster upstream generation.

## Verification

- Build 97 passed both reliability runs with empty error arrays on iOS Simulator **26.4.1**, in normal and forced-legacy UI modes. Both eight-screen native galleries passed. The explicit UIKit paste and green-text-after-caret-change assertions passed in both runs.
- Inspected the final normal and compatibility skill composer captures: selected names are sage text, ordinary prompt text keeps its normal color, and the pasted document has its own bounded paper card and remove control. Gallery content uses fixture data.
- The independent PDF check passed with **200 numbered integrals across 32 pages**, no clipped or out-of-margin characters, and no blank trailing page. Existing live math, persisted math, file-preview, media-dismissal and transcript checks also passed.
- Local bundled renderer audit passed: 15 math/chemistry cases, five delimiter cases and six font/RAF-settling cases.
- Build 93 compiled and completed the existing document/math checks, but failed the new native editor check because the fixture controller had not been mounted. The test now mounts the production composer in the foreground view hierarchy before inspecting it.
- Builds 95/96 exposed a Swift constraint-solver failure in an optional paste-handler method reference. The callback now uses an explicit typed closure and the composer is split into separate view expressions. The paste strip also has a bounded height so it cannot expand the composer into the conversation.
- The native checks exercise skill CRUD and library response decoding through an isolated URL protocol, disabled selections, account changes, three-skill limits, caret/range behavior with Arabic and emoji, per-product request bodies and task-local cleanup.
- The mounted editor check inspects foreground attributes after moving the caret, verifies skill names are text rather than attachments, performs an actual UIKit paste, and checks the complete pasted text reaches Chat's attachment fold.
- Native gallery captures include Settings/Skills, the library and the shared slash/paste composer, using labeled fixture accounts. They are simulator captures, not recordings of the owner's production account.
- The production website was checked read-only in a guest session. Authenticated live skill CRUD was not exercised. No production account skills or website source were modified.

## Release verification

- [Verified IPA, build 97](https://github.com/Hades12IQ/-/releases/download/ios-build-97/FirasAI-unsigned.ipa)
- [Simulator evidence](https://github.com/Hades12IQ/-/releases/download/ios-build-97/FirasAI-smoke-evidence.zip)
- Downloaded archive CRC passed; the published and calculated SHA-256 match: `63d5cd7a733413e733017f5b305629b824216035a57da95296ca5cb8a05715af`.
- Size: 12,458,419 bytes. Bundle: `org.firasai.FirasAI`, build `97`, native ARM64, minimum iOS `15.0`.
- No signing profile or code-signature directory was present. The owner signs this unsigned IPA as usual.
- Bundled Arabic and multilingual document fonts were present. Both reliability reports and both galleries in the downloaded release evidence passed. The release targets the exact tested source commit above.

Compatibility paths are exercised on the available simulator using the existing forced-legacy switch. This does not constitute an actual iOS 15 device test. The app's deployment minimum remains iOS 15.
