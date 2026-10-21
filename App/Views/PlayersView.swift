import MusicAssistantCore
import SwiftUI

struct PlayersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    private var speakers: [Player] {
        model.availablePlayers.filter { !model.isLocalPlayer($0) }
    }

    var body: some View {
        List {
            Section {
                thisDevice
                if model.deviceIsGrouped, model.independentAudioAvailable {
                    Button("Listen Separately", systemImage: "iphone.and.arrow.forward") {
                        Task { await model.listenSeparately() }
                    }
                    .disabled(model.connection != .connected)
                }
                if model.connection == .connected, !model.deviceGroupTargets.isEmpty {
                    Menu("Play with Speakers", systemImage: "hifispeaker.2") {
                        ForEach(model.deviceGroupTargets) { target in
                            Button(target.name) { Task { await model.joinThisDevice(to: target) } }
                        }
                    }
                    .disabled(model.commandInFlight || model.isDemo)
                }
                if let error = model.devicePlaybackError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Speakers") {
                if speakers.isEmpty {
                    Text("No speakers available").foregroundStyle(.secondary)
                }
                ForEach(speakers) { SpeakerRow(player: $0, isSheet: isSheet) }
            }
        }
        .navigationTitle("Players")
        #if os(iOS)
            .navigationBarTitleDisplayMode(isSheet ? .inline : .automatic)
        #endif
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
            .refreshable {
                do { try await model.refreshPlayers() } catch { model.error = error.localizedDescription }
            }
        #if os(macOS)
            .frame(minWidth: 430, minHeight: 380)
        #endif
    }

    private var thisDevice: some View {
        Button {
            Task {
                await model.startLocalPlayer()
                if isSheet {
                    dismiss()
                }
            }
        } label: {
            PlayerRowLabel(
                name: "This Device",
                detail: model.devicePlaybackStatus,
                symbol: localSymbol,
                isActive: true,
                isSelected: model.selectedPlayer.map(model.isLocalPlayer) == true,
                isBusy: model.local.isStarting && !model.usesIndependentPlayback
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.selectedPlayer.map(model.isLocalPlayer) == true ? .isSelected : [])
        .accessibilityIdentifier("selectThisDevice")
        .disabled(model.isDemo)
    }

    private var localSymbol: String {
        #if os(macOS)
            "laptopcomputer"
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }
}

private struct SpeakerRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let player: Player
    let isSheet: Bool

    private var isSelected: Bool {
        player.id == model.selectedPlayerID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    model.selectPlayer(player)
                    if isSheet {
                        dismiss()
                    }
                } label: {
                    PlayerRowLabel(
                        name: player.name,
                        detail: detail,
                        symbol: player.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill",
                        isActive: player.available,
                        isSelected: isSelected
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .disabled(!player.available || model.connection != .connected)
                MoreMenu("Group options for \(player.name)") { groupActions }
                    .disabled(model.commandInFlight || !player.available)
            }
            if isSelected, model.showsVolume(for: player) {
                PlayerVolume(player: player).padding(.leading, 48)
            }
        }
    }

    @ViewBuilder private var groupActions: some View {
        let targets = model.availablePlayers.filter { player.canJoin($0) }
        if !targets.isEmpty {
            Section("Group With") {
                ForEach(targets) { target in
                    Button(target.name) { Task { await model.join(player, to: target) } }
                }
            }
        }
        if player.canLeave {
            Button("Leave Group", systemImage: "rectangle.portrait.and.arrow.right") {
                Task { await model.ungroup(player) }
            }
        }
        if targets.isEmpty, !player.canLeave {
            Text("No Compatible Speakers")
        }
    }

    private var detail: String {
        if !player.available {
            return "Unavailable"
        }
        if let leader = player.leader {
            return "Grouped with \(model.players.first { $0.id == leader }?.name ?? "Another Player")"
        }
        let state = switch player.state {
        case "playing": "Playing"
        case "paused": "Paused"
        default: "Not Playing"
        }
        return player.members.count > 1 ? "\(player.members.count) Speakers · \(state)" : state
    }
}

/// Icon, name, status, and selection mark shared by This Device and speakers.
private struct PlayerRowLabel: View {
    let name: String
    let detail: String
    let symbol: String
    var isActive: Bool
    var isSelected: Bool
    var isBusy = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if isSelected {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
