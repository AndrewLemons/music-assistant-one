# Playback and system controls

## Behavior

- The iOS Sendspin player uses the playback audio-session category without an explicit `allowAirPlay` option. That option is valid only with `playAndRecord`; playback already supports AirPlay. Combining it with playback caused OSStatus -50 during setup.
- Paused or idle queues whose player resets its clock to zero display Music Assistant's `resume_pos`. The position stays frozen and is bounded by the track duration. Playing queues, completed queues, and queues without a current item do not inherit that fallback.
- On macOS, Now Playing and transport commands follow the selected player/group, including remote speakers.
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
