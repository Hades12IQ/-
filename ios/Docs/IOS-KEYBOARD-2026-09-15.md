# Skills composer keyboard regression

The owner reported that typing `/`, choosing a skill, or typing after choosing a skill dismissed the keyboard in build 97.

## Change

The attributed UIKit editor now receives an ordinary editing-state binding owned by each composer. Chat, Agent, both Code composers, and Brain use the same bridge. SwiftUI `FocusState` is retained for native SwiftUI text fields, where it has a `.focused` target. The skill editor has no such SwiftUI target and must track UIKit's begin/end editing events instead.

Queued focus updates resolve the current binding after layout rather than applying a snapshot captured before a user's tap or keystroke. The bridge coalesces pending focus updates and disconnects callbacks when dismantled. The focus command remains a view dependency so explicit dismissal still updates the editor.

No colors, dimensions, fonts, menus, skill limits, request routing, or model settings were changed.

## Regression check

The existing mounted production composer check now starts the real UITextView as first responder. It asserts the editor instance and first responder survive:

- Opening the slash picker and selecting three skills through the pick action used by Return.
- Separate Latin, Arabic, emoji and space keystrokes after each selection.
- Inserting a collapsed long-paste card without losing its full text.

A UITextView end-editing observer also detects transient keyboard dismissals, not just the final state. The check exercises both an explicit composer focus command and the application's outside-tap dismissal action, and verifies editing can resume. Its fixture owns ordinary SwiftUI state just as the production composers do.

The regression invokes the real skill pick callback through the editor delegate. It is not a physical finger-tap test.

## Verified simulator evidence

Source: `f2d166086a00042e3f081ceb54f7ced172184bae`; [build 99](https://github.com/Hades12IQ/-/actions/runs/34902316180).

- Both reliability reports passed with empty error arrays, including the new first-responder assertions. Runtime: iOS Simulator 26.4.1, in normal and forced-legacy UI modes.
- Both eight-screen native galleries passed. The two skill-composer PNGs are byte-for-byte identical to their build-97 counterparts, confirming the visual design was preserved. The normal capture was also inspected.
- Existing document checks passed, including the independent 200-integral PDF audit, with no clipped or out-of-margin characters.
- The local bundled math/chemistry and document-runtime audit passed before shipping the changes to CI.

These are simulator and forced compatibility-path checks, not tests on a physical iPhone or an actual iOS 15 runtime.

## Published release

[Build 99 IPA](https://github.com/Hades12IQ/-/releases/download/ios-build-99/FirasAI-unsigned.ipa) was downloaded and independently verified after the workflow succeeded. The release targets the exact tested source commit above.

- SHA-256: `91b36e56855e0b6ab3d75df7b83cbb3a19606fbcafe0d8e4ba7ce143f858bc6a`; matches the published checksum.
- Size: 12,459,547 bytes. ZIP CRC passed; native ARM64 executable, bundle `org.firasai.FirasAI`, build `99`, minimum iOS `15.0`.
- Unsigned, with no embedded provisioning profile or signature directory; requires the owner's usual signing step.
- Downloaded release evidence again passed both reliability reports and both galleries. Arabic and multilingual document fonts remain bundled.
