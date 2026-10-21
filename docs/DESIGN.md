# Native music experience

The redesign uses Apple Music's navigation and playback hierarchy with Music Assistant's library, provider search, and speaker controls. The client continues to use the existing Music Assistant commands; provider administration stays on the server.

## Navigation and library

- Mac: Search, a Library section with Recently Added, Albums, Songs, and Playlists, and a separate Players destination. Categories are destinations rather than a second set of tabs within Library.
- iPhone/iPad: a Library index leads to each category, with recent albums below it. Native adaptive tabs remain available for Library, Players, and Search.
- Each category has a local text filter and a sort menu. Filter/sort selections survive opening Now Playing and switching categories within the window.
- Artwork has proportional placeholders, subtle borders, readable titles, visible action menus, and a pointer play affordance. Songs retain duration and queue actions.
- Mac connection settings have one labeled sidebar entry. Mobile has one gear button in Library. Native Mac Settings and keyboard/menu access remain available.

## Search

The search field is always visible on mobile. Filters cover All, Songs, Albums, Artists, Playlists, and Radio, including a specific no-results state with a way back to all results. The empty page offers shortcuts that select a category and focus search; it does not invent genres or recommendations that the server hasn't provided.

Filters operate on the existing provider search response, so changing category does not clear the query or start another network request. The selected category survives Now Playing. The Mac window owns the playback bar's layout, keeping it anchored independently of empty, loading, and result views.

## Playback

Mac Now Playing replaces the browser within its existing window. Escape or the leading close button returns to browsing; Command-Shift-N toggles the view. Artwork and playback sit alongside a toggleable Playing Next panel. Artwork scales down for short windows, and the content remains scrollable for long metadata.

The Mac bar exposes shuffle, previous, play/pause, next, repeat, queue, speaker selection, and volume. Transport buttons share symbol weights, tooltips, and accessibility labels. Shuffle and repeat expose their state. Speaker selection uses speaker symbols because Music Assistant can control multiple kinds of players, beyond AirPlay.

On mobile, Now Playing remains a native dismissible presentation, with the system route picker available for local audio. Queue loading, errors, retry, and empty states are explicit. Volume resynchronizes when changing players.

## Scope

Library filtering and sorting use progressive server pagination. Search expands within provider limits, and remote queue pages load until complete. Independent playback and downloads add a device-owned queue and offline library. Lyrics, dedicated artist detail pages, and provider administration remain outside this interface.

## Device listening and downloads

The output picker presents This Device, speakers, and groups. It does not present audio engines. Independent listening prefers downloaded and cached audio; synchronized groups use Sendspin. Downloaded is a first-class library destination with Play/Shuffle, search, completed collections, progress, pause/resume, retry, cancellation, and storage controls. Album and playlist details expose Download directly, and track menus use the same download actions everywhere. Download icons include accessible text; statuses do not depend on color. Offline metadata and missing audio have distinct states.

Native controls retain Dynamic Type and VoiceOver semantics. iOS transport buttons use at least 44-point targets. Full-track preparation has a visible buffering state; failures leave an actionable, paused queue. Storage details live on a separate Settings page, keeping the primary settings navigation concise. AirPlay remains the system route picker for local audio.
