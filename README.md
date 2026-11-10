# Tobken

A native macOS menu bar app for tokens today, TPS, and TTFT across your local
coding tools. The status bar always shows the global total. Click it for model
and harness breakdowns; select a harness to filter the menu.

![Tobken in dark mode](docs/tobken-dark.png)

## Run

Requires macOS 14 or later and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
Scripts/build.sh
open dist/Tobken.app
```

The app has no Dock icon. Look for the token count in the menu bar. It reads
supported logs automatically; Settings lets you add other transcript locations.
To launch at login, add `Tobken.app` to macOS System Settings → General → Login
Items. The local build is ad hoc signed.

```sh
Scripts/test.sh
dist/Tobken.app/Contents/MacOS/Tobken --verify
dist/Tobken.app/Contents/MacOS/Tobken --demo
dist/Tobken.app/Contents/MacOS/Tobken --render-preview /tmp/tobken-preview
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
- **Current TPS:** summed output TPS across concurrent requests in a trailing
  three-second window. Completed output is spread
  across the logged request interval, and active requests use recent rates.
  This is an estimate from logs, not a measurement of individual streamed tokens.
  An active request without timing/reference data shows `—`; idle shows `0`.
  The graph records that same TPS reading over 60 seconds, with the latest
  reading at the right-hand dot. It keeps past readings fixed and leaves gaps
  for unavailable readings. The labeled scale stays fixed during activity,
  grows for new peaks, and resets after a full idle minute. It fills as the
  app observes activity; it does not reconstruct a history on startup.
- **TPS in model rows / Avg TPS:** today's output divided by summed timed request
  durations, including TTFT. It is weighted by duration, not an average of the
  displayed per-request rates. Intervals under 500 ms are widened to 500 ms;
  missing or invalid intervals do not contribute to speed.
- **TTFT:** approximate p50 from the first content timestamp a harness writes.
  Some harnesses do not record it; `—` means unavailable. Expand a model for
  current TPS, sample counts, response duration p50, and TTFT p95 (20+ samples).
  Percentiles use the collector's logarithmic latency histogram.

This first version reads local logs. It does not capture browser chat, remote
machines, or every arbitrary API client. Cursor is not supported yet. It starts
no proxy, account login, pricing fetch, telemetry, or remote listener. Your
transcripts are not uploaded.

## Supported harnesses

Codex, Claude Code, Claude Desktop's local agent logs, DeepSeek Harness,
OpenCode, Gemini CLI, Pi, oh-my-pi, Antigravity, WorkBuddy, WorkBuddy AI, ZCode,
Kimi, Grok Build, OpenClaw, Hermes, Factory Droid, and Devin CLI. Actual coverage
depends on the installed tool writing a supported transcript format. Reader
warnings are shown in the menu; hover for details.

## Code and provenance

- `Sources/Tobken`: AppKit status item and SwiftUI dropdown/settings.
- `Sources/TobkenCore`: presentation, grouping, formatting, synthetic fixtures,
  and an end-to-end verifier.
- `Vendor/AgentSpeed`: pinned MIT collector, request ledger, and live-rate
  engine. Small local changes expose model statistics from the existing ledger;
  see [provenance](Vendor/AgentSpeed/UPSTREAM.md).
- `Vendor/CodexBar`: MIT license and provenance for reused layout constants.
  The compact native UI follows CodexBar's visual style; this is a separate
  application, not a full CodexBar fork.

The package uses no remote Swift dependencies. App packaging includes upstream
licenses. The full collector is vendored to keep source compatibility; its
unused networking and reporting facilities are not started by Tobken.

## Investigation

- [Full investigation](research/reports/investigation.md)
- [Pinned source inventory](research/reports/source-evidence.json)
- [Research verification](research/reports/verification.md)
- [Initial app verification](docs/verification.md)

Reference checkouts live under the ignored `research/upstream/` directory.
All needed application source is included in `Vendor/`; those checkouts are not
required to build.
