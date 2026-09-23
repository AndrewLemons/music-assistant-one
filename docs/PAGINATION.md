# Library and search pagination

Library screens request 100 items at a time with `offset` and `limit`. Filtering and sorting are performed by the server before pagination, so a match outside the first page can still be found. The Recently Added sort uses `timestamp_added_desc`; title and artist ordering use the server's named sort keys. Playlist artist sorting is omitted because playlists have no artist ordering.

Rows and artwork are rendered lazily. Approaching the last ten library items (five search results) requests the next page. A visible end-of-list control also loads more and provides an accessible manual action. No background loop downloads the entire library. Each list allows only one request at a time; failed pages retain their cursor and existing results until explicitly retried. Query changes are debounced and cancel previous requests. Generation checks reject late responses even when a transport ignores cancellation.

Music Assistant's global `music/search` endpoint accepts a per-type `limit`, but has no offset or cursor. Each search category therefore starts with 25 results and doubles its requested limit as the user scrolls. Existing results retain their order, and newly discovered URIs are appended once. Geometric growth bounds cumulative prefix transfer rather than repeatedly fetching all previous results for each fixed-size page. A short response or a response with no new URIs ends loading. Providers can impose their own result limits; the app cannot retrieve results the server does not expose.

Library offsets advance by the raw response length, independently of deduplication. Refreshes start at zero; snapshots are not transactional, so changes made to a library during scrolling can move items between pages. Pull to refresh to obtain a fresh ordering.

Online scrolling has no fixed item cap. In-memory metadata grows with the rows visited; artwork views remain lazy. The offline cache deliberately retains at most 500 items per category, and cache writes are debounced. It does not store search-provider result sets or downloaded audio.

## Verification

Core tests exercise a 237-track library and a 123-result search through the WebSocket fixture, including a server-side filter for track 234. Other tests cover overlapping pages, cursor advancement, exact page boundaries, expanding search limits, duplicate-only responses, failed-page retries, cancellation, and late responses after resetting a query.

Validation completed: 24 core tests passed, macOS and iOS Simulator builds passed, and the iPhone simulator library/presentation and search/filter UI tests passed. The macOS UI runner stalled before executing tests and was stopped; live provider pagination still needs a real-server acceptance check.

Contract references:

- [Music Assistant 2.10.1 library pagination and sort keys](https://github.com/music-assistant/server/blob/2.10.1/music_assistant/controllers/music/media/base.py)
- [Music Assistant 2.10.1 global search](https://github.com/music-assistant/server/blob/2.10.1/music_assistant/controllers/music/controller.py)
