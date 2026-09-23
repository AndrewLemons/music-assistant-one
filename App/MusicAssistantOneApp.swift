import SwiftUI

@main
struct MusicAssistantOneApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.accentColor)
                .task { await model.start() }
            #if os(macOS)
                .frame(minWidth: 760, minHeight: 560)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Connection Settings…") { model.showConnection = true }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(model.connection == .disconnected || model.connection == .connecting)
            }
            CommandMenu("Playback") {
                Button(model.showNowPlaying ? "Close Now Playing" : "Show Now Playing") { model.showNowPlaying.toggle()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.connection == .disconnected || model.connection == .connecting)
                Divider()
                Button("Play / Pause") { Task { await model.togglePlayback() } }.keyboardShortcut(.space, modifiers: [])
                    .disabled(!model.canControl)
                Button("Next Track") { Task { await model.playback("next") } }.keyboardShortcut(
                    .rightArrow,
                    modifiers: [.command]
                ).disabled(!model.canControl)
                Button("Previous Track") { Task { await model.playback("previous") } }.keyboardShortcut(
                    .leftArrow,
                    modifiers: [.command]
                ).disabled(!model.canControl)
                Divider()
                Button("Choose Player…") { model.showPlayers = true }.keyboardShortcut(
                    "p",
                    modifiers: [.command, .shift]
                )
            }
        }
        #endif
        #if os(macOS)
            Settings { ConnectionSettings().environment(model).frame(width: 480) }
        #endif
    }
}
