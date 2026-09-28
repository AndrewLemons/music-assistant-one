# Playback and system controls

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
- [Music Assistant queue pause/resume implementation](https://github.com/music-assistant/server/blob/2.10.1/music_assistant/controllers/player_queues/controller.py)

## Playback reliability

- **This Device** is one selection action: it enables Sendspin, waits for the server's playable target (including a target wrapping the Sendspin protocol), and selects it. Choosing another room cancels that pending selection. Automatic reconnection never changes the selected room. Disable local playback separately when the device should no longer receive audio.
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
