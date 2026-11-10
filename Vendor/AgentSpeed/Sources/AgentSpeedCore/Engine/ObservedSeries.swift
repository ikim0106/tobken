import Foundation

/// Tobken: the observed current-TPS reading at each second of the last minute, computed from the same placed output
/// as `SpeedSnapshot.live`. Readings before monitoring began are nil (unknown), never zero. Past readings change
/// when a response completes, because its output is placed back across the time it was generated.
public struct ObservedSeries: Equatable, Sendable {
    /// Time of the last reading; it equals the snapshot's live rate.
    public var endMs: Int64
    public var stepMs: Int64
    /// Oldest first; `total.last` is at `endMs`.
    public var total: [Double?]
    /// The same readings per source, for sources with placed output in range.
    public var bySource: [SourceKind: [Double?]]

    public init(endMs: Int64, stepMs: Int64, total: [Double?], bySource: [SourceKind: [Double?]] = [:]) {
        self.endMs = endMs
        self.stepMs = stepMs
        self.total = total
        self.bySource = bySource
    }

    /// Time of the reading at `index`.
    public func timeMs(at index: Int) -> Int64 {
        endMs - Int64(total.count - 1 - index) * stepMs
    }
}
