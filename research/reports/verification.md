# Investigation verification

Date: 2026-11-10.

## Source audit

Four top-level repositories were cloned, and Syrtis's actual shared-core
submodule was checked out at its recorded gitlink. All five source trees were
clean after inspection and checks. Exact commits, file hashes, line counts and
immutable source URLs are in [source-evidence.json](source-evidence.json).

Code inspection followed the title/polling path in Syrtis, the native performance
and layout paths in CodexBar, normalization/aggregation in both tokscale engines,
and parser/timing/live-rate paths in Agent Speed.

Committed screenshots were opened for CodexBar's menu, Syrtis's model breakdown,
and Agent Speed's dashboard. These establish visual references; they are not
proof of live app behavior.

## Independent reference implementation

Working directory: `research/upstream/agent-speed`.

```sh
python3 spec/tools/reference.py --check-fixtures
```

Exit status: 0. Captured output:

```text
reference implementation matches all fixtures (58 files, 12 Antigravity databases, 3 OpenClaw databases, 4 Hermes log files, 17 Droid read cycles, 24 engine cases, price cases, 4 model attribution cases, unpriced 24 diagnose, 7 read, 17 quote, 1 live cases and 6 reports, 69 performance history records)
```

The checker uses the project's supplied fixtures, not the user's conversation
history. Its reference math passing does not establish true streaming-token
visibility; the reconstructed/estimated semantics are what the fixtures test.

## Swift implementation

Working directory: `research/upstream/agent-speed/macos`.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/tobken-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/tobken-swift-module-cache \
swift test --disable-sandbox \
  --scratch-path /private/tmp/tobken-agent-speed-build \
  --cache-path /private/tmp/tobken-swift-cache \
  --filter 'EngineCaseTests|EngineBehaviorTests|ParserFixtureTests'
```

Exit status: 0. Swift Testing reported 13 tests in three suites passed, including
24 parameterized engine cases. Selected suites:

- Parser fixtures
- Engine fixture cases
- Engine behavior

The cases exercise concurrent agents, measured versus estimated output, fallback
references, invalid timing, provisional/final replacement and day rollover.
Compiler warnings are retained in the [raw build/test log](agent-speed-swift-tests.log).

## Boundaries

No Tobken app was implemented. CodexBar and Syrtis were not built or run; Agent
Speed's build products were exercised through the selected synthetic tests only.
No CPU, energy, latency or token-generation benchmark was performed. No account
endpoint, credential store or real conversation log was queried. Installed app
versions were read from bundle metadata only.

Official interfaces were checked against OpenAI, Anthropic, OpenCode and LiteLLM
documentation. They require harness/version-specific integration proofs before
claiming accurate live output, transport timing or deduplication across collectors.
