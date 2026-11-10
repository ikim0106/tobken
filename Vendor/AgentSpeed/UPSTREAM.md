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
- Tobken enables `ObservedOutputWindow` in `TranscriptSession`'s engine. Each
  positive output usage delta is placed evenly across the interval it was
  generated: from the previous update of that response, or for the first from
  its `firstMs` or `startMs`, to its logged `endMs` (clamped to now and to 15
  minutes). Live TPS is the output placed in the trailing ten seconds, divided
  by ten. Unlike upstream's 6.3, nothing is estimated for unmeasured or
  in-flight responses. Startup reads establish the baseline; duplicate
  records, unchanged finalizations and input do not count as new output.
  Corrections retract recent contributions and late model identification moves
  attribution. Daily request TPS and TTFT retain upstream timing semantics.
- New `ObservedSeries` carries that reading at each second of the last minute
  (nil before monitoring began) through `LiveWindow`, `EngineOutput`,
  `SnapshotBuilder` and `SpeedSnapshot.observedSeries`, in total and per
  source, so the app's graph can fill in completed responses.
- `MonitorCore` uses a coalesced one-second timer only while output remains in
  that window or throttled database reads are pending. `ActiveFileWatcher`
  uses bounded vnode subscriptions alongside FSEvents to notice open-writer
  appends while idle. Ten-second rediscovery remains as a fallback, closes
  idle database connections and handles midnight. Context is reused between
  data changes; the unused reconstructed history is skipped.
- OpenCode's periodic reconciliation skips SQL when its database and WAL are
  unchanged, while retaining a separate reconciliation signature so a live
  refresh cannot hide deletions. Quiet-session memory compaction still runs.

## Excluded from the build

`Package.swift` excludes these upstream paths from the `AgentSpeedCore`
target. The files stay on disk, unmodified, so the pin remains diffable:

- `Characters`, `Lan`, `Money`, `Network`, `Profile`, `DemoDriver.swift`.
- `Updates/` except `Checksums.swift` (`Remote` uses its `FileDigest`).
- `Reporting/ReportStreamSession.swift` and
  `Reporting/URLSessionReportStream.swift`.

The rest of `Reporting`, `Remote`, `Pricing`, `History`, `Perf`, `Modes`,
`WorkSignals`, `Traffic`, `Unpriced` and `Intelligence` are referenced by the
engine, ledger or snapshot types and stay compiled. In particular
`ReportTransport` (URLSession) is still linked, but Tobken never constructs a
report client, remote coordinator or price book. Excluding more would require
editing kept engine files; reassess when the pin is next upgraded.

Request TPS includes first-token wait and uses upstream's minimum 500 ms
duration. TTFT is an estimate of first logged content latency, available only
when a response records a valid start and first-content timestamp. Percentiles
use the upstream bounded latency histogram and are marked approximate in the UI.
