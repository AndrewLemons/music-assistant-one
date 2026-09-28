import MusicAssistantCore
import Testing

@Test func queueMoveInsertionBoundaries() {
    #expect(QueueOrder.shift(source: 0, destination: 3, count: 3) == 2)
    #expect(QueueOrder.shift(source: 2, destination: 0, count: 3) == -2)
    #expect(QueueOrder.shift(source: 1, destination: 1, count: 3) == nil)
    #expect(QueueOrder.shift(source: 1, destination: 2, count: 3) == nil)
    #expect(QueueOrder.shift(source: -1, destination: 0, count: 3) == nil)
    #expect(QueueOrder.shift(source: 0, destination: 4, count: 3) == nil)
}

@Test func queueUsesOccurrenceIdentityAndExcludesHistory() {
    let entries = ["past", "current", "repeat", "next"].map {
        QueueEntry(.object([
            "queue_item_id": .string($0),
            "media_item": .object(["uri": .string("library://track/1")]),
        ]))
    }
    #expect(QueueOrder.upcoming(entries, currentID: "current", currentIndex: nil).map(\.id) == ["repeat", "next"])
    #expect(QueueOrder.upcoming(entries, currentID: nil, currentIndex: 2).map(\.id) == ["next"])
    #expect(QueueOrder.upcoming(entries, currentID: "next", currentIndex: nil).isEmpty)
    #expect(QueueOrder.upcoming(entries, currentID: nil, currentIndex: nil).count == 4)
}
