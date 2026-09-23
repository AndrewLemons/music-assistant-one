import ExtensionFoundation
import Foundation
import MusicAssistantCore
import NowPlaying

@main
struct RemoteMediaExtension: RemoteMediaSessionExtension {
    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributes: RemotePlaybackAttributes) async throws -> RemotePlaybackSession {
        RemotePlaybackSession(attributes: attributes)
    }
}
