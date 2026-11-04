# App Store review handoff

This app controls a Music Assistant server selected by the user. Apple requires the reviewer to have full access to account-based features and a running backend. See [App Review Guidelines 2.1(a)](https://developer.apple.com/app-store/review/guidelines/) and [App Review information](https://developer.apple.com/app-store/review/).

## Current review instance

- **Server:** `https://music-demo.lemonyclick.com`, on Railway project `music-assistant-review`.
- **Image:** the App Review variant of the server image (`ghcr.io/andrewlemons/music-assistant-one-server:<server>-<release>-review`). Every release deploys it automatically and verifies it; see [release maintenance](RELEASING.md#app-review-server).
- **Stateless:** each start is a fresh install. The entrypoint erases `/data` and starts Music Assistant. It then creates a random administrator that is never stored, the regular (non-admin) `apple-review` account, the local-files library, and the companion provider. Anything a reviewer changes disappears on the next restart or deploy. If seeding fails, or any other client completes first-time setup first, the container exits and restarts fresh. To reset the server mid-review, restart the service in Railway.
- **Content:** the album `Review Samples` by `Various Artists`, with four original instrumental tracks synthesized at image build (`ServerCompanion/review/samples.py`, so there are no rights questions), cover art, and the playlists `Morning Mix` and `Evening Mix`. The review device becomes the player when **This Device** is enabled.
- **Credentials:** the `apple-review` password is the `REVIEW_PASSWORD` secret in GitHub's `review-server` environment. Each deploy copies it to Railway, so GitHub is the single source of truth. To rotate it, update that secret, run **Release** with the current tag, then update App Store Connect. A local operator record is kept at `~/.config/music-assistant-one/railway-review-deployment.json` (mode `0600`). Never paste passwords or tokens into issues, logs, screenshots, or this document.

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

The app signs in to an account on the user's Music Assistant server. It has no in-app account creation and cannot delete a server account. **Settings → Server → Sign Out** removes the current server's saved token and cache. **Settings → Erase Local Data** removes all saved server addresses, tokens, library caches, playback preferences, and local Sendspin identity/pairing records. Server data must be managed by the server owner. The policy linked in the app and in the listing must reflect the final release.
