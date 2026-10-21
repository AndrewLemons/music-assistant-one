# Optional audio companion

The native app works with an unmodified Music Assistant server: browsing, room control, grouping, and online playback through Sendspin remain available. This optional provider adds independent full-track audio access for the device queue, preloading, and offline downloads. Already downloaded music needs neither the companion nor a reachable server.

Music Assistant **2.10.7** does not expose an authenticated standalone full-track file API. Its `/single` and `/flow` URLs belong to active speaker queue sessions; `/preview` is a short sample. This provider uses the server's existing media resolution and audio decoding instead of constructing those internal URLs, capturing Sendspin, fetching private provider URLs on the phone, or modifying a room queue.

## Install on a Docker server

This is a custom server provider, not an official Music Assistant integration. The app discovers it automatically; there is no second server address or account to configure.

The published image is the official Music Assistant image with this provider added. The entrypoint, `/data` volume, port, environment, and runtime user handling are unchanged, so replace only the image repository and keep your tag:

| Official image | Music Assistant One image |
| --- | --- |
| `ghcr.io/music-assistant/server:latest` | `ghcr.io/andrewlemons/music-assistant-one-server:latest` |
| `ghcr.io/music-assistant/server:stable` | `ghcr.io/andrewlemons/music-assistant-one-server:stable` |
| `ghcr.io/music-assistant/server:2.10` | `ghcr.io/andrewlemons/music-assistant-one-server:2.10` |
| `ghcr.io/music-assistant/server:2.10.7` | `ghcr.io/andrewlemons/music-assistant-one-server:2.10.7` |

Each release also has a pinned tag combining both versions, such as `2.10.7-0.2.0` for Music Assistant 2.10.7 with Music Assistant One 0.2.0; later releases never move it. Images are built for `linux/amd64` and `linux/arm64`. Only stable Music Assistant releases this project has validated are published; there are no `beta` or `nightly` tags.

New Music Assistant releases arrive after validation, so this image can briefly trail the official `latest`. Music Assistant does not support downgrades. Before switching, check that the image's version (shown in the tag table on the [package page](https://github.com/AndrewLemons/music-assistant-one/pkgs/container/music-assistant-one-server)) is the same as or newer than the server you run, and back up your data volume.

1. Change only the image of your existing server container. For Docker Compose:

   ```yaml
   services:
     music-assistant-server:
       image: ghcr.io/andrewlemons/music-assistant-one-server:latest # was ghcr.io/music-assistant/server:latest
       # Keep the existing network_mode, volumes, environment, and other settings.
   ```

2. Recreate the container using your normal process, such as `docker compose pull && docker compose up -d`.
3. In Music Assistant Settings, add the **Music Assistant One Audio** plugin provider. No additional settings are needed.
4. Reopen the native app, or choose **Downloaded → Download settings / Check Again**. Choose **This Device**, then play or download an album.

To return to the official image, remove the provider in Settings, then switch back to the official image of the same version. Removing the image does not remove the app's downloaded music.

Releases include a signed build provenance attestation. To verify an image before deploying it:

```sh
gh attestation verify oci://ghcr.io/andrewlemons/music-assistant-one-server:latest --owner AndrewLemons
```

To build the image yourself from a checkout, run `make server-image`. It builds `music-assistant-one-server:2.10.7` for your machine's architecture with Docker Buildx; `make test-server-image` also runs the checks below.

For a source installation, copy `music_assistant_one/` into that installation's `music_assistant/providers/` directory, restart the server, and add the provider in Settings. The provider imports server internals, so validate it against your precise server revision when upgrading. Home Assistant add-on installations require a separately maintained custom add-on image; this repository does not modify an installed add-on.

Removing the provider restores normal server behavior. Never expose an additional unauthenticated stream port for this feature. A reverse proxy should forward `/one/v1/` alongside `/ws`, `/api`, and the other existing server paths, preserve Authorization and Range headers, and disable response buffering for `/one/v1/stream/`. A first playlist request can wait up to two minutes for a provider to start. A complete-file request waits until the whole song is prepared, which takes about the song's length with realtime-paced providers. Public connections should use your existing HTTPS endpoint.

## Protocol and lifecycle

All paths are relative to the configured Music Assistant URL, including a reverse proxy's base path.

| Request | Authorization | Result |
| --- | --- | --- |
| `GET one/v1/capabilities` | Existing Bearer token | Version 1 capabilities; 404 means ordinary Sendspin fallback |
| `POST one/v1/resolve` with `{"uri":"library://track/…"}` | Existing Bearer token | Temporary, track-bound opaque URLs for AVFoundation (`stream`, `path`) and whether the complete file is `ready`; preparation starts immediately |
| `GET/HEAD one/v1/stream/<UUID>/index.m3u8` and its segments | Track-bound ticket | The song as lossless HLS (FLAC in fragmented MP4), growing while it is prepared |
| `GET/HEAD one/v1/audio/<UUID>.flac` | Track-bound ticket | Completed FLAC, Content-Length, ETag, and byte-range support |
| `GET/HEAD one/v1/file.flac?uri=…` | Existing Bearer token | The same audio for URLSession background downloads |

Tickets are random, exist only in memory, expire after 12 hours, and revalidate the original account credential and library-read permission at most every 30 seconds, since a stream requests playlists and segments about once per second. They are never account tokens. A server restart invalidates tickets; a new play action obtains a fresh one. The client persists neither tickets nor provider stream details. Reverse proxies should redact ticket paths from access logs, just as they redact other capability URLs. The provider does not log request tokens or provider URLs.

Only finite tracks are supported. Radio and live inputs continue through Sendspin. Account provider preferences are applied before resolution, and rendered files are isolated by account and provider preferences. The provider never invokes playback or changes speaker queues. Provider stream limits still apply; concurrent preparation may wait for the provider to free a stream slot.

Four renders can run concurrently, with a queue capped at 32 jobs. Identical playback, cache, and download requests share one render. A render nobody is streaming or downloading stops after 30 seconds, or after 8 seconds once the same account starts another song, releasing the provider's stream slot. A server short of storage answers 507 instead of starting a render. Completed audio is kept under `.one-audio` in the server data directory with a one-hour idle expiry and a bounded 2 GB cache plus in-progress render space. Each render is limited to 512 MB and six hours of source duration. Cleanup respects active file transfers, and partial files are removed on failure or restart.

Rendering keeps the source sample rate up to 192 kHz and 16- or 24-bit depth in lossless FLAC. One provider stream feeds two outputs: one-second HLS segments, served as soon as each is written, and a complete FLAC file. The encoder receives fully specified PCM, so minimal probing avoids collecting several seconds of a realtime source before writing audio. In the repeatable local fixture, the first segment appears in about 1.3 seconds and native playback advances in about 2.1 seconds; provider resolution and network time are additional. See the [playback benchmark](../docs/PLAYBACK.md#playback-latency-benchmark). The complete file backs native seeking, offline caching, and downloads, and is verified before it is published: a short preview or a truncated provider stream must never be labeled a download. Playlists start at the beginning (`EXT-X-START:TIME-OFFSET=0`, without `PRECISE`, which AVFoundation then ignores) rather than the live edge.

## Validate

```sh
python3 scripts/test-companion.py
```

Transport tests use an actual loopback HTTP server. They cover authentication, ticket expiry/revocation, bounded revalidation, byte ranges, HEAD, growing playlists, abandoned and preempted renders, render deduplication, account isolation, invalid requests, failed renders, and active-transfer eviction protection. Native simulator tests separately decode a real FLAC download and advance an offline queue after its HTTP server is stopped.

The adapter test uses the real server models and FFmpeg process. `make test-server-image` builds the image and runs it inside, then starts a fresh server from the image, adds the provider through the API, and checks authenticated capabilities. CI runs it on amd64 and arm64, and the release workflow runs it again before publishing. To run the adapter test in an existing Music Assistant development environment with FFmpeg available instead:

```sh
MA_SERVER_SOURCE=/path/to/music-assistant/server python -m unittest discover -s ServerCompanion/tests -v
```

Before release, validate the provider on the deployed Music Assistant revision with local files and each streaming provider you use. Also check an authenticated reverse proxy, a large album, cancelling during provider resolution, full server storage, provider stream limits, and removal of the companion while downloaded music is playing.

## Design references

- [Music Assistant 2.10.7 stream routes and queue sessions](https://github.com/music-assistant/server/blob/2.10.7/music_assistant/controllers/streams/controller.py)
- [Music Assistant media decoding and provider stream slots](https://github.com/music-assistant/server/blob/2.10.7/music_assistant/controllers/streams/audio.py)
- [Music Assistant plugin lifecycle](https://github.com/music-assistant/server/blob/2.10.7/music_assistant/providers/_demo_plugin_provider/__init__.py)
- [Apple background download lifecycle](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer)
