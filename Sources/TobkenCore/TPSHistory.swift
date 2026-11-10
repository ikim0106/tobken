import Foundation

/// Current-TPS readings over the last minute, for the graph.
///
/// While the monitor runs, each snapshot's `ObservedSeries` replaces the readings: output is placed across the time it
/// was generated, so a completed response fills in the seconds it took. When the monitor goes quiet it stops
/// publishing; `record` then extends the readings with the known zeros, without a timer while the menu is closed.
public struct TPSHistory: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let time: Date
        public let value: Double?
    }

    public static let duration: TimeInterval = 60
    public private(set) var samples: [Sample] = []

    public init() {}

    /// The highest reading in range, or nil when nothing is known.
    public var peak: Double? { samples.compactMap(\.value).max() }

    /// The top of the graph: the peak sits at 80% of the height, and quiet trickles do not fill it.
    public var ceiling: Double { Self.ceiling(peak: peak ?? 0) }

    public static func ceiling(peak: Double) -> Double { max(peak * 1.25, 5) }

    /// Replaces the readings with a series from the collector (oldest first, one per `step`, ending at `end`).
    public mutating func replace(values: [Double?], endingAt end: Date, step: TimeInterval = 1) {
        samples = values.enumerated().map { index, value in
            Sample(time: end.addingTimeInterval(-Double(values.count - 1 - index) * step), value: Self.clean(value))
        }
        trim(to: end)
    }

    /// Adds one reading. Past seconds stay as they are; a reading in the same second replaces the last one.
    public mutating func record(at time: Date, value: Double?) {
        if let last = samples.last, time < last.time { return }
        // The monitor sleeps after publishing zero. Fill that known quiet interval when it wakes,
        // without keeping a timer alive just to draw zeros in a closed menu.
        if let last = samples.last, last.value == 0, time.timeIntervalSince(last.time) > 1 {
            let firstSecond = max(floor(last.time.timeIntervalSince1970) + 1,
                                  ceil(time.timeIntervalSince1970 - Self.duration))
            let endSecond = floor(time.timeIntervalSince1970)
            for second in stride(from: firstSecond, to: endSecond, by: 1) {
                samples.append(Sample(time: Date(timeIntervalSince1970: second), value: 0))
            }
        }
        let sample = Sample(time: time, value: Self.clean(value))
        if let last = samples.last,
           floor(last.time.timeIntervalSince1970) == floor(time.timeIntervalSince1970) {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        trim(to: time)
    }

    private mutating func trim(to end: Date) {
        samples.removeAll { $0.time < end.addingTimeInterval(-Self.duration) }
    }

    private static func clean(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
