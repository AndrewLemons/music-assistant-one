import Foundation
@testable import MusicAssistantCore
import Testing

private func content(
    title: String = "Song", elapsed: Double, rate: Double = 1, duration: Double = 200, artwork: String? = nil
) -> NowPlayingPublication.Content {
    .init(title: title, artist: "Artist", duration: duration, elapsed: elapsed, rate: rate, artwork: artwork)
}

/// Offers each sample at its time offset and returns which ones were published.
private func published(
    _ samples: [(at: Double, content: NowPlayingPublication.Content)],
    resettingBefore reset: Int? = nil
) -> [Bool] {
    var publication = NowPlayingPublication()
    let start = Date(timeIntervalSince1970: 1000)
    return samples.enumerated().map { index, sample in
        if index == reset {
            publication.reset()
        }
        return publication.needsPublishing(sample.content, at: start + sample.at)
    }
}

@Test func steadyPlaybackPublishesOnce() {
    // The periodic observer fires twice a second while the position advances normally.
    let ticks = (0 ... 240).map { tick in
        (at: Double(tick) * 0.5, content: content(elapsed: 10 + Double(tick) * 0.5))
    }
    #expect(published(ticks) == [true] + Array(repeating: false, count: 240))
}

@Test func smallClockDriftIsNotRepublished() {
    #expect(published([
        (0, content(elapsed: 10)),
        (30, content(elapsed: 39.4)),
        (30, content(elapsed: 40.9)),
    ]) == [true, false, false])
}

@Test func positionJumpsArePublished() {
    #expect(published([
        (0, content(elapsed: 10)),
        // A seek forward, then a stall that left the clock behind the extrapolated position.
        (1, content(elapsed: 90)),
        (6, content(elapsed: 92)),
        (7, content(elapsed: 93)),
    ]) == [true, true, true, false])
}

@Test func rateMetadataAndArtworkChangesArePublished() {
    #expect(published([
        (0, content(elapsed: 10)),
        (0.5, content(elapsed: 10.5, rate: 0)),
        // Paused: the position holds, so later identical samples are not republished.
        (20, content(elapsed: 10.5, rate: 0)),
        (21, content(elapsed: 10.5)),
        (21.5, content(elapsed: 11, artwork: "art")),
        (22, content(elapsed: 11.5, artwork: "art")),
        (23, content(title: "Next", elapsed: 0, artwork: "art")),
    ]) == [true, true, false, true, true, false, true])
}

@Test func extrapolationStopsAtTheEndOfTheSong() {
    // A song held at its end while the next one loads is not a position jump.
    #expect(published([
        (0, content(elapsed: 198, duration: 200)),
        (10, content(elapsed: 200, duration: 200)),
    ]) == [true, false])
}

@Test func resetPublishesAgain() {
    #expect(published([
        (0, content(elapsed: 10)),
        (0.5, content(elapsed: 10.5)),
    ], resettingBefore: 1) == [true, true])
}
