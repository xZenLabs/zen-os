---
title: Extras
category: Extras
summary: Additional Zen tools and integrations
settingsPath: Zen Settings > Extras
order: 60
---

<!-- Documentation current through ZenOS v3.3.0. -->

## Overview

Extras contains optional tools and integrations. It covers reading statistics, plugin installation, OPDS browsing, Rakuyomi behavior, and Lockdown Mode.

## ZenPM

On supported non-Android ARM32 and ARM64 devices, choose **Zen Settings > Extras > Install ZenPM** to install the Zen plugin manager directly from ZenOS. ZenPM uses the ZenOS status bar while browsing packages.

## Stats

Open the **Stats** tab from the Navbar to view reading activity. Use **Zen Settings > Extras > Stats** to choose and arrange the dashboard widgets, enable Edit mode for on-page adjustments, set the default text size, and choose stat separators. Widgets can show activity for today, week, month, year, all time, personal records, your library, the current book, reading trends, goals, and the reading calendar.

### Widgets and settings

Choose from Today, This week, This month, This year, All time, Personal records, Library, Current book, Reading trend, Reading goals, and Reading calendar widgets. Enable the widgets you want and hold an item in **Zen Settings > Extras > Stats > Widgets** to arrange its position. The dashboard has six slots; the Reading calendar uses two.

The Reading trend widget can show pages or time for the past 7, 14, 30, or 90 days. Page totals use stable pages when a book provides them. Text-based widgets can use the default Stats font size or an individual override. **Edit mode** is enabled by default to open a widget's settings directly from the Stats page. Use **Stat separators** to choose dividers, outlines, or no separation, and set **Week reset day** to Sunday or Monday.

## OPDS

![OPDS catalog](/images/zen_os/opds.webp)

![OPDS context menu](/images/zen_os/opds_context.webp)

Use the switch on **Zen Settings > Extras > Zen OPDS** to apply ZenOS styling to the OPDS catalog browser. Open its submenu to choose the display mode. The OPDS view inherits the same styling as your library: rounded corners, list and mosaic view, items per page, and other layout options all carry over. Each book in the catalog shows its cover.

Tap and hold any item to open the OPDS context menu for per-item actions.

## Rakuyomi

Enable **Zen Settings > Extras > Rakuyomi > Return to chapter list on exit** to keep the current behavior: Rakuyomi-owned books return to the manga chapter list when you exit the reader.

Disable it to return to the Rakuyomi library view instead.

Enable **Exclude from Home** to keep Rakuyomi chapters out of recent Home content.

## Lockdown Mode

Use **Lockdown mode** to configure library, Controls, and reader restrictions. See [Lockdown Mode](/zen-os/docs/lockdown-mode) for details.

## Setting reference

| Setting | Description |
| --- | --- |
| Extras > Stats > Widgets | Chooses and arranges dashboard widgets. The calendar occupies two widget slots; up to six slots can be enabled. |
| Extras > Stats > Edit mode | Enables editing supported Stats and Home widgets directly from their pages. |
| Extras > Stats > Default font size | Sets the default text size for Stats widgets. Individual supported widgets can override it. |
| Extras > Stats > Stat separators | Selects divider lines, outlines, or no separators for Stats widgets. |
| Extras > Stats > Week reset day | Starts weekly statistics on Sunday or Monday. |
| Extras > Install ZenPM | Installs the Zen plugin manager on supported non-Android ARM devices. |
| Extras > Zen OPDS | Enables ZenOS OPDS enhancements, including cover art, list/mosaic view, hold menu, and navigation changes. |
| Extras > Zen OPDS > Display mode | Selects mosaic, list, or classic OPDS display mode. |
| Extras > Zen OPDS > Prefer large covers | In OPDS mosaic mode, prefer higher quality cover images if available. |
| Extras > Rakuyomi > Exclude from Home | Keeps Rakuyomi chapters out of recent Home content. |
| Extras > Rakuyomi > Return to chapter list on exit | Returns Rakuyomi-owned books to their manga chapter list when exiting the reader. Disable this to return to Rakuyomi library view. |
| Extras > Lockdown mode | Configures library, Controls, and reader restrictions for Lockdown Mode. |
