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
- Tobken enables `ObservedOutputWindow` in `TranscriptSession`'s engine. Live
  TPS counts positive output usage deltas observed during the trailing five
  seconds, divided by five. Startup reads establish the baseline; duplicate
  records, unchanged finalizations and input do not count as new output.
  Corrections retract recent contributions and late model identification moves
  attribution. This replaces upstream's reconstructed/predicted live rate for
  Tobken; daily request TPS and TTFT retain upstream timing semantics.
- `MonitorCore` uses a coalesced one-second timer only while output remains in
  that window or throttled database reads are pending. `ActiveFileWatcher`
  uses bounded vnode subscriptions alongside FSEvents to notice open-writer
  appends while idle. Ten-second rediscovery remains as a fallback, closes
  idle database connections and handles midnight. Context is reused between
  data changes; the unused reconstructed history is skipped.
- OpenCode's periodic reconciliation skips SQL when its database and WAL are
  unchanged, while retaining a separate reconciliation signature so a live
  refresh cannot hide deletions. Quiet-session memory compaction still runs.

Request TPS includes first-token wait and uses upstream's minimum 500 ms
duration. TTFT is an estimate of first logged content latency, available only
when a response records a valid start and first-content timestamp. Percentiles
use the upstream bounded latency histogram and are marked approximate in the UI.
