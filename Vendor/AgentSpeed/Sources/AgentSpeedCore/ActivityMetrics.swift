import Foundation

public struct ActivityKey: Hashable, Sendable, Identifiable {
    public var source: SourceKind
    public var model: String?
    public var provider: String?
    public var id: Self { self }

    public init(source: SourceKind, model: String?, provider: String? = nil) {
        self.source = source
        self.model = model
        self.provider = provider
    }
}

/// Daily request statistics and a projection of the engine's three-second live window.
public struct ActivityMetrics: Equatable, Sendable, Identifiable {
    public var key: ActivityKey
    public var id: ActivityKey { key }
    public var totals = TokenTotals()
    public var timedOutput: Int64 = 0
    public var durationMs: Int64 = 0
    public var timedRequests = 0
    public var latencyBins = [Int](repeating: 0, count: PerfLatency.bucketCount)
    public var durationBins = [Int](repeating: 0, count: PerfLatency.bucketCount)
    public var liveTPS = 0.0
    public var estimatedTPS = 0.0

    public init(key: ActivityKey) { self.key = key }

    public var averageTPS: Double? {
        durationMs > 0 ? Double(timedOutput) * 1000 / Double(durationMs) : nil
    }

    public var latencySamples: Int { latencyBins.reduce(0, +) }
    public var ttftP50: Double? { Self.percentile(latencyBins, fraction: 0.5) }
    public var ttftP95: Double? {
        latencySamples >= 20 ? Self.percentile(latencyBins, fraction: 0.95) : nil
    }
    public var durationP50: Double? { Self.percentile(durationBins, fraction: 0.5) }

    public mutating func merge(_ other: Self) {
        totals.requests += other.totals.requests
        totals.input += other.totals.input
        totals.cachedInput += other.totals.cachedInput
        totals.cacheWriteInput += other.totals.cacheWriteInput
        totals.output += other.totals.output
        totals.reasoning += other.totals.reasoning
        timedOutput += other.timedOutput
        durationMs += other.durationMs
        timedRequests += other.timedRequests
        for index in latencyBins.indices {
            latencyBins[index] += other.latencyBins[index]
            durationBins[index] += other.durationBins[index]
        }
        liveTPS += other.liveTPS
        estimatedTPS += other.estimatedTPS
    }

    mutating func apply(_ record: ResponseRecord, sign: Int) {
        totals.add(record.usage, sign: sign, requestCount: record.requestCount)
        guard record.isFinal, let timed = TimedResponse(record) else { return }
        timedOutput += Int64(sign) * Int64(record.usage.output)
        durationMs += Int64(sign) * timed.durationMs
        timedRequests += sign * record.requestCount
        durationBins[PerfLatency.bucket(timed.durationMs)] += sign
        if let start = record.startMs, let first = record.firstMs,
           first >= start, first <= record.endMs {
            latencyBins[PerfLatency.bucket(first - start)] += sign
        }
    }

    private static func percentile(_ bins: [Int], fraction: Double) -> Double? {
        let count = bins.reduce(0, +)
        guard count > 0 else { return nil }
        let rank = max(1, Int(ceil(Double(count) * fraction)))
        var cumulative = 0
        for (index, value) in bins.enumerated() {
            cumulative += value
            if cumulative >= rank { return PerfLatency.centre(index) }
        }
        return nil
    }
}

extension ResponseRecord {
    var activityKey: ActivityKey { ActivityKey(source: source, model: model, provider: provider) }
}
