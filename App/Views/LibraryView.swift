import SwiftUI
import MusicAssistantCore

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var category = "Albums"
    private let categories = ["Albums", "Playlists", "Songs"]
    private var items: [MediaItem] {
        switch category { case "Playlists": model.playlists; case "Songs": model.tracks; default: model.albums }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Library category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420).padding(.top, 12)
                Text(category == "Albums" ? "Recently Added" : category).font(.title2.bold())
                if model.isDemo { Label("Interface preview", systemImage: "eye").font(.caption).foregroundStyle(.secondary) }
                if model.libraryLoading {
                    ProgressView("Loading your library…").frame(maxWidth: .infinity).padding(60)
                } else if let error = model.libraryError {
                    ContentUnavailableView {
                        Label("Library Unavailable", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: { Button("Try Again") { Task { await model.loadLibrary() } } }
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label("Your \(category.lowercased()) will appear here", systemImage: "music.note")
                    } description: { Text("Search music from your connected services to start listening.") }
                } else if category == "Songs" {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in MediaRow(item: item); Divider().padding(.leading, 64) }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 230), spacing: 22)], alignment: .leading, spacing: 28) {
                        ForEach(items) { item in AlbumCard(item: item) }
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 30)
        }
        .navigationTitle("Library")
        .toolbar { ToolbarItem(placement: .primaryAction) {
            Button { model.showConnection = true } label: { Image(systemName: "person.crop.circle") }
                .accessibilityLabel("Connection settings")
        } }
        .refreshable { await model.loadLibrary() }
    }
}

struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem?
    var cornerRadius: CGFloat = 10
    var body: some View {
        AsyncImage(url: item?.artworkURL(server: model.server)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay { Image(systemName: item?.kind == "playlist" ? "music.note.list" : "music.note").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary) }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var body: some View {
        Button { Task { await model.play(item) } } label: {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(item: item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(item.name), \(item.subtitle)")
        .contextMenu { MediaActions(item: item) }
    }
}

struct MediaRow: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await model.play(item) } } label: {
                HStack(spacing: 12) {
                    ArtworkView(item: item, cornerRadius: 7).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).foregroundStyle(.primary).lineLimit(1)
                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if item.duration > 0 { Text(formatTime(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu { MediaActions(item: item) } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More options for \(item.name)")
        }.padding(.vertical, 8)
        .contextMenu { MediaActions(item: item) }
    }
}

struct MediaActions: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var body: some View {
        Button("Play", systemImage: "play.fill") { Task { await model.play(item) } }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { Task { await model.play(item, option: "next") } }
        Button("Add to Queue", systemImage: "text.badge.plus") { Task { await model.play(item, option: "add") } }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let value = Int(max(0, seconds))
    return "\(value / 60):\(String(format: "%02d", value % 60))"
}
