# Tobken

Native macOS menu bar app (Swift 6, macOS 14+) showing tokens today, current
TPS and TTFT, read from local coding-tool logs. Nothing is uploaded; there is no
proxy, login, telemetry or listener.

## Layout

| Path | Role |
| --- | --- |
| `Sources/Tobken/` | AppKit/SwiftUI app: `Tobken.swift` (entry, `AppController`, status item, popover), `AppModel.swift`, `MenuView.swift`, `TPSChart.swift`, `SettingsView.swift`, `SmokeTest.swift`, `PreviewRenderer.swift` |
| `Sources/TobkenCore/` | UI-free logic: `Dashboard` (derived values, filters), `MetricFormat`, `TPSHistory` (graph readings), `Demo` (synthetic data), `Verification` |
| `Vendor/AgentSpeed/` | Pinned upstream collector (`LiveMonitor`, `SpeedEngine`, `DayLedger`, parsers). Unused upstream features are excluded in `Package.swift` |
| `Vendor/CodexBar/` | License/provenance for `UsageMenuCardLayout.swift` only |
| `Tests/TobkenTests/` | Swift Testing suites |

Put display logic in `TobkenCore` so it can be unit tested; keep `Sources/Tobken`
to views and AppKit wiring.

## Commands

```sh
Scripts/build.sh                       # universal release app → dist/Tobken.app
Scripts/test.sh                        # all tests; append --filter <name> for one
dist/Tobken.app/Contents/MacOS/Tobken --verify               # headless, synthetic transcripts
dist/Tobken.app/Contents/MacOS/Tobken --demo                 # run with synthetic data
dist/Tobken.app/Contents/MacOS/Tobken --render-preview <dir> # menu, filtered menu, Settings; light + dark
dist/Tobken.app/Contents/MacOS/Tobken --ui-smoke-test <dir>  # drives the real status item; needs a desktop session
python3 Scripts/measure-resources.py BEFORE_PID AFTER_PID --seconds 10 --rounds 5
```

Before handing off: tests, build, `--verify`, and inspect `--render-preview`
output. Run `--ui-smoke-test` when a desktop session is available; if it is not,
say so instead of reporting it as passed. The version lives in `VERSION`.

## Metric invariants

- TPS counts output only; input and cache never increase it.
- Current TPS is newly observed output usage in the last five seconds ÷ 5,
  including quiet seconds. Never substitute historical request speeds for new
  output. Completion-only logs produce bursts; say so in tooltips.
- Avg TPS is output ÷ summed request durations: includes TTFT and waits within
  a request, excludes idle time between requests.
- Unknown (`nil`, shown `—`) and estimated readings stay distinct from zero.
- The status item always shows the global total; the harness filter changes
  only the open menu, and never the global graph history.

## Resource rules

Resource use is a product requirement.

- No timers while idle with the menu closed. The open-menu graph timer stops
  once the graph is flat.
- Publish at most once per second; use incremental file notifications.
- Don't redraw unchanged status text; release closed menu and Settings views.
- Measure release CPU and physical footprint (`measure-resources.py`, both
  builds side by side) before claiming an improvement or a regression fix.

## UI rules

- No `~` prefixes on TPS or TTFT; explain approximations in tooltips.
- Visible labels say which TPS is meant ("Current TPS", "Avg TPS", "TPS now").
- Check light and dark previews after any visible change.

## Vendored code

- `Vendor/AgentSpeed` is pinned source. Record every local change and every
  build exclusion in `Vendor/AgentSpeed/UPSTREAM.md`.
- Extend the existing request ledger (`DayLedger`, `ActivityMetrics`) rather
  than rescanning histories for UI updates.
- Preserve licenses when reusing upstream code; `Scripts/build.sh` bundles them.

## Keep in sync

README "What the numbers mean", tooltips in `MenuView`/`TPSChart`, and the
Settings copy describe the same definitions; change them together. Regenerate
`docs/tobken-light.png` and `docs/tobken-dark.png` with `--render-preview` after
visible UI changes.
