# Native music experience

The interface follows Apple Music's navigation and playback hierarchy, adding Music Assistant's library, provider search, and speaker control. It uses existing Music Assistant commands; provider administration stays on the server.

## Principles

- Native controls first: `List`, `Form`, `ContentUnavailableView`, toolbars, and system search. Liquid Glass is reserved for floating controls (mini player, Now Playing buttons, offline banner), not content.
- Copy is short and functional. Titles name things ("No Downloads", "Offline", "Not Playing"); there are no taglines, and footers appear only when they add information the control can't show.
- One component per concept, shared everywhere: `ArtworkView`, `AlbumCard`, `MediaRow`, `MoreMenu`, `MediaActions`, `PlayShuffleButtons`, `PlaybackButton`, and `PlayerVolume` (`App/Views/Components`).
- Every icon-only control has an accessibility label. State is never conveyed by color alone. iOS targets are at least 44 points. Fixed-height bars cap Dynamic Type as system bars do.

## Navigation and library

- iPhone/iPad: Home, Library, and Search tabs. Home shows Music Assistant's recommendation rows (Recently Played, Recently Added, and the rest the server provides) as horizontal shelves with See All. Shelves are cached per server, so Home appears instantly at launch and offline. The Library index lists Playlists, Artists, Albums, Songs, and Downloaded, followed by Recently Added with See All. Speakers are chosen from the output button in the mini player and Now Playing. A toolbar button opens Settings.
- Mac: a sidebar with Home, Search, Players, and a Library section (Recently Added, Playlists, Artists, Albums, Songs, Downloaded). The server name and connection status sit at the bottom of the sidebar and open the Settings window.
- Each tab has its own navigation stack of value routes (`App/Navigation.swift`), registered once per stack. A tap pushes exactly one page, Back returns to the page it came from, and choosing the selected tab again returns to its first page. Grids and shelves are never placed inside a single `List` row, where SwiftUI activates every link in the row.
- Tapping artwork or a title opens the album, playlist, or artist. Tapping a song plays its list from that song, as in Apple Music. Long-press shows the actions menu with a preview. Now Playing's title and artist lines go to the album and artist.
- Categories have a local filter and a sort menu, which survive Now Playing and switching categories. Offline state appears as a navigation subtitle.
- Album cards are a single accessible element with a Play action. On Mac, hovering shows Play and More controls over the artwork.
- Song rows show artwork, favorite and download badges, duration, and a "•••" menu. On iOS, swiping right offers Play Next and Add to Queue.
- Album and playlist pages have a centered header with Play and Shuffle, and download state in the toolbar. Album tracks are numbered and show the artist only when it differs from the album's. Albums end with More by the artist.
- Artist pages have Play and Shuffle, Top Songs, and shelves for Albums, Singles & EPs, and Compilations.
- Artwork requests a size from Music Assistant's image proxy that covers the view's pixel size, and is cached on disk and in memory.

## Search

Browse tiles select a category and focus the search field. With a query, category chips appear above the results. All shows up to five results per category, with See All. A single category paginates through its full results. Changing category reuses the current provider response without clearing the query. On iOS the field stays visible in the navigation bar, because the search tab doesn't present one consistently across releases.

## Playback

The iOS mini player is the tab bar accessory, with the output button (tinted while a speaker plays), play/pause, and next. Swiping the title changes songs. When the tab bar minimizes, it keeps only play/pause. Loading appears as a spinner in the play button, only after 400 ms, so quick starts never flash one. Now Playing is a sheet with artwork, which recedes while paused, plus favorite and More buttons, a scrubber, transport, volume, the output picker, AirPlay, and Queue. On iOS, controls use the primary color over a blurred-artwork background.

Mac Now Playing replaces the browser within its window. Escape or the close button returns; Command-Shift-N toggles. The Queue panel is a toolbar toggle. The floating mini player belongs to the window rather than the detail column, because pushing a page replaces that column's view hierarchy.

The Queue shows Now Playing and Playing Next, with drag-to-reorder and per-song menus. Shuffle and repeat expose their state to VoiceOver. Speaker selection uses speaker symbols, since Music Assistant controls more than AirPlay.

## Device listening and downloads

The output picker presents This Device, speakers, and groups, not audio engines. Independent listening prefers downloaded and cached audio; synchronized groups use Sendspin.

Downloaded shows Play and Shuffle, active downloads, saved albums and playlists, and songs. A navigation subtitle gives the song count and size. Each active download has a progress ring that pauses or resumes it, and swipe or context menu cancels. Failed downloads show their reason and a retry button. Without the audio companion, Downloaded explains that it's required and links to setup.

## Settings

iOS uses one grouped form: app identity, server (details and Sign Out), playback, storage (cellular downloads, sizes, clear cache), about (help, privacy, acknowledgments), and Erase Local Data. Mac uses a Settings window with General, Storage, and About tabs that share the same sections.
