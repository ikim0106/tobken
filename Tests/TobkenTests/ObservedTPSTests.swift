import Testing
@testable import AgentSpeedCore

/// Current TPS places logged output across the time it was generated and averages the last 30 seconds.
struct ObservedTPSTests {
    private let window = 30.0

    private func near(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    private func response(_ id: String = "one", model: String = "model", output: Int = 500,
                          input: Int = 1_000_000, start: Int64? = 1_000, end: Int64 = 6_000, first: Int64? = nil,
                          final: Bool = true, source: SourceKind = .codex) -> ResponseRecord {
        ResponseRecord(key: id, source: source, agentId: id, model: model, startMs: start, endMs: end,
                       usage: TokenUsage(input: input, output: output), isFinal: final, firstMs: first)
    }

    private func observing(at nowMs: Int64 = 0) -> SpeedEngine {
        var engine = SpeedEngine(observesOutput: true)
        _ = engine.advance(nowMs: nowMs, todayStartMs: 0, emitsEvents: false) // the startup seed
        return engine
    }

    private func live(_ engine: inout SpeedEngine, at nowMs: Int64) -> Double {
        engine.advance(nowMs: nowMs, todayStartMs: 0, emitsEvents: false).live.output
    }

    @Test func completedResponseIsPlacedAcrossItsGenerationTime() throws {
        var engine = observing()
        // 500 tokens generated over 5 s, logged at completion: 50 TPS while it ran, not a burst when logged.
        engine.upsert(response(), project: "", isCompletion: true, emitsEvents: true, nowMs: 6_000)
        #expect(near(live(&engine, at: 6_000), 500 / window), "all 500 tokens inside the 30 s window")
        #expect(near(live(&engine, at: 31_000), 500 / window))
        #expect(near(live(&engine, at: 33_000), 300 / window), "3 of the 5 generating seconds remain in the window")
        #expect(live(&engine, at: 36_000) == 0)

        let output = engine.advance(nowMs: 6_000, todayStartMs: 0, emitsEvents: false)
        let series = try #require(output.observedSeries)
        #expect(series.total.count == 60)
        #expect(series.total.last == output.live.output, "the graph's latest reading is the displayed number")
        // At 3 s, the window (−27 s, 3 s] holds the first 2 s of generation: 200 tokens / 30 s.
        let index = try #require(series.total.indices.first { series.timeMs(at: $0) == 3_000 })
        #expect(near(series.total[index], 200 / window), "past readings fill in when a response completes")
        #expect(series.total[0] == nil, "readings before monitoring began are unknown, not zero")
        #expect(near(series.bySource[.codex]?.last ?? nil, 500 / window))
    }

    @Test func activeRequestsAndHistoricalSpeedsNeverPredictOutput() {
        var engine = observing()
        engine.upsert(response("reference"), project: "", isCompletion: true, emitsEvents: false)
        engine.setAgent(EngineAgent(id: "active", source: .codex, project: "", model: "model",
                                    phase: .generating, inFlightStartMs: 8_000, lastLineMs: 8_000))
        let reading = engine.advance(nowMs: 10_000, todayStartMs: 0, emitsEvents: false)
        #expect(reading.live.output == 0)
        #expect(reading.liveEstimatedShare == 0)
        #expect(reading.activities.first?.averageTPS == 100, "request averages are unaffected")
    }

    @Test func responseLoggedLongAfterItEndedAddsHistoryButNoCurrentBurst() throws {
        var engine = observing()
        engine.upsert(response(start: 20_000, end: 25_000), project: "", isCompletion: true, emitsEvents: true, nowMs: 70_000)
        let output = engine.advance(nowMs: 70_000, todayStartMs: 0, emitsEvents: false)
        #expect(output.live.output == 0)
        let series = try #require(output.observedSeries)
        let index = try #require(series.total.indices.first { series.timeMs(at: $0) == 25_000 })
        #expect(near(series.total[index], 500 / window))
    }

    @Test func streamingUpdatesArePlacedSinceThePreviousUpdateAndCountOnce() {
        var engine = observing()
        engine.upsert(response(output: 20, start: 8_000, end: 10_000, first: 9_000, final: false), project: "",
                      isCompletion: true, emitsEvents: true, nowMs: 10_000)
        engine.upsert(response(output: 50, start: 8_000, end: 12_000, first: 9_000, final: false), project: "",
                      isCompletion: false, emitsEvents: true, nowMs: 12_000)
        engine.upsert(response(output: 50, start: 8_000, end: 13_000, first: 9_000), project: "",
                      isCompletion: false, emitsEvents: true, nowMs: 13_000)
        #expect(near(live(&engine, at: 13_000), 50 / window), "50 tokens once, despite the replayed final usage")
        // (11 s, 41 s] keeps the second half of the 30 tokens placed over (10 s, 12 s].
        #expect(near(live(&engine, at: 41_000), 15 / window))
        #expect(live(&engine, at: 42_000) == 0)
    }

    @Test func correctionsAndModelIdentificationDoNotProduceNewOutput() {
        var engine = observing()
        engine.upsert(response(model: "unknown", output: 100), project: "", isCompletion: true, emitsEvents: true, nowMs: 6_000)
        engine.upsert(response(model: "identified", output: 80), project: "", isCompletion: false, emitsEvents: true, nowMs: 6_500)
        let corrected = engine.advance(nowMs: 7_000, todayStartMs: 0, emitsEvents: false)
        #expect(near(corrected.live.output, 80 / window))
        #expect(corrected.activities.count == 1)
        #expect(corrected.activities.first?.key.model == "identified")
        #expect(near(corrected.activities.first?.liveTPS, 80 / window))
        engine.upsert(response("other", model: "second", output: 50, source: .claudeCode), project: "",
                      isCompletion: true, emitsEvents: true, nowMs: 7_000)
        let concurrent = engine.advance(nowMs: 7_000, todayStartMs: 0, emitsEvents: false)
        #expect(near(concurrent.live.output, 130 / window))
        #expect(near(concurrent.activities.reduce(0) { $0 + $1.liveTPS }, concurrent.live.output))
        #expect(near(concurrent.sourceLive[.codex]?.output, 80 / window))
        #expect(near(concurrent.sourceLive[.claudeCode]?.output, 50 / window))
    }

    @Test func startupUsageEstablishesBaselineAndInputOnlyUpdatesStayZero() {
        var engine = observing()
        engine.upsert(response(output: 100), project: "", isCompletion: true, emitsEvents: false)
        engine.upsert(response(output: 100, input: 9_000_000, end: 8_000), project: "", isCompletion: false,
                      emitsEvents: true, nowMs: 8_000)
        #expect(live(&engine, at: 8_000) == 0)
        engine.upsert(response(output: 150, end: 11_000), project: "", isCompletion: false, emitsEvents: true, nowMs: 11_000)
        #expect(near(live(&engine, at: 11_000), 50 / window), "50 new tokens since the previous update")
    }

    @Test func futureTimestampsAreClampedToNow() {
        var engine = observing()
        engine.upsert(response(start: 9_000, end: 60_000), project: "", isCompletion: true, emitsEvents: true, nowMs: 10_000)
        #expect(near(live(&engine, at: 10_000), 500 / window), "placed over (9 s, 10 s], all inside the window")
    }
}
