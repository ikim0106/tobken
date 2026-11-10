import Testing
import AgentSpeedCore
import TobkenCore

struct MetricFormatTests {
    @Test(arguments: [
        (0, "0"), (999, "999"), (1_000, "1.0K"), (1_500, "1.5K"), (12_345, "12.3K"),
        (99_940, "99.9K"), (99_960, "100K"), (999_499, "999K"), (999_950, "1.0M"),
        (17_800_000, "17.8M"), (999_950_000, "1.0B"), (2_500_000_000, "2.5B"), (-1_500, "-1.5K"),
    ])
    func tokensNeverOverflowTheirUnit(value: Int, expected: String) {
        #expect(MetricFormat.tokens(value) == expected)
    }

    @Test func ratesChooseDecimalsAfterRounding() {
        #expect(MetricFormat.rate(nil) == "—")
        #expect(MetricFormat.rate(.nan) == "—")
        #expect(MetricFormat.rate(0) == "0")
        #expect(MetricFormat.rate(0.04) == "0.0")
        #expect(MetricFormat.rate(21.2) == "21.2")
        #expect(MetricFormat.rate(99.94) == "99.9")
        #expect(MetricFormat.rate(99.96) == "100")
        #expect(MetricFormat.rate(146.4) == "146")
    }

    @Test func wholeRatesKeepUnknownDistinctFromZero() {
        #expect(MetricFormat.wholeRate(nil) == "—")
        #expect(MetricFormat.wholeRate(0) == "0")
        #expect(MetricFormat.wholeRate(21.6) == "22")
        #expect(MetricFormat.wholeRate(.infinity) == "—")
    }

    @Test func selectionFallsBackToAllWhenItsHarnessDisappears() {
        var snapshot = Demo.snapshot()
        let dashboard = Dashboard(snapshot: snapshot)
        #expect(dashboard.validSelection(.codex) == .codex)
        #expect(dashboard.validSelection(.gemini) == nil)
        #expect(dashboard.validSelection(nil) == nil)
        snapshot.sources.removeAll { $0.kind == .codex }
        #expect(Dashboard(snapshot: snapshot).validSelection(.codex) == nil)
    }

    @Test func averageTPSIsDurationWeightedAcrossTheSelection() {
        let snapshot = Demo.snapshot()
        let all = Dashboard(snapshot: snapshot)
        let output = snapshot.activities.reduce(0) { $0 + $1.timedOutput }
        let duration = snapshot.activities.reduce(0) { $0 + $1.durationMs }
        #expect(abs((all.averageTPS ?? 0) - Double(output) * 1_000 / Double(duration)) < 0.01)
        let codex = Dashboard(snapshot: snapshot, selectedSource: .codex)
        #expect(abs((codex.averageTPS ?? 0) - 88.4) < 0.1)
    }
}
