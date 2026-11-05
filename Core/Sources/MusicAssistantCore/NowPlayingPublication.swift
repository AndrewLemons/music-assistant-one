import Foundation

/// Decides when the system Now Playing information must be written again.
///
/// The system extrapolates elapsed time from the last published position and rate, so
/// rewriting it while playback advances normally adds nothing. Each write is relayed to
/// CarPlay and other accessories, and some head units briefly reroute audio when they
/// receive one. Publish only when what a listener sees would otherwise be wrong.
public struct NowPlayingPublication: Sendable {
    public struct Content: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var duration: Double
        public var elapsed: Double
        public var rate: Double
        /// Identifies the attached artwork, so loading it publishes once.
        public var artwork: String?

        public init(title: String, artist: String, duration: Double, elapsed: Double, rate: Double, artwork: String?) {
            self.title = title
            self.artist = artist
            self.duration = duration
            self.elapsed = elapsed
            self.rate = rate
            self.artwork = artwork
        }
    }

    /// Positions within this many seconds of the extrapolated position are not republished.
    public static let tolerance = 1.0

    private var last: (content: Content, at: Date)?

    public init() {}

    /// Returns true, and records `content` as published, when it must be written now.
    public mutating func needsPublishing(_ content: Content, at date: Date = .now) -> Bool {
        if let last, Self.matches(last.content, content, after: date.timeIntervalSince(last.at)) {
            return false
        }
        last = (content, date)
        return true
    }

    /// Forget the last publication, for example after the information was cleared.
    public mutating func reset() {
        last = nil
    }

    private static func matches(_ old: Content, _ new: Content, after interval: TimeInterval) -> Bool {
        guard old.title == new.title, old.artist == new.artist, old.duration == new.duration,
              old.rate == new.rate, old.artwork == new.artwork else { return false }
        var expected = old.elapsed + max(0, interval) * old.rate
        if old.duration > 0 {
            expected = min(expected, old.duration)
        }
        return abs(new.elapsed - expected) <= tolerance
    }
}
