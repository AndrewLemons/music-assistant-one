# App Store review handoff

This app controls a Music Assistant server selected by the user. Apple requires the reviewer to have full access to account-based features and a running backend. See [App Review Guidelines 2.1(a)](https://developer.apple.com/app-store/review/guidelines/) and [App Review information](https://developer.apple.com/app-store/review/).

## Current review instance

- **Server:** `https://music-demo.lemonyclick.com` (Music Assistant 2.10.1 on Railway).
- **Dedicated username:** `apple-review`. Enter its password only in the private App Review credentials fields.
- **Content:** `Review Samples`, two original sample tracks, and sample playlists from a persistent local-files volume. The review device becomes the player when **This Device** is enabled.
- **Operator record:** Railway project `music-assistant-review`; credentials are stored outside the repository at `~/.config/music-assistant-one/railway-review-deployment.json` with file mode `0600`. Do not paste the passwords or token into issues, logs, screenshots, or this document.

## Before submitting

1. Keep the [Music Assistant server](https://www.music-assistant.io/installation/) publicly reachable over HTTPS. Check that its WebSocket endpoint works from a cellular connection outside your network. Do not give Apple an RFC 1918, `.local`, VPN-only, or Home Assistant ingress URL.
2. Confirm the dedicated [built-in Music Assistant user](https://www.music-assistant.io/settings/user-management/) can browse, search, control a player, and pair the review device as a Sendspin player. The sign-in screen uses Music Assistant's built-in account authentication, not Home Assistant SSO. Test the account in a fresh Release or TestFlight install.
3. Keep the sample albums, tracks, and playlists available, and verify that the review device can become a player. The [local-files provider](https://www.music-assistant.io/music-providers/local-files/) can serve licensed tracks without a streaming subscription. Use music and artwork you have rights to share with App Review. Keep the server and account active throughout review. Do not set a short credential expiry or require a second factor the reviewer cannot satisfy.
4. On a physical iPhone or iPad, sign in from outside the local network. Verify library, search, queue, playback, this-device audio, background/locked-screen audio, reconnection, and sign-out. Repeat with local-network access denied; manual HTTPS entry should work.
5. Put the **server URL**, **username**, **password**, and the instructions below in the private **App Review Information** section of App Store Connect. Never commit review credentials or put them in public metadata. Supply a reachable contact person, phone number, and email address there.

## Notes for Review template

Use this text in the private App Review notes after checking it against the uploaded build:

> Music Assistant One is an independent client for a user-provided Music Assistant server. To review the app, enter `https://music-demo.lemonyclick.com` on the first screen, choose Account, and sign in with the review username and password supplied in the App Review credentials fields. The account has sample music. Open Library or Search to browse. To test audio on the review device, enable This Device under Players, select the new device as the player, then play a track. The review server works through manual entry without Local Network permission; Find Nearby Servers requests that permission. This app does not create Music Assistant accounts or sell music subscriptions.

If any feature needs special setup, name it in the notes. Attach a short recording if device pairing or speaker behavior is difficult to reproduce. Verify these instructions against the exact uploaded build and review account.

## Store listing copy

- **Name:** Music Assistant One
- **Subtitle:** Your Music Assistant player
- **Category:** Music
- **Description:** Connect to your own Music Assistant server to browse your library, search music, manage playback queues, and control compatible speakers. Enable This Device to listen on your iPhone or iPad through Sendspin. Music Assistant One is an independent client and requires a server you set up separately. Music providers and account management remain in Music Assistant. Local network access is used to find nearby servers; you can also enter a server address manually.
- **Privacy Policy URL:** `https://github.com/AndrewLemons/music-assistant-one/blob/main/PRIVACY.md`
- **Support URL:** `https://github.com/AndrewLemons/music-assistant-one/issues`

Capture screenshots from the final build on supported iPhone and iPad sizes, showing the connected app and representative, licensed sample content. Avoid a listing composed only of onboarding or placeholder screens. Complete the App Store Connect age rating, content rights, pricing, availability, privacy questionnaire, and export-compliance assessment using the actual build and server setup. This project uses Sendspin cryptography, so do not answer the encryption questions solely by assuming HTTPS is exempt. Archive with distribution signing, inspect the privacy report, and validate through TestFlight on physical devices before submission.

## Account and data behavior

The app signs in to an account on the user's Music Assistant server. It has no in-app account creation and cannot delete a server account. **Disconnect and Choose Another Server** removes the current server's saved token and cache. **Erase Local App Data** removes all saved server addresses, tokens, library caches, playback preferences, and local Sendspin identity/pairing records. Server data must be managed by the server owner. The policy linked in the app and in the listing must reflect the final release.
