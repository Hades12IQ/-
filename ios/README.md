# Firas AI for iPhone and iPad

Native SwiftUI client for the Firas AI backend.

## Requirements

- macOS with Xcode 26 or newer
- iOS / iPadOS 18 or newer
- The production API at `https://firasai.org` or a local Firas AI server

## Run

1. Open `FirasAI.xcodeproj` in Xcode.
2. Select the `FirasAI` scheme and an iPhone or iPad simulator.
3. Build and run.

The default API base URL is declared in `FirasAI/Resources/Info.plist` under
`FIRAS_API_BASE_URL`. Keep production on HTTPS. Local HTTP development is allowed only for
local networking by the app's ATS configuration.

## Architecture

- SwiftUI + Observation for UI state.
- An actor-isolated API client owns the shared `URLSession` and cookie session.
- Durable chat and agent work starts server-side and is polled without cancelling when a view
  disappears. Only the explicit Stop action calls the cancel endpoint.
- Image, cover, video, and music creation lives inside Firas Chat's `+` sheet and uses the
  production `/api/image/job`, `/api/video/job`, and `/api/music/job` durable-job routes.
- Terminal jobs route back into the correct Chat/Agent/Code/Brain surface through APNs, with the
  bundled `FirasComplete.wav` sound and a foreground completion haptic before the final reveal.
- The six web themes are mirrored as native design tokens and stored per device, matching the
  website's current local-only preference model.
- Native Liquid Glass is used on iOS 26+, with material fallbacks on iOS 18–25.

No web source file is changed by this project.
