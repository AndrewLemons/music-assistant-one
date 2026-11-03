# Playback and system controls

## Unified device playback

**This Device** is one persistent destination, identified independently of its Sendspin identity. A newly connected installation selects it by default. With the optional [audio companion](../ServerCompanion/README.md), finite music tracks use AVQueuePlayer and a local, persistent queue. Ordinary servers automatically retain online Sendspin playback. Radio and live inputs continue through Sendspin. Remote rooms and synchronized groups stay server-owned. Choosing a room changes the controller selection; it never starts that room automatically.

The device queue preserves occurrence IDs, repeated songs, edits, position, shuffle, and repeat. It restores paused after launch. Choosing a song in an album, playlist, or list plays that list from the chosen song. Songs start from the companion's progressive HLS stream unless a downloaded, cached, or complete server file is available. AVQueuePlayer holds the following item. Next and queue selection reuse that exact prepared item, and queue edits retain it when the successor is unchanged. Progressive items load paused with network loading enabled. The engine establishes the requested position before audio is audible and gates play on contiguous buffered audio: five seconds for near-realtime sources, reduced to two seconds only after at least 0.8 seconds of measured growth above 1.7×. Short tracks use their remaining duration. Startup has a 90-second limit and seeks have a ten-second limit. Loading is exposed immediately; automatic stall minimization remains enabled.

Cancellable transfers retain the current song and the next three songs on Wi-Fi and cellular, bounded by the 512 MB listening cache and 128 MB per speculative file. Low Data Mode reduces speculative transfers to the next song. The next file request starts alongside the current remainder; later transfers follow. Queue repeat order is honored. Files in this window are protected from eviction. A renewable, authenticated preparation window tells the companion to render the current song first, then upcoming songs. Account renders are sequential to accommodate single-slot providers; four accounts can render concurrently. Pre-rendering cannot make a paced provider finish future songs before enough source time has elapsed.

Upcoming AVQueuePlayer items use local files whenever caching finishes; incomplete progressive successors stay behind the startup gate. Queue edits, network changes, seeks, and cancellations reject stale work. NWPathMonitor detects connection loss, expensive paths, and Low Data Mode. Cached songs continue without the control socket or server. Unavailable offline occurrences are skipped once, then playback stops with an actionable message if none remain.

**Cellular Streaming** defaults to **Lossless**. **High Efficiency** requests AAC at approximately 256 kbps on expensive paths, including look-ahead. Wi-Fi requests and explicit downloads use lossless FLAC in MP4 (`.m4a`, `audio/mp4`). Companion protocol 3 is required. Formats have separate server/client cache keys; an AAC cache entry never satisfies a lossless download. Both encodings require an MP4 signature, the expected audio codec, a complete HTTP body, and decoded full-song duration. Files downloaded to URLSession’s `.tmp` paths receive the appropriate MIME override for native validation.

AVFoundation stops loading an HLS stream whose playlist completes during playback once its buffer fills, and seeks on it can hang (reproduced on iOS 27 and macOS with preferred and automatic buffering). When a stream that opened while growing completes, a fresh item of the complete audio is queued a few seconds ahead and the stream ends there through `forwardPlaybackEndTime`, so AVQueuePlayer continues seamlessly. A seek in that window moves to the fresh item immediately. A sustained buffer exhaustion prefers a cached complete file at the exact current position. Otherwise the engine pauses, rebuilds a five-second lead, and re-establishes that position before resuming. It never corrects an HLS live-edge start after playing. During a complete-file handoff, position reporting ignores the replacement item’s temporary zero clock. Items use automatic buffering: a preferred forward buffer duration made the stall occur sooner. Cache files use a 512 MB budget; individual speculative files are limited to 128 MB. Explicit downloads are pinned and are not evicted by cache cleanup. Both are preferred to network audio when available.

Downloads use a dedicated system background URLSession, a persisted job list, and at most two active jobs. Paused transfers keep their system tasks; resume continues those tasks when available. Missing tasks after a system restart are recreated from saved intent. User cancellation removes that intent. Changes to cellular preferences replace the session after invalidation and can restart a partial transfer. Credentials remain in Keychain; the app does not persist credential-bearing URLSession resume blobs. Completed explicit downloads require an HTTP 200 response, an MP4 container containing FLAC, matching Content-Length when supplied, and a decoded duration consistent with the full song. Invalid/partial audio stays out of the offline catalog and can be retried. The v2 manifest invalidates the old speculative cache. Existing native FLAC downloads remain playable while ordinary background jobs replace them, using the cellular-download preference. The old file is removed only after its validated replacement and manifest are published; paused or failed replacements remain retryable.

Downloads and cached audio are isolated by a server/account credential fingerprint. Manifests use atomic writes through an actor, files use random names, and audio/artwork are excluded from backups. iOS storage permits playback after the first unlock. Downloaded collection metadata and artwork remain available without the server. Queue and transport commands remain functional when the control WebSocket disconnects. Offline advancement skips unavailable entries at most once per occurrence, including with Repeat All/One, and stops with an actionable message if no playable song remains.

**Play with Speakers** enables the existing Sendspin player and joins it to the chosen room. **Listen Separately** copies the active queue and its current position back to the independent engine after leaving shared playback. Incoming Sendspin audio pauses independent audio before changing ownership. **Available to Other Devices** lets other Music Assistant clients target this device without requiring that transport for ordinary independent listening. The engine is never exposed as a user-selected technical mode. If the companion is removed, new online selections fall back to Sendspin; a failed independent session refreshes capabilities, and retry can transfer the remaining queue and position to Sendspin.

Native playback owns system media controls on iOS 26+ and macOS, including while offline. Interruptions capture the local queue occurrence and resume only when the OS permits and user intent has not changed. Headphone removal pauses; a media-services reset recreates AVQueuePlayer and stays paused. Local audio continues while browsing another room; paused independent audio yields system controls when a remote room is selected.

Server installation, first-track preparation latency, endpoint authorization, and limits are documented with the companion. No server is modified or deployed by building the app. Transport controls never wait for the server. `TransportControl` (Core) shows each command at once and sends commands in order, one writer per queue. Next and Previous show the destination song from the queue around the current song; taps queued behind an unacknowledged command combine into one jump. Repeated play/pause, seek, shuffle, and repeat keep only the latest request. Each predicted field reconciles separately: no snapshot clears it before its command is acknowledged, a matching snapshot clears it afterward, and a different one replaces it after a 2.5-second grace period (8 seconds when starting new music). A failed command reverts the controls, drops commands queued behind it, and shows a brief notice. Grouping and queue edits still run one at a time.

## Library lists

Music Assistant 2.10.9 has no media URI for a library list. Its builtin playlists are a 500-song random sample and an infinite mix, can be disabled, and ignore the listener's filter and sort. The app therefore supplies the songs (`LibraryQueue` in Core):

- Play and choosing a song start with the songs already loaded, in the displayed order. Choosing a song keeps the queue's shuffle setting and plays that song first; on speakers `start_item` pins it ahead of a shuffled queue.
- Shuffle fetches one page in the server's `random` order with the same filter, so the first song can come from anywhere in the list.
- The rest follows in the displayed server order, 500 songs per page, skipping songs already queued, up to 2,000 songs. This Device appends to its queue; when shuffled, new songs are placed at random positions after the prepared next song, keeping the listener's edits. Speakers and Sendspin start with up to 100 songs and receive the rest through `play_media` with `add`, which Music Assistant mixes in when shuffled.
- Choosing another list, signing out, or losing the connection stops loading. A failed page shows a brief notice; queued songs keep playing.

Albums play in order unless Shuffle is chosen, on both engines, as Music Assistant does for ordered media.

## Playback reliability benchmark

```sh
make server-image
python3 scripts/benchmark-playback.py --reliability --baseline-ref 204a7d40e5c32deaef88301d67056d6e5f8432d8 --output /tmp/one-reliability
```

The committed harness in `scripts/playback-research/run.py` compiles the real DeviceAudioPlayer, foreground cache, validation, and Core against the real companion encoder and HTTP service in isolated Docker fixtures. Only explicit background-download session setup is omitted in the command-line executable, which has no app bundle entitlement. No saved account is used. Sources use monotonic-deadline pacing: exact 1×, exact 1× with 1.5-second pauses every eight source seconds, and 5×. Each queue contains a 72-second song followed by two 12-second songs. JSONL telemetry samples the native clock, exposed position, buffering, loaded ranges, and local-file use every 100 ms. Results include startup, waits (including later startup gates), backward position jumps, and second-track transition overhead. Transitions have approximately 100 ms sampling uncertainty; zero means no measurable positive overhead.

The signal-loss fixture stops its container after all three files validate, then verifies advancement through the cached queue. The original cold-start-only command remains available without `--reliability`. These are native clock measurements, not physical audio-output measurements. Repeated source pauses make average production slower than playback; a five-second first-play lead cannot cover unlimited pauses. Rebuffering is measured rather than hidden.

On 3 November 2026, one trial per fixture compared base `204a7d4` with implementation `ad47aec`. Startup is time to an advancing exposed playback clock. Waits below cover the first 72-second song; the JSON also reports all queue waits, including subsequent startup gates.

| Source | Startup before → after | First-song waits before → after | Second-track overhead before → after |
| --- | --- | --- | --- |
| Exact 1× | 2.007 → 6.063 s | 1 / 1.069 s → 0 / 0 s | 0 → 0.342 s |
| 1× + 1.5 s pauses every 8 s | 1.989 → 6.002 s | 9 / 14.232 s → 4 / 12.329 s | 0 → 0 s |
| 5× | 1.208 → 1.796 s | 0 / 0 s → 0 / 0 s | 0 → 0 s |

Every after fixture had zero backward and unexpected forward jumps after startup. Full-queue wait totals were 2 / 0.315 seconds for exact 1× (subsequent startup gates), 6 / 13.485 seconds for jitter, and zero for 5×. Signal loss at 19.304 seconds, after three validated files, completed all three songs locally with zero waits or jumps. This confirms offline continuation after the cache fills; it does not promise that cold, paced sources can pre-render several future songs immediately. The [measurement manifest](../scripts/playback-research/metrics.json), [exact commands](../scripts/playback-research/commands.txt), and compressed native telemetry in `scripts/playback-research/telemetry/` are committed.

Seek regressions run separately:

```sh
python3 scripts/benchmark-playback.py --reliability --seek --baseline-ref ff3cea6 --output artifacts/playback-seek-final
python3 -m unittest discover -s scripts/playback-research -p 'test_*.py' -v
```

Each seek fixture first plays ten seconds, then awaits `device.seek` for a backward move to three seconds, an already-produced forward target (about eleven seconds at 1×; forty seconds at 5× and for local files), a future target at 1×, and five release commands about 150 ms apart. Independent main-actor tasks let newer commands supersede an in-flight seek. Only the latest target may remain after the burst. Progressive songs last 600 seconds so completion/handoff cannot obscure the seek path; the local control first prepares and validates a complete 72-second cached file.

The progressive seek fixture warms the source for 45 seconds at 1× or six seconds at 5×, renewing its resolve lease, and delays HTTP delivery of `seg20.m4s` for 180 seconds. This leaves later segments produced and seekable while the old playhead's sequential loading is blocked. AVFoundation's automatic buffering and `automaticallyWaitsToMinimizeStalling` stay enabled. On this Mac, ordinary short synthetic fixtures load every produced segment, so both revisions can pass; a delayed segment makes the unloaded-target regression deterministic without modifying the real player. The 1× fixture adds an already-produced, unloaded forward target near the seekable edge. Telemetry verifies this precondition; a fully buffered fixture cannot pass as regression coverage. Ordinary realtime, jitter, fast, and offline fixtures retain their original source and HTTP behavior.

Seek telemetry records periodic native clocks plus every exposed `onChange`, explicit issue/return/deadline events, loaded/seekable ranges, and the source production counter. Success requires two advancing native-clock samples within 0.5 seconds of the target, playing status, and an agreeing exposed position. Reported positions must remain at the target while loading and follow its advancing clock after resume; intentional seek moves are excluded from jump counts. Playing native clocks elsewhere are failures. The source counter verifies that a future target was not produced at issue time. Seeks are observed for twelve seconds before moving to the next case, so baseline hangs are right-censored at twelve seconds rather than claimed to reach the player's ninety-second limit. The future case includes time to produce the target plus the buffering lead. Latencies include roughly 100–200 ms of observation overhead; these are clock-based audio proxies, not recordings of physical output.

The harness owns one temporary directory for Core and both native builds, deletes it on exit, and removes each fixture container. It uses no simulator or saved account. The seek oracle's unit tests guard against optimistic UI-only success, stale callbacks between samples, playback elsewhere, missing scrub commands, and disabled automatic stall minimization. Updated seek and full-queue measurements are recorded alongside the original benchmark in [metrics.json](../scripts/playback-research/metrics.json).

The seek comparison used baseline `ff3cea6` and fixed player `c84d19f` (one trial per fixture). All times below include the independent clock observer:

| Seek | Baseline → fixed |
| --- | --- |
| 1× backward / nearby forward, already buffered | 0.196 / 0.255 → 0.196 / 0.255 s |
| 1× forward, produced but unloaded (49.096 s) | ≥12 s, paused → 0.353 s |
| 1× forward beyond production | ≥12 s, paused → 10.002 s including production wait |
| 5× backward / forward to 40 s | 0.256 / ≥12 → 0.205 / 0.406 s |
| Complete local backward / forward to 40 s | 0.246 / 0.235 → 0.236 / 0.244 s |
| Final release in five-seek burst, 1× / 5× / local | 0.256 / 0.256 / 0.206 → 0.269 / 0.207 / 0.192 s |

Both revisions had zero stale exposed positions, playing native clocks away from the requested target, or errors. The baseline failures stayed paused until the harness issued the next command; the harness does not claim a measured ninety-second timeout. The fixed future seek requested 64.1 seconds when only 61.1 seconds had been fed to the encoder. The target became seekable after 7.714 seconds, and playing status appeared after 9.818 seconds; the advancing-clock oracle confirmed success at 10.002 seconds. Each burst ended at its last target. No further change to `DeviceAudioPlayer.swift` was necessary.

The ordinary queue recheck completed every track with zero backward/forward jumps or errors. Historical → current startup was 6.063 → 6.045 seconds for realtime, 6.002 → 6.008 for jitter, 1.796 → 1.893 for fast, and 1.785 → 1.893 for offline. First-song jitter waits remained four, totaling 12.329 → 12.231 seconds; other first-song waits stayed zero. Full-queue waits were 2 / 0.207 seconds for realtime, 6 / 13.390 seconds for jitter, and zero for fast/offline. The offline container stopped at 19.299 seconds and all three cached songs finished locally.

The historical transition metric uses the exposed position's 500 ms update cadence. Its jitter gap changed from zero to 0.244 seconds because the final tick landed differently at the boundary. The new `native_second_track_gap_seconds` extrapolates advancing native clocks instead; recalculating both traces gives 0.229 → 0.188 seconds for jitter and 0.286 → 0.227 for realtime, with zero for fast/offline. The original metric and historical measurements remain in the manifest. The recheck shows no playback reliability regression within this single-trial native harness; physical iPhone output remains outside these measurements.

Complete-file seeking also has a decoded-audio regression:

```sh
python3 scripts/benchmark-playback.py --reliability --audible-seek --output /tmp/one-audible-seek
```

A real AVPlayer audio tap measures a variable-bitrate chirp at 30, 90, 150, 200, and 230 seconds. Its frequency identifies the played samples independently of the reported clock. The native FLAC control must fail; the companion’s faststart FLAC-in-MP4 output must pass every target. See [the fixture and oracle](../scripts/playback-research/seek-accuracy/README.md). This checks decoded audio on macOS, not physical iPhone output.

The observable engine surface is `startup` (`idle`, `resolving`, `buffering(progress:)`, `playing`), `isBuffering`, `isLoadingVisibly`, `currentAvailableOffline`, and `nextAvailableOffline`. Buffer progress ranges from zero to one for the current gate. `wantsPlayback` remains user intent while loading. No AppModel or system-media wiring is required for these properties.

## Behavior

- The iOS Sendspin player uses the playback audio-session category without an explicit `allowAirPlay` option. That option is valid only with `playAndRecord`; playback already supports AirPlay. Combining it with playback caused OSStatus -50 during setup.
- Paused or idle queues whose player resets its clock to zero display Music Assistant's `resume_pos`. The position stays frozen and is bounded by the track duration. Playing queues, completed queues, and queues without a current item do not inherit that fallback.
- Now Playing follows audible local playback when present; otherwise macOS system controls follow the selected player/group, including remote speakers.
- On iOS 27 or later, a native NowPlaying remote-media extension represents the selected remote player/group in Lock Screen and Control Center. It starts when the selected queue is playing, retains paused state, and ends when the selection is cleared, disconnected, unavailable, or completed. Switching to a queue playing locally uses the existing MediaPlayer integration.
- iOS 26 retains system controls for local Sendspin playback. Remote-only system controls require iOS 27. The app does not run a silent audio loop or activate local audio to represent a remote speaker.

The extension authenticates independently through the app's shared Keychain access group. Donated attributes contain whitelisted display metadata and server/player identifiers, never the login token or full stream details. Player transport commands target the selected player; seeking resolves its current active queue, including after regrouping. Interruptions and headphone disconnection continue to pause only the local player.

The extension refreshes from Music Assistant when it wakes and while its WebSocket is running. Commands reconnect as needed. There is no APNs integration, so server changes cannot wake a suspended extension or start controls while the app has never opened the selected session. iOS decides when to run the extension. Primary-session selection is requested in the foreground once per session; metadata updates do not continually steal controls from another app.

## Validation

- Core suite: 11 tests passed, including pause/idle resume position, duration bounds, normal playback, completed queues, and zero positions.
- iOS 27 Simulator: 5 remote-playback tests passed, covering selected-player commands, current-group seeking, invalid seeks, missing credentials, stale/session-mismatched updates, and metadata filtering.
- App builds passed for iOS Simulator and macOS. The iPhone Simulator Library/Now Playing UI regression passed.

Repeat the remote suite with:

```sh
xcodebuild -project MusicAssistantOne.xcodeproj -scheme MusicAssistantOne \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:PlaybackTests test
```

Build 0.1.0 (2) was archived for generic iOS with automatic signing. The app and remote-media extension both report build 2 and share the intended Keychain access group. Deep/strict signature verification passed. A local App Store Connect export also succeeded at `artifacts/release/iOS-build-2/`; the exported app and extension use distribution signatures with debugging disabled. Nothing was uploaded. The archive is at `artifacts/release/MusicAssistantOne-iOS-build-2.xcarchive`; open it in Xcode Organizer and choose **Distribute App → App Store Connect → Upload**.

Xcode emitted an embedded-extension path warning during archive validation because the build-products path resolves through the archive staging directory. The final archive contains the signed extension at the required `Music Assistant One.app/Extensions/RemoteMediaExtension.appex` path. Existing SendspinKit actor-isolation warnings remain.

Physical-device checks still required: enabling Sendspin and hearing audio; pausing/resuming and seeking; selecting a remote speaker with Sendspin disabled; using Lock Screen controls after backgrounding; changing groups; signing out; interruption and AirPlay route changes. Simulator tests do not establish physical audio routing or system presentation/extension scheduling.

## References

- [Apple: allowAirPlay](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowairplay)
- [Apple: publishing remote media sessions](https://developer.apple.com/documentation/nowplaying/publishing-remote-media-sessions)
- [Music Assistant queue pause/resume implementation](https://github.com/music-assistant/server/blob/2.10.9/music_assistant/controllers/player_queues/controller.py)

## Playback reliability

- **This Device** selects the persistent device destination. When synchronized audio is required, the app enables Sendspin and waits for the server's playable target, including a target wrapping the protocol. Automatic reconnection never changes the selected room. Shared availability can be disabled separately in Settings.
- Local Sendspin output has no software volume or mute capability; use the operating system's volume controls. Remote sliders use independent, ordered writers per player, coalesce rapid adjustments, retain the latest requested value, and reconcile against server state. Transport commands do not block or discard volume changes. Keyboard and accessibility adjustments use the same path as dragging.
- Queue-level artwork is preserved when extracting a nested track. The remote extension fetches and validates artwork before publishing its stable identifier, retries transient failures, and cancels stale track requests. JPEG normalization remains for NowPlaying compatibility; converting a missing image URL cannot fix missing artwork.
- The host reports audio-session activation to Sendspin on setup, interruption and resume. An interruption captures only the playing local queue and entry, pauses independently of UI command activity, and resumes after iOS supplies `shouldResume`. Resume waits for pause completion and verifies that the local queue/entry is unchanged. User pause/stop, headphone removal, disabling playback, sign-out and media-services reset invalidate automatic resume. Media-services reset recreates audio objects and leaves playback paused for a user play action.
- Local Now Playing controls remain attached to local audio while browsing remote rooms or reconnecting the control WebSocket. Recovery requests finite background execution time; it does not use silent audio to prevent suspension. Playback can continue in the background, but iOS may suspend an idle player, terminate the app, or withhold interruption-end notifications. Foreground refresh reconnects the enabled player; it does not force an old queue to play.

### Device acceptance checks

Automated tests cover ordered volume writes, failure rollback, cancellation, wrapper identity, queue artwork donation, image formats, artwork retry, and interruption resume policy. Before release, verify on a physical iPhone/iPad and a Music Assistant server:

1. Select This Device from a fresh session, play a track, and verify that only system volume controls affect local volume.
2. Move a remote slider rapidly while issuing transport commands; confirm its final value at the speaker. Change players during a pending adjustment.
3. Select a remote queue whose track inherits album artwork; verify Lock Screen/Control Center art on iOS 27, including after a track change and temporary network failure.
4. Lock the phone during local playback. Interrupt with Siri and a phone call, then verify automatic resume when permitted. Pause explicitly during the interruption and confirm it stays paused.
5. Unplug headphones, change Bluetooth/AirPlay routes, briefly lose Wi-Fi, and reset Media Services. Check that recovery neither selects another room nor resumes after an explicit pause.

Platform guidance: [Apple interruption handling](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions) and [remote media sessions](https://developer.apple.com/documentation/nowplaying/publishing-remote-media-sessions).

Validation for these changes: 37 core tests, 11 iOS playback/artwork tests, 4 UI tests, both unsigned Release builds, encrypted pairing/reconnect interop, artwork threading, lint, repository checks and secret scans passed. The credential-dependent live-server UI test was skipped because review-server credentials were not supplied. Physical-device acceptance remains required.
