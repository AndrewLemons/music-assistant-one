# Validation

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
