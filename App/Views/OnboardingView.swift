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
        Form {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(.init())
            Section {
                TextField("Server Address", text: $address, prompt: Text("music.example.com"))
                    .textContentType(.URL)
                    .focused($focusedField, equals: .address)
                    .accessibilityIdentifier("serverAddress")
                    .submitLabel(.next)
                    .onSubmit { focusedField = useToken ? .token : .username }
                #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                ForEach(model.discovery.servers) { server in
                    Button {
                        address = server.address
                        focusedField = useToken ? .token : .username
                    } label: {
                        LabeledContent {
                            if address == server.address {
                                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                            }
                        } label: {
                            Label {
                                Text(server.name)
                                Text(server.address)
                            } icon: {
                                Image(systemName: "server.rack").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(address == server.address ? .isSelected : [])
                }
            } header: {
                Text("Server")
            } footer: {
                if let message = model.discovery.message {
                    Text(message)
                }
            }

            Section {
                Picker("Sign In With", selection: $useToken) {
                    Text("Account").tag(false)
                    Text("Access Token").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if useToken {
                    SecureField("Access Token", text: $token, prompt: Text("Paste token"))
                        .focused($focusedField, equals: .token)
                        .accessibilityIdentifier("accessToken")
                        .submitLabel(.go)
                        .onSubmit(connect)
                } else {
                    TextField("Username", text: $username, prompt: Text("Username"))
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                        .accessibilityIdentifier("username")
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                    #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                    SecureField("Password", text: $password, prompt: Text("Password"))
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .accessibilityIdentifier("password")
                        .submitLabel(.go)
                        .onSubmit(connect)
                }
            } header: {
                Text("Sign In")
            } footer: {
                Text(useToken
                    ? "Create a long-lived token in Music Assistant under Settings → Profile."
                    : "Your password isn’t stored. The app keeps an access token in Keychain.")
            }

            Section {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
                Button(action: connect) {
                    HStack(spacing: 8) {
                        if submitting {
                            ProgressView().controlSize(.small)
                        }
                        Text(submitting ? "Connecting…" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canConnect)
                .accessibilityIdentifier("connectButton")
                .keyboardShortcut(.defaultAction)
                .listRowBackground(Color.clear)
                .listRowInsets(.init())
            } footer: {
                Link("Privacy Policy", destination: AppLinks.privacy)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .disabled(submitting)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .scrollDismissesKeyboard(.interactively)
        .task {
            address = model.server?.baseURL.absoluteString ?? UserDefaults.standard.string(forKey: "serverAddress") ?? ""
            model.discovery.start()
        }
        .onChange(of: useToken) { _, _ in
            error = nil
            if focusedField != nil, focusedField != .address {
                focusedField = useToken ? .token : .username
            }
        }
        .onDisappear { model.discovery.stop() }
        .disabled(model.connection == .connecting && !submitting)
    }

    private var header: some View {
        VStack(spacing: 12) {
            AppGlyph(size: 72)
            Text("Music Assistant One")
                .font(.title.bold())
            Text("Connect to your Music Assistant server.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func connect() {
        guard canConnect else { return }
        focusedField = nil
        submitting = true; error = nil
        Task {
            do {
                try await model.signIn(
                    address: address,
                    username: username,
                    password: password,
                    accessToken: useToken ? token : ""
                )
                password = ""; token = ""
            } catch { self.error = error.localizedDescription }
            submitting = false
        }
    }
}
