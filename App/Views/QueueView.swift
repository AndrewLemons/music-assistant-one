import MusicAssistantCore
import SwiftUI

/// The current song and what plays next, with drag-to-reorder.
struct QueueContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if model.queueLoading, model.queueItems.isEmpty {
                ProgressView()
            } else if let error = model.queueError {
                ContentUnavailableView {
                    Label("Queue Unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await model.loadQueueItems() } }
                }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.queue?.id) { await model.loadQueueItems() }
        .onChange(of: model.queue) { _, _ in Task { await model.loadQueueItems() } }
    }

    private var list: some View {
        List {
            if let current = model.current {
                Section("Now Playing") {
                    HStack(spacing: 12) {
                        ArtworkView(item: current, cornerRadius: 6).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.name)
                            Text(current.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "waveform")
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: model.queue?.isPlaying == true)
                            .accessibilityHidden(true)
                        MoreMenu("Current song options") { MediaActions(item: current, isCurrent: true) }
                    }
                    .contextMenu { MediaActions(item: current, isCurrent: true) }
                }
            }
            Section("Playing Next") {
                if model.upcomingQueueItems.isEmpty {
                    Text("Nothing Up Next").foregroundStyle(.secondary)
                }
                ForEach(model.upcomingQueueItems) { entry in
                    queueRow(entry)
                }
                .onMove { source, destination in
                    let items = model.upcomingQueueItems
                    guard source.count == 1, let index = source.first,
                          let shift = QueueOrder.shift(
                              source: index,
                              destination: destination,
                              count: items.count
                          )
                    else { return }
                    Task { await model.moveQueueItem(items[index].id, shift: shift) }
                }
                .moveDisabled(!model.canControl || model.queueEditing)
            }
        }
        .scrollContentBackground(.hidden)
        #if os(iOS)
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
        #else
            // Matches the inspector and popover material; no edge-to-edge hairlines.
            .listStyle(.sidebar)
        #endif
    }

    private func queueRow(_ entry: QueueEntry) -> some View {
        HStack(spacing: 4) {
            Button { Task { await model.queueCommand("play_index", args: ["index": .string(entry.id)]) } } label: {
                HStack(spacing: 12) {
                    ArtworkView(item: entry.media, cornerRadius: 6).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.media.name).foregroundStyle(.primary)
                        Text(entry.media.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!model.canControl || model.queueEditing)
            .accessibilityLabel("Play \(entry.media.name), \(entry.media.subtitle)")
            MoreMenu("More options for \(entry.media.name)") { queueActions(entry) }
        }
        .contextMenu { queueActions(entry) }
        .accessibilityAction(named: "Move Up") { Task { await model.moveQueueItem(entry.id, shift: -1) } }
        .accessibilityAction(named: "Move Down") { Task { await model.moveQueueItem(entry.id, shift: 1) } }
    }

    @ViewBuilder private func queueActions(_ entry: QueueEntry) -> some View {
        MediaActions(item: entry.media)
        Section {
            Button("Move Up", systemImage: "arrow.up") { Task { await model.moveQueueItem(entry.id, shift: -1) } }
                .disabled(model.upcomingQueueItems.first?.id == entry.id)
            Button("Move Down", systemImage: "arrow.down") { Task { await model.moveQueueItem(entry.id, shift: 1) } }
                .disabled(model.upcomingQueueItems.last?.id == entry.id)
            Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
                Task {
                    await model.queueCommand("delete_item", args: ["item_id_or_index": .string(entry.id)])
                    await model.loadQueueItems()
                }
            }
        }
        .disabled(!model.canControl || model.queueEditing)
    }
}

/// iOS presents the queue as a sheet; Mac shows it in a popover from the mini player.
struct QueueView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        #if os(iOS)
            NavigationStack {
                QueueContent()
                    .navigationTitle("Queue")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { dismiss() }
                        }
                    }
            }
            .modifier(PlaylistPresentation())
            .presentationDetents([.medium, .large])
        #else
            QueueContent()
                .frame(width: 360, height: 460)
                .modifier(PlaylistPresentation())
        #endif
    }
}
