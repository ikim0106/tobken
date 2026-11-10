import Testing
@testable import AgentSpeedCore

struct ObservedTPSTests {
    private func response(_ id: String = "one", model: String = "model", output: Int = 106,
                          input: Int = 1_000_000, final: Bool = true, source: SourceKind = .codex) -> ResponseRecord {
        ResponseRecord(key: id, source: source, agentId: id, model: model,
                       startMs: 1_000, endMs: 6_000,
                       usage: TokenUsage(input: input, output: output), isFinal: final)
    }

    @Test func fiveSecondWindowIncludesQuietSecondsAndExpiresEvenIfAgentStaysActive() {
        var engine = SpeedEngine(observesOutput: true)
        // A historical request establishes 21.2 request TPS, but cannot establish current output.
        engine.upsert(response("reference"), project: "", isCompletion: true, emitsEvents: false)
        engine.setAgent(EngineAgent(id: "active", source: .codex, project: "", model: "model",
                                    phase: .generating, inFlightStartMs: 8_000, lastLineMs: 8_000))
        #expect(engine.advance(nowMs: 10_000, todayStartMs: 0, emitsEvents: false).live.output == 0)
        engine.upsert(response(), project: "", isCompletion: true, emitsEvents: true, nowMs: 10_000)
        for now in [10_000, 11_000, 12_000, 14_999] {
            let reading = engine.advance(nowMs: Int64(now), todayStartMs: 0, emitsEvents: false)
            #expect(reading.live.output == 21.2, "106 tokens / 5 seconds, including quiet seconds")
            #expect(reading.liveEstimatedShare == 0)
            #expect(reading.activities.first?.estimatedTPS == 0)
        }
        let idle = engine.advance(nowMs: 15_000, todayStartMs: 0, emitsEvents: false)
        #expect(idle.live.output == 0)
        #expect(idle.activities.allSatisfy { $0.liveTPS == 0 })
        #expect(idle.activities.first?.averageTPS == 21.2, "request averages exclude idle time between requests")
    }

    @Test func streamingDeltasReplayAndFinalizationCountOutputOnlyOnce() {
        var engine = SpeedEngine(observesOutput: true)
        engine.upsert(response(output: 20, final: false), project: "", isCompletion: true, emitsEvents: true, nowMs: 10_000)
        engine.upsert(response(output: 50, final: false), project: "", isCompletion: false, emitsEvents: true, nowMs: 12_000)
        engine.upsert(response(output: 50), project: "", isCompletion: false, emitsEvents: true, nowMs: 13_000)
        #expect(engine.advance(nowMs: 13_000, todayStartMs: 0, emitsEvents: false).live.output == 10)
        #expect(engine.advance(nowMs: 15_000, todayStartMs: 0, emitsEvents: false).live.output == 6)
        #expect(engine.advance(nowMs: 17_000, todayStartMs: 0, emitsEvents: false).live.output == 0)
    }

    @Test func correctionsAndModelIdentificationDoNotProduceNewOutput() {
        var engine = SpeedEngine(observesOutput: true)
        engine.upsert(response(model: "unknown", output: 100), project: "", isCompletion: true, emitsEvents: true, nowMs: 10_000)
        engine.upsert(response(model: "identified", output: 80), project: "", isCompletion: false, emitsEvents: true, nowMs: 11_000)
        let corrected = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        #expect(corrected.live.output == 16)
        #expect(corrected.activities.count == 1)
        #expect(corrected.activities.first?.key.model == "identified")
        #expect(corrected.activities.first?.liveTPS == 16)
        engine.upsert(response("other", model: "second", output: 50, source: .claudeCode), project: "", isCompletion: true,
                      emitsEvents: true, nowMs: 12_000)
        let concurrent = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        #expect(concurrent.live.output == 26)
        #expect(concurrent.activities.reduce(0) { $0 + $1.liveTPS } == concurrent.live.output)
        #expect(concurrent.sourceLive[.codex]?.output == 16)
        #expect(concurrent.sourceLive[.claudeCode]?.output == 10)
    }

    @Test func startupUsageEstablishesBaselineAndInputOnlyUpdatesStayZero() {
        var engine = SpeedEngine(observesOutput: true)
        engine.upsert(response(output: 100), project: "", isCompletion: true, emitsEvents: false)
        engine.upsert(response(output: 100, input: 9_000_000), project: "", isCompletion: false,
                      emitsEvents: true, nowMs: 10_000)
        #expect(engine.advance(nowMs: 10_000, todayStartMs: 0, emitsEvents: false).live.output == 0)
        engine.upsert(response(output: 150), project: "", isCompletion: false, emitsEvents: true, nowMs: 11_000)
        #expect(engine.advance(nowMs: 11_000, todayStartMs: 0, emitsEvents: false).live.output == 10)
    }
}
