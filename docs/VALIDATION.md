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
| macOS UI automation | Incomplete: local-network system prompt prevented interaction with the test window |

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
