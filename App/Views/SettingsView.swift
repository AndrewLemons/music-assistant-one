import SwiftUI

/// iPhone and iPad present settings as a sheet; Mac uses a native Settings window with tabs.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
            TabView {
                Tab("General", systemImage: "gearshape") {
                    Form {
                        ServerSection()
                        PlaybackSection()
                    }
                    .formStyle(.grouped)
                }
                Tab("Storage", systemImage: "internaldrive") {
                    Form { StorageSection() }.formStyle(.grouped)
                }
                Tab("About", systemImage: "info.circle") {
                    NavigationStack {
                        Form {
                            AppIdentitySection()
                            AboutSection()
                            EraseSection()
                        }
                        .formStyle(.grouped)
                    }
                }
            }
            .frame(width: 480, height: 440)
        #else
            NavigationStack {
                Form {
                    AppIdentitySection()
                    ServerSection()
                    PlaybackSection()
                    StorageSection()
                    AboutSection()
                    EraseSection()
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
        #endif
    }
}

// MARK: - Sections

private struct AppIdentitySection: View {
    var body: some View {
        Section {
            HStack(spacing: 14) {
                AppGlyph(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Music Assistant One").font(.headline)
                    Text("Version \(AppInfo.version)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct ServerSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section("Server") {
            if model.isDemo {
                LabeledContent { Text("Preview") } label: {
                    SettingsLabel("Server", symbol: "server.rack", color: .blue)
                }
                Button("Connect to a Server") {
                    Task { await model.disconnect(); dismiss() }
                }
            } else {
                #if os(macOS)
                    ServerDetails()
                #else
                    NavigationLink {
                        Form { ServerDetails() }.navigationTitle(model.serverName)
                    } label: {
                        LabeledContent {
                            ConnectionStatus()
                        } label: {
                            SettingsLabel(model.serverName, symbol: "server.rack", color: .blue)
                        }
                    }
                #endif
            }
        }
    }
}

/// Address, version, and connection controls for the signed-in server.
private struct ServerDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    var body: some View {
        Group {
            #if os(macOS)
                LabeledContent("Name", value: model.serverName)
            #endif
            if let address = model.server?.baseURL.absoluteString {
                LabeledContent("Address") { Text(address).textSelection(.enabled) }
            }
            if !model.serverVersion.isEmpty {
                LabeledContent("Version", value: model.serverVersion)
            }
            LabeledContent("Status") { ConnectionStatus() }
            if model.connection != .connected {
                if let error = model.connectionError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Retry Connection") { model.retryConnection() }
            }
            Button("Sign Out…", role: .destructive) { confirmingSignOut = true }
        }
        .confirmationDialog("Sign out of \(model.serverName)?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) {
                Task { await model.disconnect(forget: true); dismiss() }
            }
        } message: {
            Text("Playback on this device stops. Speakers keep playing.")
        }
    }
}

private struct ConnectionStatus: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let connected = model.connection == .connected
        Label {
            Text(connected ? "Connected" : "Offline")
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(connected ? .green : .orange)
        }
        .labelIconToTitleSpacing(6)
        .foregroundStyle(.secondary)
    }
}

private struct PlaybackSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.localPlayerEnabled },
                set: { enabled in Task { await model.enableSharedPlayback(enabled) } }
            )) {
                SettingsLabel("Available to Other Devices", symbol: "hifispeaker.2.fill", color: .purple)
            }
            .disabled(model.isDemo || (model.connection != .connected && !model.localPlayerEnabled))
        } header: {
            Text("Playback")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Other Music Assistant apps can play to this device and group it with speakers.")
                if !model.isDemo, model.localPlayerEnabled {
                    Text("Status: \(model.local.status)")
                }
                if let error = model.local.error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
    }
}

private struct StorageSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            #if os(iOS)
                Toggle(isOn: Binding(
                    get: { model.downloads.allowCellular },
                    set: { model.downloads.allowCellular = $0 }
                )) {
                    SettingsLabel("Download over Cellular", symbol: "antenna.radiowaves.left.and.right", color: .green)
                }
            #endif
            LabeledContent {
                Text(model.downloads.downloadBytes.fileSize)
            } label: {
                SettingsLabel("Downloads", symbol: "arrow.down", color: .blue)
            }
            LabeledContent {
                Text(model.downloads.cacheBytes.fileSize)
            } label: {
                SettingsLabel("Listening Cache", symbol: "internaldrive.fill", color: .gray)
            }
            Button("Clear Listening Cache") {
                Task { await model.downloads.clearCache(protecting: model.deviceAudio.protectedURIs) }
            }
            .disabled(model.downloads.cacheBytes == 0)
        } header: {
            #if os(iOS)
                Text("Storage") // The Mac tab already names it.
            #endif
        } footer: {
            #if os(iOS)
                Text("Upcoming songs are cached on Wi-Fi, up to 512 MB. Downloads are kept until removed.")
            #else
                Text("Upcoming songs are cached, up to 512 MB. Downloads are kept until removed.")
            #endif
        }
    }
}

private struct AboutSection: View {
    var body: some View {
        Section("About") {
            ExternalLink(destination: AppLinks.support) {
                SettingsLabel("Help & Support", symbol: "questionmark", color: .blue)
            }
            ExternalLink(destination: AppLinks.privacy) {
                SettingsLabel("Privacy Policy", symbol: "hand.raised.fill", color: .indigo)
            }
            NavigationLink { AcknowledgmentsView() } label: {
                SettingsLabel("Acknowledgments", symbol: "doc.text", color: .gray)
            }
        }
    }
}

private struct EraseSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        Section {
            Button("Erase Local Data…", role: .destructive) { confirming = true }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .alert("Erase Local Data?", isPresented: $confirming) {
            Button("Erase", role: .destructive) {
                Task {
                    do { try await model.eraseLocalData(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes sign-in, downloads, cache, and settings from this device. Your server isn’t affected.")
        }
    }
}

// MARK: - Acknowledgments

private struct AcknowledgmentsView: View {
    private let text: String = ["THIRD_PARTY_NOTICES", "NOTICE", "LICENSE"]
        .compactMap { name in
            Bundle.main.url(forResource: name, withExtension: name == "THIRD_PARTY_NOTICES" ? "md" : nil)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        .joined(separator: "\n\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.hasPrefix("```") }
        .joined(separator: "\n")

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Acknowledgments")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #else
            .frame(minWidth: 480, minHeight: 400)
        #endif
    }
}

// MARK: - Shared

/// A settings row that opens a web page, marked so it's clear it leaves the app.
private struct ExternalLink<Label: View>: View {
    let destination: URL
    @ViewBuilder let label: Label
    var body: some View {
        Link(destination: destination) {
            LabeledContent {
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            } label: {
                label
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
    }
}

/// A settings row label. iOS uses Settings-style colored icons; Mac forms use plain text.
struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color
    init(_ title: String, symbol: String, color: Color) {
        self.title = title; self.symbol = symbol; self.color = color
    }

    var body: some View {
        #if os(macOS)
            Text(title)
        #else
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient, in: .rect(cornerRadius: 7))
            }
        #endif
    }
}

/// The app's glyph on an accent squircle, used where the app identifies itself.
struct AppGlyph: View {
    var size: CGFloat = 64
    var body: some View {
        Image(systemName: "music.note.house.fill")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.accentColor.gradient, in: .rect(cornerRadius: size * 0.225))
            .accessibilityHidden(true)
    }
}

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
}

enum AppLinks {
    static let audioCompanion =
        URL(string: "https://github.com/AndrewLemons/music-assistant-one/blob/main/ServerCompanion/README.md")!
    static let privacy = URL(string: "https://github.com/AndrewLemons/music-assistant-one/blob/main/PRIVACY.md")!
    static let support = URL(string: "https://github.com/AndrewLemons/music-assistant-one/issues")!
}
