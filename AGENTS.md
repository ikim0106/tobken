# Working on Tobken

Use Conventional Commits: `type(scope): lowercase imperative summary`.
Keep subjects around 72 characters; wrap nontrivial bodies around 72 columns.

Tobken is a native macOS menu bar app. Product labels use TPS, TTFT, and tokens
today. TPS always counts output; input/cache must never increase it. Preserve
unknown and estimated readings separately from zero. Filters change the open
menu, while the status item always shows the global total.
Display TPS and TTFT without `~` prefixes; explain approximations in tooltips.
Current TPS counts newly observed output usage in the last five seconds / five,
including quiet seconds. Never substitute historical request speeds for new
output. Completion-only logs may produce bursts; describe this in tooltips.
Request averages include within-request waits and exclude idle between requests.

Resource use is a product requirement. Stop live refresh timers when idle, cap
active publishing at once per second, and use incremental file notifications.
Avoid redrawing unchanged status text or retaining closed SwiftUI views. Measure
release CPU and physical footprint before claiming an improvement.

`Vendor/AgentSpeed` is pinned source, with local changes recorded in its
`UPSTREAM.md`. Extend its existing request ledger rather than rescanning histories
for UI updates. Preserve licenses when reusing upstream code.

Build with `Scripts/build.sh`; test with `Scripts/test.sh`. Verify the packaged
binary with `--verify` against synthetic data before handing it off. Use
`--render-preview <directory>` to inspect the actual production SwiftUI view in
light and dark appearances without reading user histories.
