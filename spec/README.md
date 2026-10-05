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

Runtime versions live in `koreader-lock.json`. Update a pin deliberately, then
regenerate the affected goldens and review every PNG diff. Test artifacts belong
under `spec/.artifacts/` and are ignored by Git.

Run the migration contract against the pinned minimum and current stable runtimes with:

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

## Linux goldens

The committed framebuffer baselines are generated only on Linux/Xvfb at
800×600. Run the `Generate Linux Goldens` workflow manually, download its
`linux-goldens` artifact, review the PNGs, and commit the approved files under
`spec/goldens/v2026.07/linux-800x600/`. Normal CI only compares committed
baselines; it never writes or pushes goldens. A missing Linux baseline is a
test failure, so the initial artifact must be reviewed and committed before
the regular CI job can pass.
