import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    private let sections = [("track", "Songs"), ("album", "Albums"), ("artist", "Artists"), ("playlist", "Playlists"), ("radio", "Radio")]
    var body: some View {
        @Bindable var model = model
        Group {
            if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Find your next favorite", systemImage: "magnifyingglass", description: Text("Search songs, albums, artists, and playlists across your music services."))
            } else if model.searching {
                ProgressView("Searching your music…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.searchError {
                ContentUnavailableView("Search Unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if model.searchResults.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                List {
                    ForEach(sections, id: \.0) { kind, name in
                        let items = model.searchResults.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Section(name) { ForEach(items) { item in MediaRow(item: item) } }
                        }
                    }
                }.listStyle(.plain)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $model.searchText, prompt: "Songs, albums, artists, and more")
        .task(id: model.searchText) { await model.search() }
    }
}
