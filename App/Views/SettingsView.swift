import MusicAssistantCore
import SwiftUI

/// iPhone and iPad present settings as a sheet; Mac uses a native Settings window with tabs.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
            TabView {
                Tab("General", systemImage: "gearshape") {
                    Form {
                        AppearanceSection()
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
            .frame(width: 480, height: 500)
        #else
            NavigationStack {
                Form {
                    AppIdentitySection()
                    ServerSection()
                    AppearanceSection()
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

/// A status dot and text. Not a `Label`: as the value of a `LabeledContent` in a `Form`, a
/// label adopts the form's row layout and adds hundreds of points of empty height on iOS.
private struct ConnectionStatus: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var dot = 8.0
    var body: some View {
        let connected = model.connection == .connected
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: min(dot, 14)))
                .foregroundStyle(connected ? .green : .orange)
                .accessibilityHidden(true)
            Text(connected ? "Connected" : "Offline")
        }
        .foregroundStyle(.secondary)
    }
}

private struct AppearanceSection: View {
    @AppStorage(Accent.storageKey) private var accent = AccentRGB.default

    var body: some View {
        Section("Appearance") {
            #if os(macOS)
                LabeledContent("Accent Color") {
                    HStack(spacing: 8) {
                        AccentSwatches(selection: $accent, diameter: 16)
                        CustomAccentPicker(selection: $accent).labelsHidden()
                    }
                }
            #else
                AccentSwatches(selection: $accent, diameter: 28)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Accent Color")
                CustomAccentPicker(selection: $accent) {
                    SettingsLabel("Custom Color", symbol: "paintpalette.fill", color: accent.fill)
                }
            #endif
        }
    }
}

/// A row of curated accents. The selected one is ringed and checked.
private struct AccentSwatches: View {
    @Binding var selection: AccentRGB
    let diameter: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Accent.swatches, id: \.color) { swatch in
                let selected = swatch.color == selection
                Button { selection = swatch.color } label: {
                    Circle()
                        .fill(swatch.color.fill)
                        .frame(width: diameter, height: diameter)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: diameter * 0.45, weight: .bold))
                                    .foregroundStyle(swatch.color.foreground.fill)
                            }
                        }
                        .padding(diameter / 8)
                        .overlay {
                            if selected {
                                Circle().strokeBorder(swatch.color.fill, lineWidth: max(1.5, diameter / 14))
                            }
                        }
                    #if os(iOS)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    #else
                        .padding(.horizontal, 1)
                    #endif
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(swatch.name)
            }
        }
    }
}

/// The system color picker, for any accent. Transparency isn't offered.
private struct CustomAccentPicker<Label: View>: View {
    @Binding var selection: AccentRGB
    @ViewBuilder var label: Label

    var body: some View {
        ColorPicker(selection: Binding {
            selection.fill
        } set: { color in
            if let rgb = AccentRGB(color) {
                selection = rgb
            }
        }, supportsOpacity: false) { label }
    }
}

extension CustomAccentPicker where Label == Text {
    init(selection: Binding<AccentRGB>) {
        self.init(selection: selection) { Text("Custom Color") }
    }
}

private struct PlaybackSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            StreamingQualitySetting()
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
    /// Icons grow with text, as in the system Settings app, up to a size that leaves room for the title.
    @ScaledMetric(relativeTo: .body) private var iconSize = 28.0
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
                let size = min(iconSize, 40)
                Image(systemName: symbol)
                    .font(.system(size: size / 2, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(color.gradient, in: .rect(cornerRadius: size / 4))
            }
        #endif
    }
}

/// The app's glyph on an accent squircle, used where the app identifies itself.
struct AppGlyph: View {
    @Environment(\.accent) private var accent
    var size: CGFloat = 64
    var body: some View {
        Image(systemName: "music.note.house.fill")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(accent.onTint)
            .frame(width: size, height: size)
            .background(accent.tint.gradient, in: .rect(cornerRadius: size * 0.225))
            .accessibilityHidden(true)
    }
}

// MARK: - Accent color

/// The accent color setting. The app icon keeps the default.
enum Accent {
    static let storageKey = "accentColor"

    struct Swatch {
        let name: String
        let color: AccentRGB
    }

    /// System-like hues that read as text on light and dark backgrounds. The default is first.
    static let swatches: [Swatch] = [
        ("Sky", "#1ABCF2"), ("Blue", "#007AFF"), ("Indigo", "#5E5CE6"), ("Purple", "#AF52DE"),
        ("Pink", "#FF2D55"), ("Orange", "#F5820D"), ("Green", "#2DAA4F"), ("Graphite", "#8E8E93"),
    ].compactMap { name, hex in AccentRGB(hex: hex).map { Swatch(name: name, color: $0) } }
}

extension AccentRGB {
    /// Exactly this color, for swatches.
    var fill: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// The app tint. It adapts to light and dark appearance only as far as legibility requires.
    var tint: Color {
        adaptive { self.legible(on: $0 ? .darkBackground : .white) }
    }

    /// White or black symbols on a filled `tint`.
    var onTint: Color {
        adaptive { self.legible(on: $0 ? .darkBackground : .white).foreground }
    }

    /// Reads a picked color in sRGB. Extended-range components are clamped.
    init?(_ color: Color) {
        #if os(macOS)
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        #else
            var (red, green, blue, alpha) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
            self.init(red: red, green: green, blue: blue)
        #endif
    }

    private func adaptive(_ resolve: @escaping @Sendable (_ dark: Bool) -> AccentRGB) -> Color {
        #if os(macOS)
            Color(nsColor: NSColor(name: nil) { appearance in
                let rgb = resolve(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
                return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            })
        #else
            Color(uiColor: UIColor { traits in
                let rgb = resolve(traits.userInterfaceStyle == .dark)
                return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            })
        #endif
    }
}

extension EnvironmentValues {
    /// The chosen accent, for views that fill with it or need its foreground.
    @Entry var accent = AccentRGB.default
}

/// Applies the accent setting. Use at the root of every window and the Mac Settings window.
private struct AccentTint: ViewModifier {
    @AppStorage(Accent.storageKey) private var accent = AccentRGB.default
    func body(content: Content) -> some View {
        content.tint(accent.tint).environment(\.accent, accent)
    }
}

extension View {
    func accentTint() -> some View {
        modifier(AccentTint())
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
