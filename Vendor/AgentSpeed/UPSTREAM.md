# Agent Speed source

Repository: https://github.com/zoefix/agent-speed

Revision: `9d50d8c28bdee0be2be4e77560903795827295bc`.

Copied `macos/Sources/AgentSpeedCore` and `macos/Sources/CZstd`. The MIT license
and the bundled Zstandard license are retained. `METRICS.md` records upstream
measurement semantics. No update service, reporting service or remote transport
is started by Tobken; it uses the local `LiveMonitor` only, without pricing.

Local changes:

- `ActivityMetrics.swift` adds per-source/provider/model daily statistics.
- `DayLedger` updates these in the existing replace path, including subtraction
  of provisional contributions. It remains the sole owner of daily accounting.
- `LiveWindow` projects the same live output contributions by activity key.
- `SpeedEngine`, `EngineOutput`, `SpeedSnapshot`, and `SnapshotBuilder` carry the
  new statistics to the UI without another transcript scan.

Request TPS includes first-token wait and uses upstream's minimum 500 ms
duration. TTFT is an estimate of first logged content latency, available only
when a response records a valid start and first-content timestamp. Percentiles
use the upstream bounded latency histogram and are marked approximate in the UI.
