# Playback feedback and connection recovery

Now Playing uses blurred album artwork over a material background. Missing or unavailable artwork falls back to the system background.

Play, pause, stop, seek, shuffle, repeat, and volume changes are predicted immediately. Predictions are separate from server snapshots: rejected commands remove the prediction, while successful commands refresh authoritative state. A short reconciliation window accommodates devices that acknowledge before publishing their state. Commands are serialized, and playback commands are never replayed after reconnecting.

The Sendspin setting is stored independently of the audio connection. Enabling it persists across launches; disabling it cancels recovery and closes audio. While enabled, failed audio connections retry with exponential backoff capped at 30 seconds. Recovery preserves the selected speaker. The app must be running and permitted by the OS to execute; this setting does not bypass background execution restrictions.

Saved sessions open the main interface even when the server cannot be reached. Server connections retry with exponential backoff capped at 30 seconds, and users can retry from the offline banner or Connection settings. Foregrounding and restored network connectivity also trigger retries. Credentials remain in Keychain, including during outages or authentication failures; Connection settings exposes the last connection error and explicit sign-out.

The last successful library fetch is cached as display metadata scoped to the server. Offline browsing and local text search use that cache. It retains up to 500 previously loaded items per category, not the entire library, artwork, or downloaded audio. This offline snapshot limit does not limit online scrolling. Explicit sign-out clears this cache. Failed refreshes retain existing contents.

## Validation

- Core tests cover prediction clock freezing, resuming, seeking to zero, and mode changes, plus existing WebSocket authentication, cancellation, and disconnect behavior.
- macOS and iOS Simulator builds check platform compilation.
- Live-server acceptance: pause/play, seek, shuffle, repeat, and volume should update immediately; reject a command server-side and verify rollback.
- Enable Sendspin, quit and reopen, then interrupt only the audio socket and confirm automatic recovery without changing the selected room. Disable during retry and verify it stays disabled.
- Load a library, quit, disconnect the network, and reopen. Verify library browsing and search remain available without login. Restore connectivity and verify players/library refresh and Sendspin recovers.
- Sign out during a retry and verify the previous session does not reappear. Repeat with expired credentials and use Connection settings to inspect the error and sign in again.

Live-server and physical-device acceptance checks require a reachable Music Assistant server and have not been automated here.
