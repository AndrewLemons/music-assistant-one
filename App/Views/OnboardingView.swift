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
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case address, username, password, token }

    private var canConnect: Bool {
        !submitting && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (useToken ? !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty :
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 80, height: 80)
                        .background(.tint.opacity(0.08), in: .rect(cornerRadius: 22))
                        .accessibilityHidden(true)
                    Text("Your music.\nRight at home.")
                        .font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text("Connect to Music Assistant to bring your music and speakers together.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 20) {
                    nearbyServers
                    VStack(alignment: .leading, spacing: 8) {
                        SetupFieldRow("Server address") {
                            HStack(spacing: 8) {
                                TextField("music.example.com", text: $address)
                                    .textContentType(.URL)
                                    .focused($focusedField, equals: .address)
                                    .accessibilityLabel("Server address")
                                    .accessibilityIdentifier("serverAddress")
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = useToken ? .token : .username }
                                    #if os(iOS)
                                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    #endif
                                if focusedField == .address && !address.isEmpty {
                                    Button {
                                        address = ""
                                        focusedField = .address
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Clear server address")
                                }
                            }
                        }
                        .background(fieldBackground, in: .rect(cornerRadius: 14))
                        .overlay { focusOutline(active: focusedField == .address) }
                        Text("Choose a nearby server or enter its address.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Sign in with", selection: $useToken) {
                            Text("Account").tag(false)
                            Text("Access token").tag(true)
                        }.pickerStyle(.segmented)

                        VStack(spacing: 0) {
                            if useToken {
                                SetupFieldRow("Access token") {
                                    SecureField("Paste your token", text: $token)
                                        .focused($focusedField, equals: .token)
                                        .accessibilityLabel("Access token")
                                        .accessibilityIdentifier("accessToken")
                                        .submitLabel(.go)
                                        .onSubmit(connect)
                                        #if os(iOS)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        #endif
                                }
                            } else {
                                SetupFieldRow("Username") {
                                    TextField("Your Music Assistant username", text: $username)
                                        .textContentType(.username)
                                        .focused($focusedField, equals: .username)
                                        .accessibilityLabel("Username")
                                        .accessibilityIdentifier("username")
                                        .submitLabel(.next)
                                        .onSubmit { focusedField = .password }
                                        #if os(iOS)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        #endif
                                }
                                Divider().padding(.horizontal, 16)
                                SetupFieldRow("Password") {
                                    SecureField("Enter your password", text: $password)
                                        .textContentType(.password)
                                        .focused($focusedField, equals: .password)
                                        .accessibilityLabel("Password")
                                        .accessibilityIdentifier("password")
                                        .submitLabel(.go)
                                        .onSubmit(connect)
                                }
                            }
                        }
                        .background(fieldBackground, in: .rect(cornerRadius: 14))
                        .overlay { focusOutline(active: focusedField != nil && focusedField != .address) }

                        if useToken {
                            Text("Create a long-lived token in Music Assistant → Settings → Profile.")
                                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                        }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if submitting { ProgressView().controlSize(.small) }
                            Text(submitting ? "Connecting…" : "Connect")
                            Spacer()
                        }.padding(.vertical, 5)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(!canConnect)
                    .accessibilityIdentifier("connectButton")
                    .keyboardShortcut(.defaultAction)
                }
                .disabled(submitting)

                Text("Your access token is stored securely in Keychain. Your password isn’t saved.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 24).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(pageBackground)
        .task {
            address = model.server?.baseURL.absoluteString ?? UserDefaults.standard.string(forKey: "serverAddress") ?? ""
            model.discovery.start()
        }
        .onChange(of: useToken) { _, _ in
            error = nil
            if focusedField != nil && focusedField != .address { focusedField = useToken ? .token : .username }
        }
        .onDisappear { model.discovery.stop() }
        .disabled(model.connection == .connecting && !submitting)
    }

    @ViewBuilder private var nearbyServers: some View {
        if !model.discovery.servers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nearby Servers").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                ForEach(model.discovery.servers) { server in
                    Button {
                        address = server.address
                        focusedField = useToken ? .token : .username
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name).foregroundStyle(.primary)
                                Text(server.address).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: address == server.address ? "checkmark.circle.fill" : "chevron.right")
                        }.padding(16).background(fieldBackground, in: .rect(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var pageBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    private var fieldBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }
    @ViewBuilder private func focusOutline(active: Bool) -> some View {
        #if os(macOS)
        RoundedRectangle(cornerRadius: 14).strokeBorder(active ? Color.accentColor.opacity(0.7) : .primary.opacity(0.08), lineWidth: active ? 2 : 1)
            .allowsHitTesting(false)
        #endif
    }
    private func connect() {
        guard canConnect else { return }
        focusedField = nil
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

private struct SetupFieldRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).accessibilityHidden(true)
            content
                .font(.body)
                .textFieldStyle(.plain)
                .frame(minHeight: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
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
