# Architecture

- `Core`: independently testable Swift package. JSON wire values, server address validation, media/player/queue projections, and an actor-isolated WebSocket client. No UI or audio dependencies.
- `App/AppModel.swift`: main-actor observable state and user actions. Owns authentication lifecycle, selected output, library/search, event coalescing, and reconnect backoff.
- `App/Services`: Keychain credentials, Bonjour discovery, independent AVQueuePlayer audio, background downloads, Sendspin transport, and Apple system media controls.
- `App/Views`: platform-adaptive SwiftUI views. Network commands flow through AppModel; server updates determine playback state.
- `project.yml`: XcodeGen source of truth. The generated Xcode project and package resolution are committed for normal Xcode use.

A single app-scoped model shares connection and audio ownership across windows. The network actor owns one receive loop, request continuations, per-request deadlines, partial-result accumulation, and socket generation guards. Cancellation/disconnect resolve outstanding requests. Event bursts coalesce before reading the authoritative active queue. Reconnect backs off up to 30 seconds; it never replays queued transport commands.

`DevicePlaybackQueue` owns occurrence identity, order, seek position, shuffle, and repeat for independent playback. It restores paused. `AudioFileStore` serializes file/manifest writes, isolates the server/account scope, and evicts only unpinned cache files. `AudioDownloads` owns one background URLSession for explicit downloads and cancellable, network-conscious speculative transfers. `DeviceAudioPlayer` owns AVQueuePlayer and keeps its timing independent of the control WebSocket.

The optional `ServerCompanion` provider supplies an authenticated, versioned full-track file contract. A missing capability endpoint selects the original Sendspin path automatically. Cached and downloaded files remain usable without the companion or a live server. Selecting a remote room never transfers music automatically; incoming Sendspin audio and grouping pause independent device audio before changing ownership. System media commands target the locally audible engine even while browsing another room.

Shared playback is opt-in. One actor-isolated Keychain SendspinStateStore and at most one SendspinClient are alive per app process. Account credentials and Sendspin pairing identity use separate Keychain namespaces. The server API and audio transport use platform certificate validation. Signing out stops local audio, cancels transfers, and removes the signed-out offline library; reconnecting a control socket preserves the independent queue and audio engine.

Tests exercise the control protocol against an independent local WebSocket fixture, not mocks of the Swift implementation. UI automation uses an explicit `--demo` launch argument with clearly labeled synthetic content and disabled network playback. `--onboarding` forces first-run UI without erasing stored credentials.
