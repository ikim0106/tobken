import Foundation
import Testing
@testable import AgentSpeedCore
import TobkenCore

struct AccountingTests {
    private func response(_ key: String = "one", source: SourceKind = .codex, model: String? = "model",
                          input: Int = 1_000, output: Int = 200, start: Int64? = 10_000,
                          end: Int64 = 12_000, first: Int64? = nil, final: Bool = true) -> ResponseRecord {
        ResponseRecord(key: key, source: source, agentId: key, model: model, startMs: start, endMs: end,
                       usage: TokenUsage(input: input, cachedInput: input / 2, output: output, reasoning: output / 4),
                       isFinal: final, firstMs: first)
    }

    @Test func replacementsMoveModelsWithoutDoubleCounting() {
        var engine = SpeedEngine()
        engine.upsert(response(model: "old", first: 10_500, final: false), project: "", isCompletion: true, emitsEvents: false)
        _ = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        let replacement = response(model: "new", output: 400, first: 10_500)
        engine.upsert(replacement, project: "", isCompletion: false, emitsEvents: false)
        engine.upsert(replacement, project: "", isCompletion: false, emitsEvents: false)
        let result = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        #expect(result.today.total == 1_400)
        #expect(result.today.requests == 1)
        #expect(result.activities.count == 1)
        #expect(result.activities.first?.key.model == "new")
        #expect(result.activities.first?.averageTPS == 200)
        #expect(result.activities.first?.latencySamples == 1)
    }

    @Test func totalsIncludeCacheAndReasoningOnlyOnce() {
        var engine = SpeedEngine()
        engine.upsert(response(), project: "", isCompletion: true, emitsEvents: false)
        let result = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        #expect(result.today.input == 1_000)
        #expect(result.today.cachedInput == 500)
        #expect(result.today.reasoning == 50)
        #expect(result.today.total == 1_200)
        #expect(result.activities.first?.totals == result.today)
        #expect(result.activities.first?.averageTPS == 100)
    }

    @Test func unavailableTimingDoesNotBecomeZero() {
        var engine = SpeedEngine()
        engine.upsert(response(start: nil), project: "", isCompletion: true, emitsEvents: false)
        let result = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        #expect(result.today.total == 1_200)
        #expect(result.activities.first?.averageTPS == nil)
        #expect(result.activities.first?.ttftP50 == nil)
        #expect(MetricFormat.rate(result.activities.first?.averageTPS) == "—")
    }

    @Test func liveOutputAddsAcrossModelsAndIgnoresInput() {
        var engine = SpeedEngine()
        engine.upsert(response(input: 9_000_000, output: 300, start: 9_000, end: 12_000), project: "", isCompletion: true, emitsEvents: false)
        engine.upsert(response("two", source: .claudeCode, model: "other", input: 4_000_000, output: 150, start: 9_000, end: 12_000), project: "", isCompletion: true, emitsEvents: false)
        let result = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        #expect(abs(result.live.output - 150) < 0.001)
        #expect(abs(result.activities.reduce(0, { $0 + $1.liveTPS }) - result.live.output) < 0.001)
    }

    @Test func inFlightEstimatesAreAttributedToTheirModel() {
        var engine = SpeedEngine()
        engine.upsert(response(start: 1_000, end: 3_000), project: "", isCompletion: true, emitsEvents: false)
        engine.setAgent(EngineAgent(id: "active", source: .codex, project: "", model: "model", phase: .generating,
                                   inFlightStartMs: 10_000, lastLineMs: 10_000))
        let result = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        #expect(result.live.output > 0)
        #expect(result.activities.first?.estimatedTPS == result.activities.first?.liveTPS)
        #expect(abs(result.activities.reduce(0, { $0 + $1.liveTPS }) - result.live.output) < 0.001)
    }

    @Test func midnightResetsDailyStatsAndAllowsLiveCarryover() {
        var engine = SpeedEngine()
        engine.upsert(response(), project: "", isCompletion: true, emitsEvents: false)
        _ = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        let result = engine.advance(nowMs: 86_401_000, todayStartMs: 86_400_000, emitsEvents: false)
        #expect(result.today.total == 0)
        #expect(result.activities.isEmpty)
    }

    @Test func modelGroupingUsesWeightedRatesAndKeepsUnknownModels() {
        var engine = SpeedEngine()
        engine.upsert(response(source: .codex, output: 200), project: "", isCompletion: true, emitsEvents: false)
        engine.upsert(response("two", source: .claudeCode, output: 800, start: 8_000), project: "", isCompletion: true, emitsEvents: false)
        engine.upsert(response("unknown", model: nil, start: nil), project: "", isCompletion: true, emitsEvents: false)
        let result = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        var snapshot = SpeedSnapshot.empty
        snapshot.state = .running
        snapshot.today = result.today
        snapshot.activities = result.activities
        let dashboard = Dashboard(snapshot: snapshot)
        #expect(dashboard.models.count == 2)
        let known = dashboard.models.first { $0.name == "model" }
        #expect(known?.sources.count == 2)
        #expect(abs((known?.metrics.averageTPS ?? 0) - 1_000.0 / 6) < 0.001)
        #expect(dashboard.models.contains { $0.name == "Unknown model" })
        #expect(dashboard.models.reduce(0, { $0 + $1.metrics.totals.total }) == result.today.total)
        #expect(Dashboard(snapshot: snapshot, selectedSource: .claudeCode).statusTitle == dashboard.statusTitle)
    }

    @Test func ttftPercentileRequiresEnoughSamplesForP95() {
        var ledger = DayLedger(dayStartMs: 0)
        for index in 0..<19 { ledger.replace(nil, with: response("\(index)", first: 10_500)) }
        #expect(ledger.activities.values.first?.latencySamples == 19)
        #expect(ledger.activities.values.first?.ttftP95 == nil)
        ledger.replace(nil, with: response("19", first: 10_500))
        #expect(ledger.activities.values.first?.ttftP95 != nil)
        #expect(abs((ledger.activities.values.first?.ttftP50 ?? 0) - 500) < 50)
    }

    @Test func activeRequestsWithoutRatesShowUnknownInsteadOfIdle() {
        var snapshot = SpeedSnapshot.empty
        snapshot.state = .running
        snapshot.generatingCount = 1
        #expect(Dashboard(snapshot: snapshot).currentTPS == nil)
        #expect(Dashboard(snapshot: snapshot).statusTitle.contains("— TPS"))
        snapshot.generatingCount = 0
        #expect(Dashboard(snapshot: snapshot).currentTPS == 0)
    }

    @Test @MainActor func actualMonitorSeedsAppendsAndRestarts() async throws {
        let report = try await Verification.run()
        #expect(report.hasPrefix("PASS:"))
    }
}
