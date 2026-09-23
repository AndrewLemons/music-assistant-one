# Music Assistant One

A native SwiftUI music player and [Music Assistant](https://www.music-assistant.io/) controller for Mac, iPhone, and iPad. Connect to your own Music Assistant server, browse your library, control speakers, or play audio on this device through Sendspin.

Maintained by [Andrew Lemons (@AndrewLemons)](https://github.com/AndrewLemons). App Store distribution is published by **Lemony Click, LLC**.

This is an independent client, not an official Music Assistant application. It requires an existing server; server administration and music-provider accounts stay in Music Assistant.

## Build and run

Requires **Xcode 27**, macOS 26 or newer, Python 3, and Git. The app supports macOS 26 and iOS/iPadOS 26; the remote media extension activates on iOS 27. Core alone requires Swift 6.2 or newer.

```sh
brew bundle
make bootstrap
open MusicAssistantOne.xcodeproj
```

Select the **MusicAssistantOne** scheme and **My Mac** or an iOS simulator. For device or signed Mac builds, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set your development team and, if needed, your own bundle identifier. Local signing settings are ignored by Git.

SendspinKit is downloaded at an exact revision into `.dependencies/`, with one verified Release compatibility patch. No vendor source is tracked. Run `make bootstrap` before first opening Xcode and after dependency changes. See [dependency maintenance](docs/DEPENDENCIES.md).

`project.yml` is the XcodeGen source of truth. After adding files or changing targets, run `make generate` and commit the generated project. The version and build number live in `Config/Version.xcconfig`.

## Connect and listen

1. Choose a nearby server or enter a URL. Hostnames default to HTTPS; IP literals and local hostnames default to HTTP. Specify HTTPS explicitly for an IP server that supports it. Reverse-proxy paths are preserved.
2. Sign in with a Music Assistant built-in account or a long-lived access token from Settings → Profile. Tokens and local-player identity are stored in Keychain; passwords are not persisted.
3. Select a speaker in **Players**, or enable **This Device** for local audio.
4. Browse or search music, then use Now Playing for transport controls, volume, repeat, shuffle, and queue access.

Library results load progressively with server-side filtering and sorting. Search requests expand as you scroll, within provider limits. The offline metadata cache contains up to 500 items per category; it does not download audio. See [pagination](docs/PAGINATION.md).

## Compatibility and scope

- Music Assistant WebSocket control, Bonjour discovery, account/token sign-in, reconnect, and Keychain persistence.
- PCM/FLAC local playback and account-bound encrypted pairing, tested with Music Assistant **2.10.1** and **aiosendspin 9.1.1**.
- Speaker grouping, volume, queue controls, native Mac navigation, adaptive iPhone/iPad views, and system media controls.
- The iOS 27 remote media extension supplements local playback integration; physical-device behavior still requires release validation.

Older Sendspin protocols, Home Assistant ingress login, cloud WebRTC access, audio downloads, and dedicated CarPlay browsing are not supported. MusicKit is not used; Music Assistant owns provider access.

## Development

```sh
make format           # Format first-party Swift
make check            # Formatting, lint, workflow/metadata checks, core and tooling tests
make secrets          # Scan publishable history and current files
make build-macos      # Unsigned Release compilation
make build-ios        # Unsigned iOS Simulator Release compilation
python3 scripts/check-interop.py  # Loopback encrypted pairing and reconnect
python3 scripts/test-ios.py       # Playback and UI tests on an installed iOS 27+ simulator
```

UI tests use synthetic `--demo` data. `--onboarding` exercises first-run UI without deleting credentials. See [CONTRIBUTING.md](CONTRIBUTING.md), [architecture](docs/ARCHITECTURE.md), and [validation](docs/VALIDATION.md).

CI checks formatting, lint, secrets, core tests, both Release builds, protocol compatibility, artwork threading, and simulator tests. Release Please opens version/changelog/build-number PRs only. Building, signing, tagging, and publishing releases remain manual; see [release maintenance](docs/RELEASING.md) and [distribution](docs/DISTRIBUTION.md).

## License

[Apache License 2.0](LICENSE). Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md). Report vulnerabilities using [SECURITY.md](SECURITY.md).
