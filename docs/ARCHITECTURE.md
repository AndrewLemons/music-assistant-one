# Architecture

- `Core`: independently testable Swift package. JSON wire values, server address validation, media/player/queue projections, and an actor-isolated WebSocket client. No UI or audio dependencies.
- `App/AppModel.swift`: main-actor observable state and user actions. Owns authentication lifecycle, selected output, library/search, event coalescing, and reconnect backoff.
- `App/Services`: Keychain credentials, Bonjour discovery, Sendspin transport/local audio, and Apple system media controls.
- `App/Views`: platform-adaptive SwiftUI views. Network commands flow through AppModel; server updates determine playback state.
- `project.yml`: XcodeGen source of truth. The generated Xcode project and package resolution are committed for normal Xcode use.

A single app-scoped model shares connection and audio ownership across windows. The network actor owns one receive loop, request continuations, per-request deadlines, partial-result accumulation, and socket generation guards. Cancellation/disconnect resolve outstanding requests. Event bursts coalesce before reading the authoritative active queue. Reconnect backs off up to 30 seconds; it never replays queued transport commands.

Local audio is opt-in. One Keychain SendspinDevice and at most one SendspinClient are alive per app process. Disconnection closes both audio and transport ownership. Account credentials and Sendspin pairing identity use separate Keychain namespaces. The server API and audio transport use platform certificate validation.

Tests exercise the control protocol against an independent local WebSocket fixture, not mocks of the Swift implementation. UI automation uses an explicit `--demo` launch argument with clearly labeled synthetic content and disabled network playback. `--onboarding` forces first-run UI without erasing stored credentials.
