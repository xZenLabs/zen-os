---
title: General
category: General
summary: Manage connectivity, power, language, time, maintenance, and updates.
settingsPath: Zen Settings > General
order: 70
---

<!-- Documentation current through ZenOS v4.3.0. -->

Device and system stuff: wireless, lighting, sleep, battery, language, and updates.

## Wi-Fi and Bluetooth

Toggle them and open their settings. Bluetooth works on supported Kindle, Kobo, and PocketBook devices.

**Where:** Zen Settings > General > Wi-Fi / Bluetooth

## Schedules

Automate brightness, warmth, and night mode. Brightness and warmth can follow a clock schedule or just switch with light/dark mode. Use whichever you want or none at all.

ZenOS turns off KOReader's Auto warmth plugin while schedules are on so they don't fight.

**Where:** Zen Settings > General > Schedules

## Sleep

Sleep screen, sleep presets, auto dim, and auto suspend.

**Where:** Zen Settings > General > Sleep

## Battery

Charge, health, drain per hour (overall, awake, asleep), screen on/off time, time remaining, and charging history.

ZenOS logs your battery every 30 minutes and on sleep, wake, and charging changes. Time KOReader was closed or charging doesn't count toward drain. Some numbers show `-` until there's about an hour of data. Capacity and health only show if your device reports them.

History is saved to `koreader/settings/ZenOS/battery_history` (one JSON line per window) if you want to dig in. **Reset battery log** starts fresh without losing charging history or health.

**Where:** Zen Settings > General > Battery

## Language and time

Change the KOReader and ZenOS language, and open KOReader's date and time settings.

**Where:** Zen Settings > General > Language / Time and date

## Advanced and Updates

See [Advanced](/zen-os/docs/advanced) and [Updates](/zen-os/docs/updates).
