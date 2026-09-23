# Building and distributing Music Assistant One

Run `make bootstrap` before building. Use Xcode 27 for the iOS 27 extension. Export options infer the team from your signed archive; they contain no account credentials.

## Identity and signing

- App: `com.lemonyclick.music-assistant-one` on macOS and iOS.
- UI tests: `com.lemonyclick.music-assistant-one.uitests`. Xcode manages its test runner; do not create an App Store record for tests.
- Team: set your own team in ignored `Config/Signing.local.xcconfig`.
- Version/build: `Config/Version.xcconfig`. Release PRs reserve the next version/build; increment the build manually for each additional upload. See [release maintenance](RELEASING.md).
- Minimum systems: macOS 26 and iOS/iPadOS 26. SDK version and minimum supported OS are separate settings.

`project.yml` defines targets; the xcconfig defines version and local signing. Run `make generate` after changing targets. Automatic signing is enabled. Mac sandbox/network entitlements and hardened runtime apply only to macOS. The private Keychain group allows the Release app to persist Sendspin identity in the data-protection Keychain. Do not remove provisioning just to make signing errors disappear.

Sign in under **Xcode → Settings → Accounts**, select your development team, and resolve any membership/agreement or certificate-access issues. Paid Apple Developer Program membership is required for these distribution paths. Xcode can manage development and distribution signing assets when your account has the appropriate permissions. Never commit private keys, provisioning secrets, app-specific passwords, or API private keys.

The bundle ID change gives the app a new preferences/sandbox identity. Expect to reconnect to the server and potentially pair local playback again. Existing Keychain service-name strings are deliberately preserved; these are storage labels, not bundle IDs, and changing them would unnecessarily orphan credentials.

## macOS: direct download

1. Open the project, select **MusicAssistantOne → My Mac**, and run it. Test sign-in, discovery, local playback, and restart persistence.
2. Choose **Product → Archive** (Release). In Organizer select **Distribute App → Direct Distribution**, or the custom **Developer ID** workflow where offered by your Xcode version.
3. Let Xcode sign using **Developer ID Application for your team**, submit for notarization, and export the notarized app. A development-signed archive is an intermediate product; export re-signs it for distribution.
4. Test the exported app, including a downloaded/quarantined copy on another Mac. Distribute a ZIP or DMG containing the stapled app. A plain ZIP/app does not need a Developer ID Installer certificate; a signed installer package does.

CLI archive and export (run from the repository root):

```sh
mkdir -p artifacts/release
xcodebuild -project MusicAssistantOne.xcodeproj -scheme MusicAssistantOne \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath DerivedData-release \
  -archivePath artifacts/release/MusicAssistantOne-macOS.xcarchive \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath artifacts/release/MusicAssistantOne-macOS.xcarchive \
  -exportOptionsPlist Distribution/ExportOptions-macOS.plist \
  -exportPath artifacts/release/macOS -allowProvisioningUpdates
```

The CLI export above signs but does **not** notarize. Configure notarization credentials once in your own terminal (follow the prompts; do not paste credentials into chat):

```sh
xcrun notarytool store-credentials music-assistant-one
```

Use your Apple Account, development team, and an app-specific password, or the API-key authentication supported by notarytool. Then:

```sh
ditto -c -k --keepParent 'artifacts/release/macOS/Music Assistant One.app' \
  artifacts/release/MusicAssistantOne-notarization.zip
xcrun notarytool submit artifacts/release/MusicAssistantOne-notarization.zip \
  --keychain-profile music-assistant-one --wait
```

Proceed only if the result is **Accepted**. If rejected, retrieve the submission log with `xcrun notarytool log SUBMISSION_ID --keychain-profile music-assistant-one` and fix the reported issue.

```sh
xcrun stapler staple 'artifacts/release/macOS/Music Assistant One.app'
xcrun stapler validate 'artifacts/release/macOS/Music Assistant One.app'
codesign --verify --deep --strict --verbose=2 'artifacts/release/macOS/Music Assistant One.app'
spctl --assess --type execute --verbose=2 'artifacts/release/macOS/Music Assistant One.app'
ditto -c -k --keepParent 'artifacts/release/macOS/Music Assistant One.app' \
  artifacts/release/MusicAssistantOne-macOS.zip
```

The final ZIP is created **after** stapling. Keep the archive and dSYMs for crash symbolication. Check that the exported signature has your expected team, the correct identifier, hardened runtime, and no `get-task-allow` debug entitlement.

## iOS: archive, TestFlight, App Store

1. In Apple Developer Certificates, Identifiers & Profiles, ensure the explicit App ID `com.lemonyclick.music-assistant-one` belongs to the team. Automatic signing may already have registered it during a build.
2. Create an iOS app record in **App Store Connect → My Apps → +**. Select the matching bundle ID, display name, primary language, and a private SKU such as `music-assistant-one`. The bundle ID becomes fixed after the first uploaded build. The same identifier can support a later macOS platform under a universal-purchase record.
3. Connect an iPhone/iPad, enable Developer Mode if prompted, select it in Xcode, and test. A simulator cannot establish physical-device background audio or signing behavior.
4. Select **Any iOS Device (arm64)** or another generic iOS device destination, then **Product → Archive**. Use the app scheme, not a test scheme.
5. In Organizer, choose **Distribute App → App Store Connect → Upload** and automatic signing. Complete validation and encryption questions. An archive is a local `.xcarchive`; Xcode packages and uploads the app. You do not email Apple the archive.
6. Wait for processing, then configure **TestFlight**, add internal testers, and install through TestFlight. External testing may require Beta App Review. For public release, complete the store listing, select the build, and submit for App Review.

CLI archive:

```sh
xcodebuild -project MusicAssistantOne.xcodeproj -scheme MusicAssistantOne \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData-ios-release \
  -archivePath artifacts/release/MusicAssistantOne-iOS.xcarchive \
  -allowProvisioningUpdates archive
open artifacts/release/MusicAssistantOne-iOS.xcarchive
```

Optional local App Store Connect export (does not upload):

```sh
xcodebuild -exportArchive \
  -archivePath artifacts/release/MusicAssistantOne-iOS.xcarchive \
  -exportOptionsPlist Distribution/ExportOptions-iOS.plist \
  -exportPath artifacts/release/iOS -allowProvisioningUpdates
```

Keep version/build management consistent: the supplied export options preserve the values from `project.yml`. Upload the IPA using Transporter, or use Organizer to upload directly from the archive.

## Remaining release preparation

- **Privacy policy:** publish a real policy and support/contact page, supply their URLs in App Store Connect, and add an accessible policy link inside the app. There is not yet an in-app policy link. Describe local preferences, Keychain tokens/pairing, server communications, artwork requests, and any information retained by services you operate.
- **App Privacy:** review actual app and dependency behavior before answering Apple's data-collection questionnaire. The required-reason manifest declares the app's own UserDefaults use (`CA92.1`); it is not a substitute for a policy or the questionnaire. Generate/review Xcode's archive privacy report and resolve any dependency/API findings.
- **Encryption:** Sendspin uses CryptoKit, Noise/CPace, and third-party libsodium/CElligator. Do not assume this is only operating-system HTTPS. Complete Apple's export-compliance assessment, including territory questions and documentation if required. `ITSAppUsesNonExemptEncryption` is intentionally unset until that assessment is complete.
- **Review access:** this app requires a Music Assistant server. Provide a reachable review server, working review credentials, legally usable sample music, and clear instructions for local playback. The `--demo` launch argument is a developer fixture, not an accessible substitute for reviewers testing the distributed app.
- **Listing:** final name, description, keywords, category, age-rating questionnaire, screenshots for supported device classes, support/privacy URLs, contact details, availability, and pricing. Recheck icon appearance and third-party license/attribution obligations, including SendspinKit and binary codecs.
- **Real devices:** test local-network permission allowed/denied, manual URL, discovery, sign-in, relaunch, pairing persistence, audio with screen locked and app backgrounded, interruptions, route changes/AirPlay, reconnects, and iPad layout. Verify Release Keychain behavior, not only Debug.
- **Current app limits:** older Sendspin protocols, offline playback, and CarPlay are not implemented; the listing should match supported functionality.

## Sources

- [Apple: preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [Apple: Developer ID distribution and notarization](https://developer.apple.com/developer-id/)
- [Apple: App Store submission requirements](https://developer.apple.com/app-store/submitting/)
- [Apple: required-reason API declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Apple: export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Apple: App Review guidelines](https://developer.apple.com/app-store/review/guidelines/)
