# Tobken

A native macOS menu bar app for tokens today, TPS, and TTFT across your local
coding tools. The status bar always shows the global total. Click it for model
and harness breakdowns; select a harness to filter the menu. Right-click for
Settings, Rescan Logs and Quit.

![Tobken in dark mode](docs/tobken-dark.png)

## Run

Requires macOS 14 or later and a Swift 6 toolchain (Xcode or Command Line Tools).
The build is universal (Apple silicon and Intel); the version comes from `VERSION`.

```sh
Scripts/build.sh
open dist/Tobken.app
```

The app has no Dock icon. Look for the token count in the menu bar. It reads
supported logs automatically; Settings lets you add other transcript locations
and turn on **Open Tobken at login**. Move the app to `/Applications` first so
the login item points at a stable path. The local build is ad hoc signed, so
macOS may ask you to approve the login item in System Settings → General →
Login Items.

```sh
Scripts/test.sh
dist/Tobken.app/Contents/MacOS/Tobken --verify
dist/Tobken.app/Contents/MacOS/Tobken --demo
dist/Tobken.app/Contents/MacOS/Tobken --render-preview /tmp/tobken-preview  # menu, filtered menu, Settings
dist/Tobken.app/Contents/MacOS/Tobken --ui-smoke-test /tmp/tobken-ui-smoke
```

`--demo` and previews use synthetic data. `--verify` creates isolated transcripts
and checks the production background reader through seed, append, and restart.
The UI smoke test requires an active macOS desktop session and uses demo data.

## What the numbers mean

- **Tokens today:** input + output since local midnight, across every detected
  supported harness and model. Cached input and reasoning are already included
  in input/output; they are not added twice. Requests count when their usage is
  logged, so an unfinished request may appear later. Missing model names still
  contribute to totals.
- **Current TPS:** new output tokens observed in logs in the last five seconds,
  divided by five, summed across all tools and models. Quiet seconds count as
  zero; after five seconds without new output the reading is `0`, even if a
  request is still marked active. Input never increases TPS. Startup history,
  duplicate records and finalizing an unchanged usage count do not add output.
  Tools that report usage only at completion produce bursts; this measures
  observed log throughput, not individual token emission or predicted speed.
  A dash means the monitor is starting or has no supported sources. The menu
  bar shows it as a whole number; harness rows label it "TPS now".
  The graph records that same TPS reading over 60 seconds, with the latest
  reading at the right-hand dot. It keeps past readings fixed and leaves gaps
  for unavailable readings. The labeled scale stays fixed during activity,
  grows for new peaks, and resets after a full idle minute. It fills as the
  app observes activity; it does not reconstruct a history on startup. With a
  harness selected, the graph shows that harness's own readings.
- **Avg TPS** (summary and model rows): today's output divided by summed timed request
  durations, including TTFT. It is weighted by duration, not an average of the
  displayed per-request rates. This includes pauses within requests and excludes
  idle time between them. Intervals under 500 ms are widened to 500 ms;
  missing or invalid intervals do not contribute to speed.
- **TTFT:** approximate p50 from the first content timestamp a harness writes.
  Some harnesses do not record it; `—` means unavailable. Expand a model for
  current TPS, sample counts, response duration p50, and TTFT p95 (20+ samples).
  Percentiles use the collector's logarithmic latency histogram.

This first version reads local logs. It does not capture browser chat, remote
machines, or every arbitrary API client. Cursor is not supported yet. It starts
no proxy, account login, pricing fetch, telemetry, or remote listener. Your
transcripts are not uploaded.

## Resource use

File notifications trigger incremental reads. Snapshots publish at most once a
second during output activity and stop when the five-second window reaches
zero. A ten-second discovery check catches missed events and new sources.
Recent files have at most 32 transcript watchers plus OpenCode database/WAL
watchers. Unchanged menu-bar text is not redrawn. The menu and Settings views
are created when opened and released when closed; no hidden graph animates.
The graph fills known quiet intervals with zeros when activity resumes or the
menu opens. While the menu is open after output stops, a one-second timer keeps
the graph moving until it is flat; nothing ticks with the menu closed. While
output is active the menu bar item only grows, so neighbouring items do not
shift each second.

See [resource measurements](docs/resource-use.md) for measured CPU/memory costs
and the repeatable sampling command. Startup still reads today's history;
memory also depends on the number of requests and sessions being tracked.

## Supported harnesses

Codex, Claude Code, Claude Desktop's local agent logs, DeepSeek Harness,
OpenCode, Gemini CLI, Pi, oh-my-pi, Antigravity, WorkBuddy, WorkBuddy AI, ZCode,
Kimi, Grok Build, OpenClaw, Hermes, Factory Droid, and Devin CLI. Actual coverage
depends on the installed tool writing a supported transcript format. Reader
warnings are shown in the menu; hover for details.

## Code and provenance

- `Sources/Tobken`: AppKit status item and SwiftUI dropdown/settings, plus the
  UI smoke test and preview renderer.
- `Sources/TobkenCore`: presentation, grouping, formatting, synthetic fixtures,
  and an end-to-end verifier.
- `Vendor/AgentSpeed`: pinned MIT collector, request ledger, and live-rate
  engine. Small local changes expose model statistics from the existing ledger;
  see [provenance](Vendor/AgentSpeed/UPSTREAM.md).
- `Vendor/CodexBar`: MIT license and provenance for reused layout constants.
  The compact native UI follows CodexBar's visual style; this is a separate
  application, not a full CodexBar fork.

The package uses no remote Swift dependencies. App packaging includes upstream
licenses. Upstream features Tobken never uses (LAN sharing, profiles,
characters, price fetchers, the self-updater) are excluded from the build; the
remaining reporting and remote code is compiled because the engine references
its types, but Tobken never starts it. See
[provenance](Vendor/AgentSpeed/UPSTREAM.md) for the exact list.

## Investigation

- [Full investigation](research/reports/investigation.md)
- [Pinned source inventory](research/reports/source-evidence.json)
- [Research verification](research/reports/verification.md)
- [App verification](docs/verification.md)

Reference checkouts live under the ignored `research/upstream/` directory.
All needed application source is included in `Vendor/`; those checkouts are not
required to build.
