import SwiftUI
import MusicAssistantCore

struct PlayersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isSheet = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: localSymbol).font(.title2).foregroundStyle(.tint).frame(width: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This Device").font(.headline)
                        Text(model.local.status).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.local.isStarting { ProgressView() }
                    Toggle("Enable Sendspin", isOn: Binding(
                        get: { model.localPlayerEnabled },
                        set: { enabled in Task {
                            if enabled { await model.startLocalPlayer() } else { await model.stopLocalPlayer() }
                        } }
                    )).labelsHidden().disabled(model.isDemo)

                }.padding(.vertical, 8)
                if let error = model.local.error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: { Text("Listen here") } footer: {
                Text("Keep this device enabled as a Sendspin player, including after reopening the app. Audio reconnects automatically when the server is available.")
            }
            Section {
                if model.availablePlayers.isEmpty {
                    ContentUnavailableView("No Players Available", systemImage: "hifispeaker", description: Text("Enable this device or connect a player in Music Assistant."))
                }
                ForEach(model.availablePlayers) { player in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Button {
                                model.selectedPlayerID = player.id
                                if isSheet { dismiss() }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: player.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                                        .font(.title2).foregroundStyle(player.available ? Color.accentColor : .secondary).frame(width: 34)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(player.name).foregroundStyle(.primary)
                                        Text(detail(player)).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if player.id == model.selectedPlayerID { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!player.available)
                            Menu {
                                let targets = model.availablePlayers.filter { player.canJoin($0) }
                                if !targets.isEmpty {
                                    Section("Join a group") {
                                        ForEach(targets) { target in
                                            Button(target.name) { Task { await model.join(player, to: target) } }
                                        }
                                    }
                                }
                                if player.canLeave { Button("Leave Group") { Task { await model.ungroup(player) } } }
                                if targets.isEmpty && !player.canLeave { Text("No compatible groups available") }
                            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.commandInFlight || !player.available)
                            .accessibilityLabel("Group options for \(player.name)")
                        }
                        if player.id == model.selectedPlayerID, player.volume != nil {
                            PlayerVolume(player: player).padding(.leading, 48)
                        }
                    }.padding(.vertical, 6)
                }
            } header: { Text("Speakers & groups") } footer: {
                Text("Choose a player to control it. Use its menu to join or leave a compatible group.")
            }
        }
        .navigationTitle("Players")
        .toolbar {
            if isSheet { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .refreshable {
            do { try await model.refreshPlayers() } catch { model.error = error.localizedDescription }
        }
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 380)
        #endif
    }
    private var localSymbol: String {
        #if os(macOS)
        "laptopcomputer"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }
    private func detail(_ player: Player) -> String {
        if !player.available { return "Offline" }
        if let leader = player.leader { return "Grouped with \(model.players.first { $0.id == leader }?.name ?? "another player")" }
        if player.members.count > 1 { return "\(player.members.count) speakers · \(player.state.capitalized)" }
        return player.state == "idle" ? "Ready to play" : player.state.capitalized
    }
}

struct PlayerVolume: View {
    @Environment(AppModel.self) private var model
    let player: Player
    @State private var draft: Double = 0
    @State private var editing = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            // Keep the control continuous to avoid tick marks; setVolume rounds the command.
            Slider(value: $draft, in: 0...100) { Text("Volume") } onEditingChanged: { active in
                editing = active
                if !active { Task { await model.setVolume(draft, player: player) } }
            }
            .labelsHidden()
            .controlSize(.small)
            .tint(.primary)
            .accessibilityValue("\(Int(draft.rounded())) percent")
            .disabled(!model.canControl)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .onAppear { draft = player.volume ?? 0 }
        .onChange(of: player.volume) { _, value in if !editing { draft = value ?? 0 } }
        .onChange(of: player.id) { _, _ in editing = false; draft = player.volume ?? 0 }
    }
}
