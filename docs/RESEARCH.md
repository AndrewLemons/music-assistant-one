# Integration and design decisions

Research date: 23 September 2026. Initial target: Music Assistant 2.10.x, API schema 65; macOS 26+, iOS/iPadOS 26+. Built with Xcode 27 and Swift 6.

## Music Assistant

Music Assistant is a server that combines music providers and local libraries, maintains queues, and sends audio to player providers. Home Assistant is optional. One should be a focused client, leaving provider setup, library management, DSP, and administration to the server.

Use the authenticated `/ws` API for correlated commands and live player/queue events. HTTP `/auth/login` accepts built-in account credentials; long-lived profile tokens also work. Tokens belong in Keychain, while server addresses and player selection can use UserDefaults. Preserve reverse-proxy base paths. Prefer HTTPS for hostnames; explicit local HTTP addresses are supported through the local-network ATS exception. Do not disable certificate validation.

Discover `_mass._tcp` using Bonjour and resolve its server-info TXT record. Always retain manual address entry for VLANs, VPNs, and networks where multicast is unavailable. This build connects directly; Home Assistant ingress and Music Assistant cloud WebRTC tunneling are not implemented.

Players and queues are distinct. Resolve `player_queues/get_active_queue` before enqueueing so a grouped child controls its actual active queue. Group only where `can_group_with` advertises compatibility. Never silently move playback to a different speaker when the selected player disappears. Commands request a change; subsequent server state is the confirmation.

Sources inspected:

- [Music Assistant overview](https://www.music-assistant.io/)
- [API documentation](https://www.music-assistant.io/api/) — per-server `/api-docs` is authoritative for that deployment.
- [Official Python client](https://github.com/music-assistant/client): `connection.py`, `client.py`, `music.py`, `players.py`, `player_queues.py`.
- [Server 2.10.1](https://github.com/music-assistant/server/tree/2.10.1): auth handlers, WebSocket client, Sendspin proxy/provider, discovery, artwork proxy.
- [Wire models](https://github.com/music-assistant/models): players, queues, media items.

## Local playback and Sendspin

SendspinKit supplies clock synchronization, codec decoding, buffer scheduling, and native audio output. Reimplementing these would create unnecessary synchronization and audio risks. Its 1.0.1 tag predates the encrypted protocol used by the target server. Pin revision `98fbe9e46953ef83a0fdb6938f8d8ad98c262992` so the build does not drift with upstream main.

Connect to the *same chosen server* at `/sendspin`, authenticate the MA proxy with the account token and stable device ID, then give its ordered text/binary transport to SendspinKit. The client uses Keychain-backed device identity and `.pairedOnly`. Register as an app player (`product_name: Mobile Application`) and call `sendspin/pair_web_player` with the device pairing token over the authenticated control session. Never print tokens. The server binds pairing to the account. Support PCM and FLAC at 44.1/48 kHz initially. Expose connection and streaming failures separately from remote speaker control.

The dependency has changed substantially since its last release; its pin and the account-bound pairing flow deserve real-device regression tests before distribution. A successful handshake or command does not prove audible playback or synchronization.

- [SendspinKit](https://github.com/Sendspin/SendspinKit)
- [Pinned source](https://github.com/Sendspin/SendspinKit/tree/98fbe9e46953ef83a0fdb6938f8d8ad98c262992)
- [MA Sendspin implementation](https://github.com/music-assistant/server/tree/2.10.1/music_assistant/providers/sendspin)

## Apple integration

SwiftUI owns navigation, layout, controls, sheets, system search, SF Symbols, semantic colors, and Dynamic Type. Mac gets a resizable split view, menu commands, and keyboard shortcuts. iPhone gets tabs and the system `tabViewBottomAccessory` mini player; iPad adapts to a sidebar. Use Liquid Glass for navigation/controls, keeping artwork and reading surfaces uncluttered. Avoid fixed phone dimensions, custom tab bars, and replicas of system controls.

Use AVAudioSession's playback category for iOS local audio, audio background mode, and AVRoutePickerView for hardware routing. Use MPNowPlayingInfoCenter and MPRemoteCommandCenter for local playback metadata and lock-screen/headphone/media-key commands. Pause on interruption and when headphones disconnect. Remote-room selection must not activate an audio session. Physical routing and synchronized multiroom output require device tests.

MusicKit provides Apple Music authorization, catalog, and playback APIs. It is not a generic player for MA streams. Requesting Apple Music authorization here would duplicate provider integration and add an unrelated sign-in requirement; do not link it without an Apple Music-specific feature.

A dedicated CarPlay browsing interface needs Apple's audio-app entitlement and a CarPlay scene using approved templates (`CPTabBarTemplate`, `CPListTemplate`, `CPNowPlayingTemplate`). Keep the connection workflow on the phone; CarPlay should present a small library/recent-items hierarchy and existing playback. This build supplies the system media-control foundation, not an entitled CarPlay app. App Intents/Siri, Spotlight indexing, Handoff, offline downloads, and cloud access are follow-up scope, not claimed features.

Apple sources:

- [MusicKit](https://developer.apple.com/documentation/musickit/)
- [Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [CarPlay](https://developer.apple.com/design/human-interface-guidelines/carplay)
- [Native Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Tab accessory](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:))
- [Remote command center](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)
- [Media playback integration](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MediaPlaybackGuide/Contents/Resources/en.lproj/RefiningTheUserExperience/RefiningTheUserExperience.html)
