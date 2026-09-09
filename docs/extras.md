---
title: Extras
category: Extras
summary: Additional Zen goodies like OPDS, lighting schedules, and sleep settings
settingsPath: Zen Settings > Extras
order: 60
---

<!-- Documentation current through ZenOS v3.3.0. -->

## Overview

Extras collects optional additions that fall outside of the Library/Reader. It includes Stats, ZenPM installation, Zen OPDS, TBR behavior, custom icons, Rakuyomi return behavior, lighting automation, whole-word search matching, sleep settings, and Lockdown Mode.

## ZenPM

On supported non-Android ARM32 and ARM64 devices, choose **Zen Settings > Extras > Install ZenPM** to install the Zen plugin manager directly from ZenOS.

## Stats

Open the **Stats** tab from the Navbar to view reading activity. Use **Zen Settings > Extras > Stats** to choose and arrange the dashboard widgets, enable Edit mode for on-page adjustments, set the default text size, and choose stat separators. Widgets can show activity for today, week, month, year, all time, personal records, your library, the current book, reading trends, goals, and the reading calendar.

### Widgets and settings

Choose from Today, This week, This month, This year, All time, Personal records, Library, Current book, Reading trend, Reading goals, and Reading calendar widgets. Enable the widgets you want and hold an item in **Zen Settings > Extras > Stats > Widgets** to arrange its position. The dashboard has six slots; the Reading calendar uses two.

The Reading trend widget can show pages or time for the past 7, 14, 30, or 90 days. Page totals use stable pages when a book provides them. Text-based widgets can use the default Stats font size or an individual override. Enable **Edit mode** to open a widget's settings directly from the Stats page, use **Stat separators** to choose dividers, outlines, or no separation, and set **Week reset day** to Sunday or Monday.

## OPDS

![OPDS catalog](/images/zen_os/opds.webp)

![OPDS context menu](/images/zen_os/opds_context.webp)

Enable **Zen Settings > Extras > Zen OPDS** to apply ZenOS styling to the OPDS catalog browser. The OPDS view inherits the same styling as your library: rounded corners, list and mosaic view, items per page, and other layout options all carry over. Each book in the catalog shows its cover.

Tap and hold any item to open the OPDS context menu for per-item actions.

## To Be Read

To add one book to your To Be Read list, tap and hold it in the Library, choose **Read status**, then choose **To Be Read**. The book appears in the To Be Read Navbar tab and anywhere the Home Featured or unified Strip widget uses To Be Read as its source.

To include every new book automatically, enable **Zen Settings > Library > Include new books in TBR**. This adds books with the New status to the To Be Read Navbar tab and Home widgets without changing their saved read status. New includes unread books and books modified since they were last opened.

## Custom Icons

The bundled ZenOS and KOReader icons remain the default. To use loose icon
overrides, enable **Zen Settings > Extras > Enable custom icons** and place them directly in
`/koreader/icons` as before.

For a named pack, copy its folder or ZIP into `/koreader/icons/zen`, enable
custom icons, and select it under **Zen Settings > Extras > Custom icon pack**. Valid ZIPs are
installed automatically. See [Custom Icon Packs](/zen-os/docs/icon-packs) for the complete
installation and authoring guide.

> Note: Icons placed directly inside `/koreader/plugins/zenos.koplugin/icons` are erased on updates, so do not put custom icons there.

## Rakuyomi

Enable **Zen Settings > Extras > Rakuyomi > Return to chapter list on exit** to keep the current behavior: Rakuyomi-owned books return to the manga chapter list when you exit the reader.

Disable it to return to the Rakuyomi library view instead.

## Schedules

Use **Zen Settings > Extras > Schedules** for automatic brightness, night mode, and warmth changes. Brightness and warmth can follow either a clock schedule or KOReader's light/dark mode, with separate values for each state. These two methods are mutually exclusive for each setting: enabling a schedule turns off its light/dark values, and enabling light/dark values turns off its schedule.

Lighting automation disables KOReader's Auto warmth and night mode plugin because it would compete for the same device controls. Warmth settings appear only on devices with natural-light support.

## Search, Sleep, And Lockdown

Use **Zen Settings > Extras > Search** to switch library search between substring and whole-word matching.

Use **Zen Settings > Extras > Sleep** for KOReader sleep screen controls, sleep presets, automatic dimmer, and automatic suspend integrations when available.

Use **Zen Settings > Extras > Lockdown mode** to configure library, Controls, and reader restrictions.

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
| Library > Include new books in TBR | Adds books with the New status to the To Be Read tab and Home widgets. New includes unread books and books modified since they were last opened. |
| Extras > Enable custom icons | Enables loose icon overrides or the selected ZenOS icon pack. |
| Extras > Custom icon pack | Installs ZIPs from `/koreader/icons/zen` and selects an unpacked pack. |
| Extras > Rakuyomi > Return to chapter list on exit | Returns Rakuyomi-owned books to their manga chapter list when exiting the reader. Disable this to return to Rakuyomi library view. |
| Extras > Search > Match whole words | Uses whole-word search instead of substring search. |
| Extras > Schedules > Brightness > Enable brightness schedule | Enables automatic frontlight brightness changes and sets day/night times and values. |
| Extras > Schedules > Brightness > Light mode / Dark mode brightness | Applies separate brightness values as KOReader changes between light and dark mode, without requiring a clock schedule. |
| Extras > Schedules > Night mode schedule > Enable night mode schedule | Enables automatic night mode changes and sets on/off times. |
| Extras > Schedules > Warmth > Enable warmth schedule | Enables automatic warmth changes and sets day/night times and values on natural-light devices. |
| Extras > Schedules > Warmth > Light mode / Dark mode warmth | Applies separate warmth values as KOReader changes between light and dark mode, without requiring a clock schedule. |
| Extras > Sleep | Shows supported sleep screen controls, sleep presets, automatic dimmer, and automatic suspend integrations. |
| Extras > Lockdown mode | Configures library, Controls, and reader restrictions for Lockdown Mode. |
