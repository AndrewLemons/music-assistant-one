# Optional audio companion

The native app works with an unmodified Music Assistant server: browsing, room control, grouping, and online playback through Sendspin remain available. This optional provider adds independent full-track audio access for the device queue, preloading, and offline downloads. Already downloaded music needs neither the companion nor a reachable server.

Music Assistant **2.10.1** does not expose an authenticated standalone full-track file API. Its `/single` and `/flow` URLs belong to active speaker queue sessions; `/preview` is a short sample. This provider uses the server's existing media resolution and audio decoding instead of constructing those internal URLs, capturing Sendspin, fetching private provider URLs on the phone, or modifying a room queue.

## Install on a Docker server

This is a custom server provider, not an official Music Assistant integration. The app discovers it automatically; there is no second server address or account to configure. Back up your normal Music Assistant configuration before replacing a server image.

1. From the repository root, build a derived image:

   ```sh
   docker build -t music-assistant-one-server:2.10.1 ServerCompanion
   ```

2. Change only your existing server container's image to `music-assistant-one-server:2.10.1`. Keep its current network configuration, data volume, environment, and other container settings. This repository does not stop, recreate, or deploy your server.
3. Restart that container using your normal deployment process.
4. In Music Assistant Settings, add the **Music Assistant One Audio** plugin provider. No additional settings are needed.
5. Reopen the native app, or choose **Downloaded → Download settings / Check Again**. Choose **This Device**, then play or download an album.

For a source installation, copy `music_assistant_one/` into that installation's `music_assistant/providers/` directory, restart the server, and add the provider in Settings. The provider imports server internals, so validate it against your precise server revision when upgrading. Home Assistant add-on installations require a separately maintained custom add-on image; this repository does not modify an installed add-on.

Removing the provider restores normal server behavior. Removing the derived image does not remove the app's downloaded music. Never expose an additional unauthenticated stream port for this feature. A reverse proxy should forward `/one/v1/` alongside `/ws`, `/api`, and the other existing server paths, preserve Authorization and Range headers, and allow up to three minutes for preparing an uncached file. Public connections should use your existing HTTPS endpoint.

## Protocol and lifecycle

All paths are relative to the configured Music Assistant URL, including a reverse proxy's base path.

| Request | Authorization | Result |
| --- | --- | --- |
| `GET one/v1/capabilities` | Existing Bearer token | Version 1 capabilities; 404 means ordinary Sendspin fallback |
| `POST one/v1/resolve` with `{"uri":"library://track/…"}` | Existing Bearer token | A temporary, track-bound opaque URL for AVFoundation |
| `GET/HEAD one/v1/audio/<UUID>.flac` | Track-bound ticket | Completed FLAC, Content-Length, ETag, and byte-range support |
| `GET/HEAD one/v1/file.flac?uri=…` | Existing Bearer token | The same audio for URLSession background downloads |

Tickets are random, exist only in memory, expire after 12 hours, and revalidate the original account credential and library-read permission on each request. They are never account tokens. A server restart invalidates tickets; a new play action obtains a fresh one. The client persists neither tickets nor provider stream details. Reverse proxies should redact ticket paths from access logs, just as they redact other capability URLs. The provider does not log request tokens or provider URLs.

Only finite tracks are supported. Radio and live inputs continue through Sendspin. Account provider preferences are applied before resolution, and rendered files are isolated by account and provider preferences. The provider never invokes playback or changes speaker queues. Provider stream limits still apply; concurrent preparation may wait for the provider to free a stream slot.

Two renders can run concurrently, with a queue capped at 32 jobs and a three-minute deadline. Identical playback, cache, and download requests share one render. Completed audio is kept under `.one-audio` in the server data directory with a one-hour idle expiry and a bounded 2 GB cache plus in-progress render space. Each render is limited to 512 MB and six hours of source duration. Cleanup respects active file transfers, and partial files are removed on failure or restart.

Rendering keeps the source sample rate up to 192 kHz and 16- or 24-bit depth in lossless FLAC. A file is completed before serving so native seeking and integrity validation work reliably. The first uncached song can therefore take longer to start, especially with a slow provider. The app prepares the next item and caches two upcoming tracks on Wi-Fi to hide that delay during ordinary listening. This is deliberate: a short preview or a truncated provider stream must never be labeled a download.

## Validate

```sh
python3 scripts/test-companion.py
```

Transport tests use an actual loopback HTTP server. They cover authentication, ticket expiry/revocation, byte ranges, HEAD, render deduplication, account isolation, invalid requests, failed renders, and active-transfer eviction protection. Native simulator tests separately decode a real FLAC download and advance an offline queue after its HTTP server is stopped.

The optional adapter test uses the real server models and FFmpeg process. In an existing Music Assistant development environment with FFmpeg available:

```sh
MA_SERVER_SOURCE=/path/to/music-assistant/server python -m unittest discover -s ServerCompanion/tests -v
```

Before release, validate the provider on the deployed Music Assistant revision with local files and each streaming provider you use. Also check an authenticated reverse proxy, a large album, cancelling during provider resolution, full server storage, provider stream limits, and removal of the companion while downloaded music is playing.

## Design references

- [Music Assistant 2.10.1 stream routes and queue sessions](https://github.com/music-assistant/server/blob/2.10.1/music_assistant/controllers/streams/controller.py)
- [Music Assistant media decoding and provider stream slots](https://github.com/music-assistant/server/blob/2.10.1/music_assistant/controllers/streams/audio.py)
- [Music Assistant plugin lifecycle](https://github.com/music-assistant/server/blob/2.10.1/music_assistant/providers/_demo_plugin_provider/__init__.py)
- [Apple background download lifecycle](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer)
