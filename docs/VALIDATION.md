# Validation

## Open-source preparation (23 September 2026)

- Core: 26 tests passed, including HTTPS defaults for hostnames with explicit ports.
- Release tooling: 3 tests passed for idempotent build reservation, preserving manual increases, and invalid-number rejection.
- Unsigned macOS and iOS Simulator Release builds passed with the bootstrapped SendspinKit dependency.
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
