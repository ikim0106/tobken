import Foundation

/// Readings of the displayed live rate, kept as observed rather than reconstructed later.
public struct TPSHistory: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let time: Date
        public let value: Double?
    }

    public static let duration: TimeInterval = 60
    public private(set) var samples: [Sample] = []
    public private(set) var ceiling: Double = 100

    public init() {}

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
            if time.timeIntervalSince(last.time) >= Self.duration { ceiling = 100 }
        }
        let value = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let sample = Sample(time: time, value: value)
        if let last = samples.last,
           floor(last.time.timeIntervalSince1970) == floor(time.timeIntervalSince1970) {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        samples.removeAll { $0.time < time.addingTimeInterval(-Self.duration) }
        if let value, value > ceiling {
            let magnitude = pow(10, floor(log10(value)))
            ceiling = ([1.0, 2, 5, 10].first { $0 * magnitude >= value } ?? 10) * magnitude
        }
        // Keep a stable scale through activity; allow a fresh scale after a full idle minute.
        if samples.count >= 60, samples.allSatisfy({ $0.value == 0 }) { ceiling = 100 }
    }
}
