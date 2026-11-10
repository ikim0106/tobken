# Resource measurements

The optimized release uses less CPU during quiet monitoring. A memory
reduction was not established.

Measured on macOS arm64, Swift 6.3.1, 2026-11-10, with 11 logical cores. Both
release apps ran concurrently against the same configured local histories,
with their menus closed, both freshly launched and startup settled. The host
remained in normal use; load averages at measurement start were 2.62, 3.39 and
3.60. Five paired
ten-second windows share that background load, with counter-read order
alternating between the two processes.

| Metric | Before: median (range) | After: median (range) |
| --- | --- | --- |
| CPU, % of one core | 0.199% (0.173–0.249%) | 0.038% (0.031–0.101%) |
| Physical footprint, MiB | 78.94 (78.70–79.36) | 74.28 (74.19–74.53) |
| Package idle wakeups/s | 0.30 (0–0.30) | 0.10 (0–0.30) |

Before is `c7e972f`; after includes event-driven idle scheduling and observed
five-second TPS. Raw counters, I/O deltas and summaries are in
[resource-samples.json](resource-samples.json). CPU uses nanoseconds of process
user + system time divided by wall time; 100% means one fully used core.
Package idle wakeups are a kernel power counter, not the number of dispatched
callbacks. Zero in that column does not mean no work occurred.

An earlier five-window comparison measured median CPU of 0.166% before and
0.0056% after, with memory at 80.56 and 81.02 MiB respectively. Its raw samples
are retained under `earlier_comparison` in the same JSON. An intermediate build
also measured about 64 MiB. CPU reductions reproduced across the comparisons;
the memory reduction did not. Log activity and allocation state vary during
normal use, so neither the lowest CPU sample nor the lowest footprint is a
fixed resource budget.
These short samples do not establish a long-running memory ceiling, startup
peak or sustained generation cost. Memory depends on retained requests and
sessions; the app still builds today's accounting state at startup.

## What changed

Separate profiling of the original release found repeated status-item drawing,
snapshot computation and OpenCode reconciliation, including SQL reads when the
database was unchanged. The original collector published every half-second
and polled recent files every second even while quiet.

The replacement wakes on FSEvents and bounded vnode notifications. It publishes
at most once per second during output activity, then stops that timer after
the five-second output window empties. A ten-second discovery check remains
for new sources, missed events, midnight and connection cleanup. OpenCode's
unchanged database/WAL no longer triggers reconciliation queries. The native
status item redraws only for changed text. Closed menus retain no SwiftUI
hosting controller, and the collector skips its unused reconstructed graph.

This removes recurring work; the remaining quiet cost includes discovery,
filesystem notifications and native status-item handling. This measurement
does not show how much each individual change contributed.

## Repeat

Build with `Scripts/build.sh`, launch the release, leave menus closed and let
startup settle. For a comparison, launch both builds against the same data:

```sh
python3 Scripts/measure-resources.py BEFORE_PID AFTER_PID --seconds 10 --rounds 5
```

The script reads `proc_pid_rusage` kernel counters, checks API failures and
process identity, and prints per-window samples plus median/min/max. It creates
no polling or telemetry inside Tobken. Profile in a separate run so sampling
overhead does not contaminate the reported CPU counters.

Correctness is checked separately: 21 tests pass, including real open-writer
appends while idle, rate-limited publishing and atomic file replacement. The
packaged `--verify` proves accounting through seed/append/restart and observes
**0 → 80 → 0 TPS** after 400 new output tokens. The native UI test checks menu
opening, closing, reopening and release of closed views. Performance does not
come from disabling collection or returning empty totals.
