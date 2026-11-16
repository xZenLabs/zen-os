# ZenOS tests

Run all commands from the plugin root through `./spec/run`.

- `lua` runs Busted specs with KOReader's LuaJIT and a fresh `KO_HOME`.
- `smoke` runs the deterministic Python smoke contract against the stable runtime.
- `full` runs Lua, smoke, visual golden checks, and package validation.
- `nightly-smoke` repeats the smoke contract against the latest KOReader master runtime.
- `legacy-upgrade` stages the compatibility package, enables a disabled legacy install
  through KOReader's plugin manager, and verifies both restart boundaries plus final state.
- `update-goldens` is the only command allowed to replace committed PNG baselines.
- `package-check` builds the plugin and asserts that test assets are absent.
- `bench` runs emulator benchmarks and writes `spec/.artifacts/benchmark/REPORT.md`.

## Benchmarks

`./spec/run bench` measures the scenarios and metrics of
[kindle_benchmark](https://github.com/d1-m4ss/kindle_benchmark) (`SCENARIOS.md`) against
ZenOS only: start/home/library navigation, first render, sequential and cached paging,
folder enter/back, sort, open/close book, reader page turn, quick settings, repeated
navigation, memory checkpoints, and restart (spawn → first screen, spawn → library).
Each sample records wall time, first content paint, action CPU, heap delta, refresh
requests, requested and submitted dirty area, and a framebuffer hash.

The harness (`zen_ui_test_driver.koplugin/zen_bench.lua`) runs in-process with no
socket polling; `zen_bench.py` generates deterministic synthetic corpora (cached in
`spec/.cache/bench-corpus`; `flat_N` keeps ≥ 3/4 of books in the root plus 12/30/60-book
side folders, `hierarchical_N` nests genre and series folders), orchestrates processes and aggregates. A scenario that
fails its semantic postcondition fails the test; timings never do. The emulator is
pinned to the upstream 1236×1648 @ 300 DPI framebuffer, so numbers are comparable in
shape but stay emulator-relative.

| Variable | Default |
|---|---|
| `ZEN_UI_BENCH_CORPORA` | `flat_50,flat_2000,hierarchical_50,hierarchical_2000` |
| `ZEN_UI_BENCH_STARTUP_CORPUS` | last corpus |
| `ZEN_UI_BENCH_RESTARTS` | `3` |
| `ZEN_UI_BENCH_WARMUP` / `ZEN_UI_BENCH_MEASURE` | `2` / `10` |
| `ZEN_UI_BENCH_BASELINE` | previous `results.json`; adds Δ columns |
| `ZEN_UI_BENCH_VARIANTS` | `zenos,stock` (stock disables ZenOS; adds a ZenOS vs stock section) |
| `ZEN_UI_BENCH_JITP` | scenario name or `startup`; writes `raw/<variant>/<profile>/*.json.folded` sampled stacks |

Profiled runs are for attribution, not timing: the 1 ms sampling signal can disturb
CoverBrowser's forked extractor. `python spec/python/zen_bench.py <file>.folded` prints
inclusive/self time per frame; the folded files also feed standard flame graph tools.

Per-process results and logs land in `raw/<variant>/<profile>/` and
`logs/<variant>/<profile>/` (e.g. `logs/stock/startup/restart_1.log`); each run clears both.

Keep a baseline by copying `spec/.artifacts/benchmark/results.json` before a change.
`python spec/python/zen_bench.py results.json --baseline old.json` re-renders a report.

Set `KOREADER_DIR` to an emulator runtime directory containing `luajit`,
`frontend`, `spec/rocks`, and bundled plugins such as CoverBrowser. Emulator
runs stage those bundled plugins alongside ZenOS and the test driver. The
runner never uses a system Lua interpreter for behavior tests and creates a
temporary `KO_HOME` for every invocation.

Tests keep the emulator in the background without taking desktop focus. Its
windows still render normally, including framebuffer screenshots. Launching
KOReader manually is unchanged.
Pass `--fg` before or after the command to run in the foreground, for example
`./spec/run smoke --fg` or `./spec/run --fg full`.

LuaCheck caches analysis of unchanged files under `spec/.cache/luacheck`.
The emulator test driver polls for commands every 20 ms; each scenario still
starts with its own emulator and temporary settings.
Commands wait for deferred UI work and repaint before replying.
Shutdown goes through the test driver to flush settings and close KOReader
without waiting on SDL input handling; signal and kill fallbacks remain for hung instances.

Runtime versions live in `koreader-lock.json`. Update a pin deliberately, then
regenerate the affected goldens and review every PNG diff. Test artifacts belong
under `spec/.artifacts/` and are ignored by Git.

CI runs the migration contract only through the manual `Zen UI to ZenOS Migration`
workflow, against the pinned minimum and current stable runtimes. Release and regular
test workflows do not run it. To run it locally:

```sh
KOREADER_DIR="$(./spec/provision-koreader.sh compat)" ./spec/run legacy-upgrade
KOREADER_DIR="$(./spec/provision-koreader.sh stable)" ./spec/run legacy-upgrade
```

Both commands stage symlinks to the KOReader runtime and copy ZenOS into a temporary
plugin directory. The migration renames only that disposable copy and a temporary
`KO_HOME`; provisioned source and runtime trees are not mutated.

`runtime-modules.txt` is the explicit production-module inventory. Add every
new runtime Lua file there with its intended test layer before merging it.
The runtime manifest guards against silently omitting unloaded UI and
integration modules from the test plan.

Set `ZEN_UI_PYTEST_TARGET` to one Python test file when debugging a single
emulator scenario; normal smoke and CI runs still execute the complete suite.

Stable CI distributes Python tests across four isolated runners using
`ZEN_UI_PYTEST_SHARD=INDEX/COUNT` (1-based). Each runner keeps its own emulator
display, settings, and artifacts; Lua tests and package checks still run in
every shard. Local runs execute all tests unless this variable is set. For example,
`ZEN_UI_PYTEST_SHARD=1/4 ./spec/run full` runs the first shard locally.
Python runs print the 20 slowest test durations, and CI uploads each shard's
JUnit reports and screenshots for timing and failure analysis.

## Linux goldens

The committed framebuffer baselines are generated only on Linux/Xvfb at
800×600. Run the `Generate Linux Goldens` workflow manually, download its
`linux-goldens` artifact, review the PNGs, and commit the approved files under
`spec/goldens/v2026.07/linux-800x600/`. Normal CI only compares committed
baselines; it never writes or pushes goldens. A missing Linux baseline is a
test failure, so the initial artifact must be reviewed and committed before
the regular CI job can pass.
