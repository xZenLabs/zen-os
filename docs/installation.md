---
title: Installation
category: Getting Started
summary: Install ZenOS by copying the plugin folder into your KOReader plugins directory.
settingsPath: ''
order: 5
---

<!-- Documentation current through ZenOS v4.3.0. -->

## Before you start

- Install [KOReader](https://github.com/koreader/koreader#installation) 2026.03 or newer. ZenOS is tested on 2026.07.
- Remove or disable **Project: Title** (see below). ZenOS handles the other conflicting plugins for you.

## Install

1. Download `zenos.koplugin.zip` from the latest [release](https://github.com/xZenLabs/zen-os/releases).
2. Unzip it. You should get a **folder** called `zenos.koplugin`.
3. Copy that **folder** (not the zip) into your device's plugins directory:

| Device | Plugins directory |
| --- | --- |
| **Kobo** | `/mnt/onboard/.adds/koreader/plugins/` |
| **Kindle** | `/mnt/base-us/koreader/plugins/` |
| **PocketBook** | `/mnt/ext1/applications/koreader/plugins/` |
| **Android** | `/sdcard/koreader/plugins/` |
| **Desktop (Linux/macOS)** | `/koreader/plugins/` |

4. Restart KOReader. The setup guide walks you through the rest.

> The final path should look like `.../plugins/zenos.koplugin/main.lua`

![zenos.koplugin folder inside the KOReader plugins directory](/images/zen_os/plugins_folder.webp)

Not loading? Enable it under **Tools > More tools > Plugin management > ZenOS**, and check the [FAQ](/zen-os/docs/faq).

## Coming from Zen UI?

Don't install ZenOS next to it. Update from Zen UI's settings page instead. It keeps your settings and moves everything over after two automatic restarts. If Zen UI is disabled, turn it on once so the move can run.

Your old settings stay in `koreader/settings/Zen UI` as a backup, so downgrading puts you right back where you were.

## Coming from Project: Title?

Both plugins patch the same parts of KOReader, so only one can run. Either:

- **Remove it**: delete `projecttitle.koplugin` from your plugins folder, or
- **Disable it**: rename it to `projecttitle.koplugin.disabled`.

Then restart KOReader.

![ZenOS Startup Screen](/images/zen_os/quickstart.webp)
