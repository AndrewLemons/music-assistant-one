import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var useToken = false
    @State private var error: String?
    @State private var submitting = false
    @FocusState private var focusAddress: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 104, height: 104)
                        .background(.tint.opacity(0.08), in: .rect(cornerRadius: 28))
                        .accessibilityHidden(true)
                    Text("Your music.\nRight at home.")
                        .font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text("Connect to Music Assistant to bring your music and speakers together.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 18) {
                    if !model.discovery.servers.isEmpty {
                        Text("Nearby servers").font(.headline)
                        ForEach(model.discovery.servers) { server in
                            Button { address = server.address } label: {
                                HStack {
                                    Image(systemName: "server.rack").foregroundStyle(.tint)
                                    VStack(alignment: .leading) {
                                        Text(server.name).foregroundStyle(.primary)
                                        Text(server.address).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: address == server.address ? "checkmark.circle.fill" : "chevron.right")
                                }.padding(12).background(.quaternary, in: .rect(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server address").font(.subheadline.weight(.medium))
                        TextField("https://music.example.com", text: $address)
                            .textContentType(.URL).focused($focusAddress)
                            .accessibilityIdentifier("serverAddress")
                            #if os(iOS)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                            .textFieldStyle(.roundedBorder)
                        Text("Choose a nearby server or enter its address.").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Sign in with", selection: $useToken) {
                        Text("Account").tag(false)
                        Text("Access token").tag(true)
                    }.pickerStyle(.segmented)
                    if useToken {
                        SecureField("Access token", text: $token).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("accessToken")
                        Text("Create a long-lived token in Music Assistant → Settings → Profile.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Username", text: $username).textContentType(.username).textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                        SecureField("Password", text: $password).textContentType(.password).textFieldStyle(.roundedBorder)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: connect) {
                        HStack { Spacer(); if submitting { ProgressView().controlSize(.small) }; Text(submitting ? "Connecting…" : "Connect"); Spacer() }
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(submitting || address.isEmpty || (useToken ? token.isEmpty : username.isEmpty || password.isEmpty))
                    .accessibilityIdentifier("connectButton")
                    .keyboardShortcut(.defaultAction)
                }
                .padding(24)
                .background(.background, in: .rect(cornerRadius: 20))
                Text("Your server manages your music. Your credentials stay in this device’s Keychain.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24).padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(.background.secondary)
        .task {
            address = model.server?.baseURL.absoluteString ?? UserDefaults.standard.string(forKey: "serverAddress") ?? ""
            model.discovery.start()
        }
        .onDisappear { model.discovery.stop() }
        .disabled(model.connection == .connecting && !submitting)
    }
    private func connect() {
        submitting = true; error = nil
        Task {
            do {
                try await model.signIn(address: address, username: username, password: password, accessToken: useToken ? token : "")
                password = ""; token = ""
            } catch { self.error = error.localizedDescription }
            submitting = false
        }
    }
}

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Music Assistant") {
                    LabeledContent("Server", value: model.serverName)
                    if let address = model.server?.baseURL.absoluteString { Text(address).textSelection(.enabled).foregroundStyle(.secondary) }
                    if !model.serverVersion.isEmpty { LabeledContent("Version", value: model.serverVersion) }
                }
                Section {
                    Button("Disconnect and Choose Another Server", role: .destructive) {
                        Task { await model.disconnect(forget: true); dismiss() }
                    }
                } footer: { Text("Disconnecting stops playback on this device. Other speakers continue playing.") }
            }
            .formStyle(.grouped)
            .navigationTitle("Connection")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 340, minHeight: 300)
    }
}
