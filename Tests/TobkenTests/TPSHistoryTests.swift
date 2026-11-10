import Foundation
import Testing
@testable import AgentSpeedCore
import TobkenCore

struct TPSHistoryTests {
    @Test func secondRolloverDoesNotCreateAPhantomDrop() throws {
        var engine = SpeedEngine()
        engine.upsert(ResponseRecord(key: "reference", source: .codex, agentId: "reference", model: "model",
                                     startMs: 1_000, endMs: 3_000, usage: TokenUsage(output: 200)),
                      project: "", isCompletion: true, emitsEvents: false)
        engine.setAgent(EngineAgent(id: "active", source: .codex, project: "", model: "model", phase: .generating,
                                    inFlightStartMs: 8_000, lastLineMs: 8_000))
        let before = engine.advance(nowMs: 11_999, todayStartMs: 0, emitsEvents: false)
        let after = engine.advance(nowMs: 12_000, todayStartMs: 0, emitsEvents: false)
        // The old chart used the partial bucket: 99.9 tokens becomes 0 at a second boundary.
        #expect(try #require(before.history.last).estimated.output > 99)
        #expect(try #require(after.history.last).estimated.output == 0)
        #expect(before.live.output == 100)
        #expect(after.live.output == 100)

        var history = TPSHistory()
        history.record(at: Date(timeIntervalSince1970: 11.999), value: before.live.output)
        history.record(at: Date(timeIntervalSince1970: 12), value: after.live.output)
        #expect(history.samples.map(\.value) == [100, 100])
    }

    @Test func onlyTheCurrentSecondChangesAndPastReadingsStayFixed() {
        var history = TPSHistory()
        history.record(at: Date(timeIntervalSince1970: 10), value: 40)
        history.record(at: Date(timeIntervalSince1970: 10.5), value: 60)
        history.record(at: Date(timeIntervalSince1970: 11), value: 70)
        history.record(at: Date(timeIntervalSince1970: 11.5), value: 80)
        #expect(history.samples.map(\.value) == [60, 80])
        #expect(history.samples.last?.time == Date(timeIntervalSince1970: 11.5))
        history.record(at: Date(timeIntervalSince1970: 10), value: 500)
        #expect(history.samples.map(\.value) == [60, 80])
    }

    @Test func unknownReadingsRemainGapsAndWindowDoesNotStretch() {
        var history = TPSHistory()
        history.record(at: Date(timeIntervalSince1970: 0), value: 100)
        history.record(at: Date(timeIntervalSince1970: 1), value: nil)
        history.record(at: Date(timeIntervalSince1970: 60), value: 80)
        #expect(history.samples.map(\.value) == [100, nil, 80])
        history.record(at: Date(timeIntervalSince1970: 61), value: 75)
        #expect(history.samples.map(\.value) == [nil, 80, 75])
    }

    @Test func scaleStaysFixedWhenAPeakLeavesTheWindow() {
        var history = TPSHistory()
        history.record(at: Date(timeIntervalSince1970: 0), value: 320)
        #expect(history.ceiling == 500)
        history.record(at: Date(timeIntervalSince1970: 61), value: 80)
        #expect(history.ceiling == 500)
        for second in 62...122 { history.record(at: Date(timeIntervalSince1970: Double(second)), value: 0) }
        #expect(history.ceiling == 100)
    }
}
