# Music Assistant One

A native SwiftUI music player and Music Assistant controller for macOS, iPhone, and iPad. Requires an existing Music Assistant server; server administration stays in Music Assistant.

## Open and run

Open **MusicAssistantOne.xcodeproj**, select the **MusicAssistantOne** scheme, and choose **My Mac** or an iOS simulator. Xcode resolves the pinned SendspinKit dependency automatically. Requires Xcode 26.2 or newer with Swift 6.2; development is verified with Xcode 27. Deployment targets are macOS 26 and iOS/iPadOS 26.

For a physical device, select your signing team in Xcode. CarPlay entitlement is not included.

```sh
# Mac development build (ad-hoc signed)
xcodebuild -project MusicAssistantOne.xcodeproj -scheme MusicAssistantOne \
  -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- build
open 'DerivedData/Build/Products/Debug/Music Assistant One.app'

# Core protocol and model tests
swift test --package-path Core

# UI tests (replace the destination with an installed simulator)
xcodebuild -project MusicAssistantOne.xcodeproj -scheme MusicAssistantOne \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

`project.yml` is the project source of truth. After changing targets or adding source files, run `xcodegen generate` (install via `brew install xcodegen`). The generated project is committed, so XcodeGen is not required just to build. `scripts/generate-icon.swift` reproduces the original vector app icon.

## Connect and listen

1. Choose a nearby server or enter a URL. Hostnames default to HTTPS; a local IP/port can use HTTP. Reverse-proxy paths are preserved.
2. Sign in with a Music Assistant built-in account, or paste a long-lived access token from its Settings → Profile page. Tokens and local-player identity are stored in Keychain. Passwords are not persisted.
3. Choose a speaker in **Players**, or enable **This Device** for Sendspin audio.
4. Search or choose an album, playlist, or song. Use the mini player for transport controls and expanded Now Playing for seeking, volume, repeat, shuffle, and queue access.
5. Use a player's menu to join an advertised compatible group or leave its current group.

The first library page shows up to 60 items per category; its filters and sort menu apply to that loaded page. Global search searches the configured providers and can be filtered by media type. The queue view displays up to 100 entries. Pagination and detailed album/artist browsing are follow-up work.

## Current scope

- Bonjour discovery, configurable server, account/token sign-in, Keychain persistence, reconnect backoff.
- Shared library/search/player/queue state driven by Music Assistant's WebSocket API.
- Playback on other speakers; opt-in local PCM/FLAC playback with pinned SendspinKit and account-bound encrypted pairing.
- Compatible group joining/leaving, group volume, seek, skip, repeat, shuffle, play next, and add to queue.
- Native Mac library sidebar, in-window Now Playing with queue, and keyboard commands; adaptive iPhone/iPad tabs and a Library index.
- Persistent library filtering/sorting, search categories, and a stable Liquid Glass playback bar with speaker and volume controls.
- iOS audio session/background capability, system route picker, local Now Playing and media commands, interruption/headphone-disconnect handling.

The local playback integration targets the encrypted Sendspin implementation in Music Assistant 2.10.x. Older Sendspin protocol versions, Home Assistant ingress login, Music Assistant cloud WebRTC access, offline downloads, and dedicated CarPlay browsing are outside this first build. MusicKit is deliberately not used: Music Assistant owns music-provider access. See [research](docs/RESEARCH.md) and [architecture](docs/ARCHITECTURE.md) for the reasoning and primary sources.

## Validation

See [validation notes](docs/VALIDATION.md) for executed checks and remaining device/server checks. Launch with `--demo` for clearly labeled synthetic UI data, or `--onboarding` to exercise first-run UI without deleting credentials. Preview playback never sends commands to a real server.

See [design notes](docs/DESIGN.md) for the native navigation, search, and playback decisions.
