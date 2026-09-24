import AVFoundation
import Foundation
import MusicAssistantCore
import Observation
import SendspinKit
#if os(iOS)
    import UIKit
#endif

@MainActor @Observable
final class LocalPlayer {
    var clientID: String?
    var isConnected = false
    var isStarting = false
    var status = "Play music on this device"
    var error: String?
    private var device: SendspinStateStore?
    private var client: SendspinClient?
    private var eventTask: Task<Void, Never>?
    private var transport: AuthenticatedSendspinTransport?
    private var epoch = UUID()

    func start(server: ServerAddress, token: String, api: MusicAssistantClient) async throws {
        guard !isStarting else { return }
        await stop()
        try Task.checkCancellation()
        isStarting = true
        error = nil
        status = "Connecting audio…"
        let attempt = UUID()
        epoch = attempt
        defer {
            if epoch == attempt {
                isStarting = false
            }
        }
        do {
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                // Playback already supports AirPlay. Explicit allowAirPlay is only valid
                // with playAndRecord and causes OSStatus -50 on iOS.
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            #endif
            if device == nil {
                device = try SendspinStateStore { [weak self] message in
                    Task { @MainActor in self?.error = message }
                }
            }
            guard let device else { return }
            clientID = device.identity.clientId
            let formats = try [44100, 48000].flatMap { rate in
                try [
                    AudioFormatSpec(codec: .flac, channels: 2, sampleRate: rate, bitDepth: 16),
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: rate, bitDepth: 16),
                ]
            }
            #if os(macOS)
                let name = Host.current().localizedName ?? "Mac"
            #else
                let name = UIDevice.current.name
            #endif
            let player = try SendspinClient(
                identity: device.identity, name: "\(name) · Music Assistant One", roles: [.playerV1, .metadataV1],
                deviceInfo: DeviceInfo(
                    productName: "Mobile Application",
                    manufacturer: "Music Assistant One",
                    softwareVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                ),
                playerConfig: PlayerConfiguration(bufferCapacity: 2_097_152, supportedFormats: formats),
                unpairedAccessEnabled: false,
                persistenceProvider: device,
                pairing: PairingConfiguration(pairingPsk: device.pairingPSK, store: device)
            )
            client = player
            let events = player.events()
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self, epoch == attempt else { return }
                    switch event {
                    case let .serverConnected(info):
                        isConnected = info.hasRole(.playerV1)
                        status = isConnected ? "Ready to play" : "Pairing this device…"
                    case .streamStarted: status = "Playing on this device"
                    case .streamEnded: status = "Ready to play"
                    case let .streamingFailed(failure):
                        isConnected = false
                        error = failure.localizedDescription
                        status = "Audio needs attention"
                    case .disconnected:
                        isConnected = false
                        status = "Audio disconnected"
                    default: break
                    }
                }
            }
            let transport = AuthenticatedSendspinTransport(url: server.endpoint("sendspin", websocket: true))
            self.transport = transport
            try await transport.authenticate(token: token, clientID: device.identity.clientId)
            try Task.checkCancellation()
            guard epoch == attempt else { throw CancellationError() }
            try await player.acceptConnection(transport)
            guard epoch == attempt else { throw CancellationError() }
            // MA binds the pairing to this signed-in account and persists it server-side.
            _ = try await api.command("sendspin/pair_web_player", args: ["pairing_token": .string(device.pairingToken)])
            guard epoch == attempt else { throw CancellationError() }
            try await device.checkHealth()
            isConnected = player.connectionState == .connected
            status = isConnected ? "Ready to play" : "Waiting for audio connection"
        } catch {
            if epoch == attempt {
                await stop()
                let message = Self.describe(error)
                self.error = message
                status = "Couldn’t connect audio"
            }
            throw MAError.message(Self.describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        let type = String(reflecting: type(of: error))
        if type.contains("Handshake") {
            return "The server and this app couldn’t establish a Sendspin session (\(String(describing: error))). This build targets Music Assistant 2.10.1."
        }
        return error.localizedDescription
    }

    func stop() async {
        epoch = UUID()
        eventTask?.cancel(); eventTask = nil
        let oldClient = client; client = nil
        let oldTransport = transport; transport = nil
        isConnected = false; isStarting = false
        await oldClient?.close()
        await oldTransport?.disconnect()
        status = "Play music on this device"
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func eraseStoredIdentity() async throws {
        await stop()
        device = nil
        clientID = nil
        try SendspinStateStore.deleteStoredState()
    }
}
