# Validation

## Open-source preparation (23 September 2026)

- Core: 26 tests passed, including HTTPS defaults for hostnames with explicit ports.
- Release tooling: 3 tests passed for idempotent build reservation, preserving manual increases, and invalid-number rejection.
- Unsigned macOS and iOS Simulator Release builds passed with the bootstrapped SendspinKit dependency, including from a fresh clone with no local signing configuration or vendor snapshot. Project generation and builds left the generated project and package locks unchanged. License/notice resources were verified in the Mac app bundle.
- Release interoperability fixture: encrypted handshake, account-style PSK pairing, stored trust, and paired reconnect passed against aiosendspin 9.1.1.
- iOS simulator: 9 playback tests and 3 UI tests passed.
- Background artwork/system Now Playing regression passed.
- SwiftFormat, focused SwiftLint rules, actionlint, metadata validation, and secret scanning passed. Publishable history and eligible working files contained no detected secrets. An exact declaration-only Gitleaks exception covers upstream patch context; it does not suppress key values.
- Local checkpoint refs were also inspected: scanner findings were upstream Swift type declarations and public cryptographic test vectors. These internal refs are not release branches; publish main normally, not with a mirror push.

GitHub-hosted workflows require the repository to be created and Actions enabled; local checks do not establish that remote workflows have run. Physical-device audio, notarization, and store submission remain manual.

## Distribution preparation (23 September 2026)

- Signed Release archives succeeded for generic macOS (arm64 + x86_64) and generic iOS destinations with Xcode 27, bundle ID `com.lemonyclick.music-assistant-one`, and the maintainer development team.
- Mac Developer ID export succeeded. Deep/strict signature verification passed, including embedded FLAC and ogg frameworks; the signature includes hardened runtime, sandbox/network access, and the provisioned private Keychain group, with no debug entitlement.
- iOS App Store Connect export produced an Apple Distribution-signed IPA. Deep/strict signature verification passed; `get-task-allow` is false and the bundle/team identifiers match.
- The app privacy manifest is present in the Mac archive. Plist validation passed for the manifest and both export-option files.
- Fixed the icon generator to emit an opaque 1024 × 1024 iOS icon (no alpha channel), retaining macOS transparency. Regenerated the asset and rebuilt the archives.
- The pinned SendspinKit version failed Release compilation because two production pairing paths referenced a DEBUG-only scalar override. The compatibility patch provides a nil override in Release, preserving fresh random scalars. All 813 upstream tests passed; SwiftLint strict validation passed for the modified source file.
- Core tests passed (9 tests). The Integration package resolves the same bootstrapped dependency as the app.
- iOS compilation reports pre-existing SendspinKit warnings about nonisolated access to UIDevice properties; no compiler errors. AppIntents metadata extraction is skipped because the app does not use AppIntents.

These checks do not establish notarization acceptance, App Store upload/validation, review approval, or physical-device runtime behavior. The signed Mac Release app still needs live sign-in/pairing persistence and playback checks. See [distribution instructions](DISTRIBUTION.md). Artifacts and logs are local under `artifacts/release/` and ignored by Git.

Executed on 23 September 2026 with Xcode 27, Swift 6.4, and macOS 27.2.

| Check | Result |
| --- | --- |
| Core protocol/model suite | 9 tests passed, including parameterized address cases, authenticated WebSocket exchange, reconnect, cancellation, partial results, and events |
| macOS development build | Passed; ad-hoc signature and embedded frameworks verified |
| iPhone simulator UI | Onboarding and library/Now Playing tests passed in light and dark appearances |
| iPad simulator UI | Onboarding and library/Now Playing tests passed |
| Sendspin interoperability | Encrypted handshake, PSK pairing, trust record creation in the test store, and paired reconnect passed against aiosendspin 9.1.1 |
| System artwork regression | 64 background requests and publication through MPNowPlayingInfoCenter passed |
| Live Music Assistant 2.10.1 | Sign-in and library access confirmed; user confirmed local player enable and audible playback |
| Sustained local playback | User confirmed playback continues without crashing after the artwork fix |
| macOS UI automation | Redesign checks passed: in-window Now Playing, preserved library filter, search categories, and stable player position |

The initial live playback attempt crashed when MediaPlayer invoked an artwork provider on its background queue. The provider inherited MainActor from its construction site. The fix constructs it in a nonisolated helper; system remote-command callbacks explicitly use Sendable closures and hop to MainActor for app state. The regression check exercises the actual artwork helper from a background queue and publishes it through the system framework.

Simulator UI tests use explicit synthetic preview data. They do not establish live audio, AirPlay routing, background playback, lock-screen controls, or synchronized groups. These still need physical-device and live-server checks. Dedicated CarPlay browsing is not implemented or entitled.

## Repeat the checks

Run `swift test --package-path Core`. App build and simulator UI-test commands are in the root README.

For the artwork crash regression, on macOS:

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  App/Services/SystemMediaArtwork.swift scripts/check-system-artwork.swift \
  -o /tmp/ma-one-artwork-check
/tmp/ma-one-artwork-check
```

For the real Sendspin protocol check, start the loopback fixture in one terminal:

```sh
uv run --python 3.12 --with 'aiosendspin[server]==9.1.1' scripts/sendspin-fixture.py
```

It prints a loopback URL with a dynamically allocated port. In another terminal, substitute that URL:

```sh
swift run --package-path Integration SendspinInterop http://127.0.0.1:PORT
```

Stop the fixture with Control-C. It uses ephemeral identities and has no access to the production account. This test verifies protocol compatibility, not audible output.

Mac development builds use the login Keychain. Distribution builds and physical iOS devices require appropriate signing/provisioning for the data-protection Keychain. Build into a separate derived-data directory before replacing a running app, to avoid invalidating its code signature while it is in use.

## UI redesign validation

The September 23 redesign was built for macOS and iOS Simulator with Xcode 27. Core tests passed (9 tests). UI automation uses synthetic `--demo` data and does not send playback commands to a real server.

- macOS: 3 UI tests passed. Verified opening/closing Now Playing with no sheet, one connection settings button, keeping a Songs filter after returning from Now Playing, filtering search results, recovering from an empty category, and identical mini-player vertical position before and after a search.
- iPhone 18 Pro, iOS 27: onboarding and Library/Now Playing passed; the search test passed after correcting the test gesture to drag the visible category chips instead of the navigation bar. Checked dark appearance and the always-visible search field.
- iPad Pro 13-inch (M5), iOS 27: all 3 UI tests passed in light appearance, including onboarding, Library/Now Playing, and search filtering.
- Visual inspection covered artwork placeholders, album title wrapping, search browse/results, native mobile presentations, the Mac queue panel, and the Mac window at 980 × 650 and its 760 × 560 minimum. Small-window playback received reduced artwork sizing and spacing.

The final album-grid alignment adjustment was build-checked on both platforms. Live server playback, physical-device audio, VoiceOver narration, and every Dynamic Type size were not revalidated during this UI pass. Existing pagination limits remain unchanged; see [design notes](DESIGN.md).

UI screenshots are attached to the local XCTest result bundles. The Mac UI tests use `click()`; mobile uses `tap()`. A horizontal search-filter test drags within the visible chips because SwiftUI's scroll-view accessibility frame also includes the area under the navigation bar.

## Collection browsing and music actions (27 September 2026)

- `make check`: formatting, SwiftLint, workflow/metadata checks, 39 Core tests, and 3 tooling tests passed. New queue-order tests cover insertion boundaries, no-op moves, repeated songs with distinct queue-entry IDs, and excluding the current song/history.
- iPhone 18 Pro / iOS 27: 6 UI tests and 11 playback tests passed. The live review-account test was skipped because review-server credentials were not supplied. A further focused run passed playlist selection from collection details, Now Playing, and the nested Playing Next sheet.
- Simulator testing found and fixed multiple collection links sharing one List row. The Library home grid now has independent navigation targets. Settings was visually inspected in the shared device panel.
- Unsigned macOS and iOS Simulator Release builds passed. macOS UI automation could not bootstrap: its test runner was killed before establishing a connection, so this does not establish a Mac UI test pass.
- Live-server writes (queue replacement/insertion/reordering, favorites, and playlist additions) still need a connected-server smoke test. Command names and arguments follow the [Music Assistant frontend API](https://github.com/music-assistant/frontend/blob/main/src/plugins/api/index.ts). Preview mode remains non-networked and does not save these changes.

For a live smoke test, use an editable playlist and an expendable playback queue. Confirm Play replaces the queue, Play Next preserves the current song and inserts immediately after it, and Add to Queue appends. Drag upcoming songs in both directions, including repeated copies of one song; verify the order in another client. Switch speakers during an edit and test a rejected move/disconnection. Check favorite add/remove and adding songs or a collection to a playlist, including provider-owned read-only playlists and collections/queues longer than 100 entries.


## Independent playback and downloads (October 20, 2026)

Implemented a persistent device queue, native AVQueuePlayer playback, validated background downloads, Wi-Fi listening cache, offline collection metadata/artwork, and automatic Sendspin fallback through one This Device destination. The optional Music Assistant One Audio provider runs inside a user-managed Music Assistant server; building this repository does not install it.

Automated validation for this change:

- `make check`: formatting, SwiftLint, workflow/repository checks, 48 core behavior/transport tests, three release-tooling tests, and eight companion HTTP tests passed. The additional server adapter test skips when its external source/dependencies are absent.
- Companion interop: all nine tests passed with the actual Music Assistant 2.10.1 source, models, and FFmpeg helper. The adapter generated and inspected a complete seekable FLAC from deterministic PCM.
- All 17 iOS playback tests passed. They exercise real HTTP downloads and native FLAC decoding, reject invalid audio, cover pause/resume and completion races, serialize rapid network-preference changes, restore a paused seek position, advance offline queues past streaming-only entries, and finish offline albums without a spurious network error. Existing remote command/artwork tests remain included.
- Unsigned Release builds passed for macOS and iOS Simulator. Seven iPhone UI regressions passed, covering Downloaded discovery/search/settings, existing collection/playlist actions, player selection, onboarding, and Now Playing. One live-account test was skipped because credentials were not supplied.
- Encrypted Sendspin handshake, account pairing, and paired reconnect passed. The system artwork threading regression and repository secret scans passed.

A dedicated iPhone Simulator was opened in the shared device panel. The Downloaded empty state was inspected visually and through its accessibility tree. Native iOS controls retain Dynamic Type, search, labeled download actions, and 44-point transport targets. The live review-account UI test requires separately supplied credentials and is not covered by fixture-based validation.

Release acceptance still requires the companion installed on the actual server revision, each intended music provider, physical iPhone/iPad background transfers after suspension/relaunch, Lock Screen commands, interruptions, AirPlay/headphone changes, grouping while audio is playing, Listen Separately, provider limits, and loss of the home network while cellular remains connected. Simulator decoding and deterministic server interop do not establish those physical/server behaviors. No production server was modified and nothing was uploaded or deployed.

## Interface polish (October 21, 2026)

Redesigned Downloaded, Search, Settings, onboarding, Now Playing, Queue, Players, and album pages using shared components and native patterns. Copy was shortened throughout. Mac settings moved to a tabbed Settings window.

- iPhone 18 Pro / iOS 27: 7 UI tests and 17 playback tests passed; the live review-account test was skipped without credentials. Each screen was inspected in dark and light appearance and at accessibility-large Dynamic Type.
- macOS 27, signed with the local development team: all 8 UI tests passed. Unsigned runners are still killed before bootstrapping. Two harness fixes made the Mac tests reliable:
  - A test-launched app may not open a window until it receives a reopen event, so `launchApp` sends File › New Window when none appears, and passes `-ApplePersistenceIgnoreState YES`.
  - Mac menus are queried as menu buttons and menu items.
- Mac testing found a pre-existing bug, also present before this pass: pushing an album or playlist page replaced the detail column and removed the floating mini player. The player and its scroll margin now belong to the split view.
- `make lint`, `make test` (48 core tests plus tooling and companion tests), and unsigned Release builds for macOS and iOS Simulator passed.
- On the iOS 27 simulator, the search-role tab doesn't present its own search field even with `.searchable` on the `TabView`, so the field stays pinned in the navigation bar.
- Not revalidated: live-server playback, physical devices, and VoiceOver narration.

## Music Assistant 2.10.7 and server image (October 21, 2026)

Moved the supported server from Music Assistant 2.10.1 to 2.10.7 and added a published server image: the official image plus the Music Assistant One provider.

- Upstream comparison, 2.10.1 to 2.10.7: API schema 65 and the 188 WebSocket commands are unchanged. Two commands gained optional parameters. The provider's server APIs (auth middleware, dynamic routes, stream details, media stream, FFmpeg, plugin model) keep their signatures. Stream routes are unchanged.
- The bundled `aiosendspin` moved from 9.1.1 to 10.2.0. With the fixture ported to 10.2.0, encrypted handshake, PSK pairing, and paired reconnect passed on repeated runs. The server reports the pinned SendspinKit as a noncompliant legacy client and rejects it at `client/hello` when legacy clients are disallowed. See [dependency maintenance](DEPENDENCIES.md).
- `make test-server-image` on arm64 (OrbStack): the provider imported from the installed image, and all nine companion tests passed inside the image. These included the adapter test with the server's own models and FFmpeg. A fresh server from the unchanged entrypoint reported 2.10.7, accepted first-run setup, and added **Music Assistant One Audio** through `config/providers/setup`. `/one/v1/capabilities` rejected an unauthenticated request and answered version 1 with a token. The same test fails against the plain upstream image.
- `make check`, `make secrets`, actionlint, and an unsigned macOS Release build passed.
- Not run locally: the amd64 image, the multi-platform push, and the attestation. CI and the release workflow cover them on GitHub. Live playback and downloads against a real 2.10.7 server with real providers still need validation before release.

## Playback latency (October 21, 2026)

- The reproducible [native cold-start benchmark](PLAYBACK.md#playback-latency-benchmark) compared the working tree with `39d2891d16c1`. Three trials per version reduced median time to advancing AVFoundation playback from 5.938 to 2.056 seconds (65.4%). A subsequent five-run check with render slots reset between trials had a 2.086-second median. Sources were synthetic realtime PCM over loopback HTTP; no user credentials or live speaker queues were used.
- The real FFmpeg encoder published its first segment in about 1.3 seconds, versus 4.889 seconds before tuning. A full progressive song completed through native AVFoundation without an error or a stall.
- iOS 27 Simulator: 22 playback tests passed. New regressions cover prepared Next without another resolution, retaining the successor through queue edits, concurrent current/next cache requests before either file completes, cancellation deduplication, position updates after seeking, and slow artwork staying off audio preparation. The prepared skip took approximately 31 ms with a simulated 250 ms resolve response. The UI suite ran nine tests: eight passed and the credential-dependent live-account test was skipped.
- `make test-server-image` passed on arm64 with 16 tests, including the real Music Assistant adapter, a realtime first-segment deadline, and byte-for-byte decoding of 24-bit/192 kHz FLAC. A fresh server accepted the provider and required authentication for capabilities.
- Core: 49 tests passed. Tooling: five tests passed. Formatting, SwiftLint, workflow/metadata validation, repository generation, and secret scans passed. Encrypted Sendspin handshake, account pairing, and reconnect passed against the pinned server protocol. Unsigned macOS (arm64/x86_64) and iOS Simulator Release builds passed.
- The live endpoint answered unauthenticated capability requests with 401 in approximately 76 ms; authenticated provider playback was not exercised there. Physical audio-output timing, cellular/AirPlay behavior, and synchronized speakers still require device acceptance. The updated server image was built and tested locally; it was not deployed to the user's server.

