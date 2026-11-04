# Music Assistant One

A native SwiftUI music player and [Music Assistant](https://www.music-assistant.io/) controller for Mac, iPhone, and iPad. Browse your library, control speakers, and take downloaded music with you. One **This Device** destination automatically chooses independent playback or Sendspin for synchronized listening.

Maintained by [Andrew Lemons (@AndrewLemons)](https://github.com/AndrewLemons). App Store distribution is published by **Lemony Click, LLC**.

This is an independent client, not an official Music Assistant application. It requires an existing server; server administration and music-provider accounts stay in Music Assistant.

Join the [public TestFlight beta](https://testflight.apple.com/join/jydPafdE) to install iOS builds.

## Build and run

Requires **Xcode 27**, macOS 26 or newer, Python 3, and Git. The app supports macOS 26 and iOS/iPadOS 26; the remote media extension activates on iOS 27. Core alone requires Swift 6.2 or newer.

```sh
brew bundle            # installs mise; activate it in your shell (https://mise.jdx.dev)
make tools bootstrap   # pinned tools, then the verified SendspinKit checkout
open MusicAssistantOne.xcodeproj
```

Select the **MusicAssistantOne** scheme and **My Mac** or an iOS simulator. For device or signed Mac builds, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set your development team and, if needed, your own bundle identifier. Local signing settings are ignored by Git.

SendspinKit is downloaded at an exact revision into `.dependencies/`, with one verified Release compatibility patch. No vendor source is tracked. Run `make bootstrap` before first opening Xcode and after dependency changes. See [dependency maintenance](docs/DEPENDENCIES.md).

`project.yml` is the XcodeGen source of truth. After adding files or changing targets, run `make generate` and commit the generated project. The version and build number live in `Config/Version.xcconfig`.

## Connect and listen

1. Choose a nearby server or enter a URL. Hostnames default to HTTPS; IP literals and local hostnames default to HTTP. Specify HTTPS explicitly for an IP server that supports it. Reverse-proxy paths are preserved.
2. Sign in with a Music Assistant built-in account or a long-lived access token from Settings → Profile. Tokens and local-player identity are stored in Keychain; passwords are not persisted.
3. Choose **This Device** or a speaker in **Players**. With the [optional audio companion](ServerCompanion/README.md), this device uses its own persistent queue; ordinary servers automatically use Sendspin. **Play with Speakers** joins a synchronized group.
4. Open an album or playlist to browse its songs. Its separate **Play** button starts it immediately and replaces the queue.
5. Long press, right click, or use **•••** for Play Next, Add to Queue, Favorites, and Add to Playlist. On iPhone and iPad, swipe a song right for Play Next or Add to Queue. Albums, playlists, and Songs offer **Play** and **Shuffle**. Play Next inserts after the current song; Add to Queue appends. Now Playing offers library actions for the current song.
6. Open **Queue** to drag upcoming songs into order, or use their menus to move or remove them. **Settings** covers the server connection, playback on this device, storage, and local data. On Mac it is a standard Settings window (⌘,).

7. Choose **Download** from a song, album, or playlist menu, then open **Library → Downloaded**. Downloads support pause, retry, cancellation, and offline playback. Settings includes cellular-download and storage controls. Independent playback prepares the next item and keeps a bounded listening cache on Wi-Fi. Downloads require the optional companion; speaker control and Sendspin work without it.

Library results load progressively with server-side filtering and sorting. Search requests expand as you scroll, within provider limits. The library metadata cache contains up to 500 items per category; downloaded audio and its collection metadata are stored separately. See [pagination](docs/PAGINATION.md) and [playback](docs/PLAYBACK.md).

## Compatibility and scope

- Music Assistant WebSocket control, Bonjour discovery, account/token sign-in, reconnect, and Keychain persistence.
- PCM/FLAC local playback and account-bound encrypted pairing, tested with Music Assistant **2.10.9** and **aiosendspin 10.2.1**. Keep the Sendspin provider's **Allow legacy clients** setting enabled (the default); the pinned SendspinKit predates parts of the current Sendspin specification.
- Speaker grouping, volume, queue controls, native Mac navigation, adaptive iPhone/iPad views, and system media controls.
- The iOS 27 remote media extension supplements local playback integration; physical-device behavior still requires release validation.

Older Sendspin protocols, Home Assistant ingress login, cloud WebRTC access, and dedicated CarPlay browsing are not supported. MusicKit is not used; Music Assistant owns provider access. Independent audio uses an optional custom provider, currently targeting Music Assistant 2.10.9. It ships as a [drop-in server image](ServerCompanion/README.md#install-on-a-docker-server) that replaces the official one; live-provider acceptance is separate from compiling the app.

## Development

```sh
make format           # Format first-party Swift
make check            # Formatting, lint, workflow/metadata checks, core and tooling tests
make secrets          # Scan publishable history and current files
make build-macos      # Unsigned Release compilation
make build-ios        # Unsigned iOS Simulator Release compilation
make test-unit        # Playback tests on an iOS 27+ simulator, with coverage
make test-ui          # UI tests on an iOS 27+ simulator
make interop          # Loopback encrypted pairing and reconnect
make test-server-image            # Build the server image and test it in Docker
python3 scripts/benchmark-playback.py --baseline-ref HEAD --runs 3  # Compare native cold-start latency
```

UI tests use synthetic `--demo` data. `--onboarding` exercises first-run UI without deleting credentials. See [CONTRIBUTING.md](CONTRIBUTING.md), [architecture](docs/ARCHITECTURE.md), and [validation](docs/VALIDATION.md).

CI checks formatting, lint, workflow security, secrets, dependencies, Core tests with coverage, both Release builds, protocol compatibility, artwork threading, unit simulator tests, and the server and App Review images on amd64 and arm64. It runs only what a PR affects. UI tests run after merge and on the release PR, which they gate. Every merge to main that changes the app goes to internal TestFlight testers. Merging the Release Please PR tags `vX.Y.Z`, sends the build to public TestFlight testers, attaches a notarized Mac download to the GitHub release, and publishes the server image. See [release maintenance](docs/RELEASING.md) and [distribution](docs/DISTRIBUTION.md).

## License

[Apache License 2.0](LICENSE). Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md). Read the [privacy policy](PRIVACY.md). Report vulnerabilities using [SECURITY.md](SECURITY.md).
