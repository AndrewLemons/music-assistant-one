import Foundation

/// Queue entry IDs identify occurrences: two copies of a song are distinct entries.
public enum QueueOrder {
    public static func upcoming(_ entries: [QueueEntry], currentID: String?, currentIndex: Int?) -> [QueueEntry] {
        if let currentID, let index = entries.firstIndex(where: { $0.id == currentID }) {
            return Array(entries.dropFirst(index + 1))
        }
        if let currentIndex, currentIndex >= 0 {
            return Array(entries.dropFirst(currentIndex + 1))
        }
        return entries
    }

    /// SwiftUI's destination is an insertion boundary in the original list.
    /// MA's move_item takes a relative shift; zero has a special Play Next meaning.
    public static func shift(source: Int, destination: Int, count: Int) -> Int? {
        guard (0 ..< count).contains(source), (0 ... count).contains(destination) else { return nil }
        let target = destination > source ? destination - 1 : destination
        return target == source ? nil : target - source
    }
}
