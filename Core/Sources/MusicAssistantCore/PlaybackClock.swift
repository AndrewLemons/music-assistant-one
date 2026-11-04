import Foundation

/// Display smoothing shared by progress controls. Seek events bypass backward-drift smoothing.
public final class PlaybackClock {
    private var shown: (queue: String, item: String?, value: Double, positionChange: Date?)?

    public init() {}

    public func value(_ queue: PlayerQueue, at date: Date) -> Double {
        var value = queue.elapsed(at: date)
        if queue.isPlaying, let shown, shown.queue == queue.id, shown.item == queue.itemID,
           shown.positionChange == queue.positionChange,
           value < shown.value, shown.value - value < 2
        {
            value = shown.value
        }
        shown = (queue.id, queue.itemID, value, queue.positionChange)
        return value
    }
}
