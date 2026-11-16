---
title: Contributing
category: Contributing
summary: Report bugs, request features, or open a pull request against the dev branch.
settingsPath: ''
order: 90
---

<!-- Documentation current through ZenOS v4.3.0. -->

Contributions that keep ZenOS clean, minimal, and fast are always welcome.

> **Open all [pull requests](https://github.com/xZenLabs/zen-os/pulls) against `dev`.** PRs to `main` will get asked to retarget.

## Bugs and ideas

Open an [issue](https://github.com/xZenLabs/zen-os/issues). For bugs, include:

- What happened and what you expected.
- KOReader version and device (**Zen Settings > About**).
- Steps to reproduce.
- `crash.log` from the KOReader folder if it crashed.

For features, tell me what and why. Keep the philosophy in mind: less clutter or real value. Mockups help.

For translations, see [Translations](/zen-os/docs/translations).

## Code

ZenOS is a plain Lua KOReader plugin. No build step to run it.

1. [Fork](https://github.com/xZenLabs/zen-os/fork) and branch: `git checkout -b fix/my-bug`.
2. Copy `zenos.koplugin` into `plugins/` on your device or the [KOReader emulator](https://github.com/koreader/koreader/blob/master/doc/Building.md) (fastest way to iterate), and restart.
3. Wrap new UI strings in `_()` and add them to `locales/en.po` with an empty `msgstr ""`.
4. Run the checks:

```sh
./spec/run lua
./spec/run smoke
./spec/run package-check
luacheck -q _meta.lua main.lua common config modules
./build.sh
```

`build.sh` makes `zenos.koplugin.zip` and the `zen_ui.koplugin.zip` updater bridge.

## PR checklist

- One feature or fix per PR, targeting `dev`.
- Tested on a device or the emulator.
- New strings wrapped in `_()` and added to `en.po`.
- `./build.sh` works.
- No leftover debug logs or commented-out code.
- If you used AI, review and test everything before submitting.
