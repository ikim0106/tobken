# Initial app verification

Verified locally on 2026-11-10, macOS arm64, with Swift 6.3.1.

## Accounting and collection

`Scripts/test.sh`: **10 tests passed**.

- Replacing provisional usage and replaying final usage leaves one request,
  updates its model attribution, and does not double count.
- Input, cache, output, and reasoning totals preserve the collector's normalized
  accounting. Large input counts never increase output TPS.
- Concurrent model rates add up to the global output rate; in-flight estimates
  retain model attribution.
- Missing timing remains unavailable; active requests without a rate show a
  dash, while idle shows zero.
- Aggregation across harnesses uses summed output / summed duration, includes
  unknown models, and keeps the status title independent of menu filters.
- Midnight clears daily statistics. TTFT p95 requires at least 20 samples.
- The real background monitor seeds a synthetic transcript, reads an append
  while its writer remains open, and reconstructs the same total in a new
  monitor instance.

The packaged release binary's `--verify` also passed independently:

```text
PASS: seed 1,200 → append 4,600 → restart 4,600; model totals match;
filters preserve status total; unknown TTFT preserved.
```

## Native UI and bundle

`Scripts/build.sh` produced `dist/Tobken.app`. Its ad hoc signature passed
`codesign --verify --deep --strict`.

The packaged binary's `--ui-smoke-test` passed with macOS desktop access. It
invokes the actual status item's action, verifies the popover opens, changes
the harness selection, verifies the menu shrinks and the global status title
stays unchanged, then opens the production Settings window. The runtime result
is saved in [ui-smoke.json](ui-smoke.json).

The production SwiftUI menu was rendered in light and dark appearances using
synthetic data and inspected directly. Images: [light](tobken-light.png),
[dark](tobken-dark.png). The images contain no user transcripts or usage.

The native checks caught and resolved initial popover size negotiation and
content-height preference issues. Preview generation alone did not detect the
popover issue. Desktop checks must run with access to macOS WindowServer and
LaunchServices; the headless accounting verifier does not initialize AppKit.

## Limits

These checks exercise synthetic Codex transcripts and the shared request/rate
engine. They do not establish compatibility with every installed version of
every supported harness. Upstream parser fixtures were investigated separately;
see the [research results](../research/reports/verification.md).

Current TPS and TTFT remain estimates from transcript timing. There is no
interception of actual token streaming, Cursor reader, remote aggregation, or
browser chat tracking in this version.

## TPS graph correction

`Scripts/test.sh`: **14 tests passed**, including four graph regressions.
The constant-rate reproduction runs the actual engine across a second boundary:
its current partial bucket falls from 99.9 to zero while its trailing live rate
stays at 100 TPS. This confirms why the previous sparkline showed a false dip.
The new graph records the same live rate as the displayed number; its two
readings remain `[100, 100]` across that boundary.

Additional checks cover replacing only the current second's reading, preserving
past readings, retaining unknown readings as gaps, limiting the time window to
60 seconds, and keeping the vertical scale stable when an old peak expires.
The native smoke test also checks that the latest graph reading matches the
displayed TPS. Light and dark previews were regenerated from the production UI.

## Scrollbar behavior

Tobken sets its own `AppleShowScrollBars` preference to `WhenScrolling` before
initializing AppKit. This selects the native overlay scrollbars that fade after
activity stops. The native smoke test checks the real `NSScrollView` instances
in the menu and Settings use `.overlay`. System-wide preferences are untouched.
