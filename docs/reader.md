---
title: Reader
category: Reader
summary: Configure reader status bars, bottom status bar presets, font access, lookup tools, and page navigation.
settingsPath: Zen Settings > Reader
order: 50
---

<!-- Documentation current through ZenOS v3.0.0. -->

![Page browser grid](/images/zen_os/page_browser_grid.webp)

![Page browser menu](/images/zen_os/page_browser_menu.webp)

![Page browser table of contents](/images/zen_os/page_browser_toc.webp)

![Page browser bookmarks](/images/zen_os/page_browser_bookmarks.webp)

![Page browser search](/images/zen_os/page_browser_search.webp)

![Reader](/images/zen_os/reader.webp)

![Dictionary lookup menu](/images/zen_os/reader_dict.webp)

![Highlight menu](/images/zen_os/reader_highlight.webp)

![Reader menu](/images/zen_os/reader_menu.webp)

![Book details](/images/zen_os/reader_book_details.webp)

## Overview

Reader settings control ZenOS features while a book is open. They cover the top status bar, reader themes and font menu, highlight and lookup tools, bottom swipe, stable page labels, page browser, return behavior, and bottom status bar options including presets.

![Page browser](/images/zen_os/page_browser.webp)

## Options

- Configure one reader top status bar with shared left, center, and right item slots across document formats.
- Reserve the top bar's space in paged reflowable documents, or paint it over CBZ/PDF files.
- Use the top bar's border as reading progress with optional chapter marks.
- Apply built-in or custom themes for light and dark reader modes.
- Apply prebuilt bottom status bars or save your current setup as a preset.
- Open KOReader's reader font controls from ZenOS.
- Configure Zen quick lookup, Zen highlight menu, Wikipedia, and detected X-Ray, KOAssistant, or AI Assistant integrations.
- Enable bottom swipe and the Zen page browser.
- Use stable page labels in the page browser and table of contents when a book provides a page map.
- Restore the previous library location when leaving the reader.
- Enable or disable the bottom status bar and configure its Zen Presets, font, and CBZ/PDF hiding.

## Setting reference

| Setting | Description |
| --- | --- |
| Top status bar > Enable top status bar | Shows ZenOS's top reader status bar. |
| Top status bar > Left items | Selects and arranges time, combined or separate battery information, Incognito, Wi-Fi, brightness, RAM usage, disk space, custom text, book title, author, chapter, progress percentage, separate current/total pages, or combined current/total pages for the left slot. |
| Top status bar > Center items | Selects and arranges top-bar items for the center slot. |
| Top status bar > Right items | Selects and arranges top-bar items for the right slot. |
| Top status bar > Left/center/right items > Show separator | Shows separators inside the selected slot. |
| Top status bar > Left/center/right items > Custom text | Enables custom text in that slot and opens its value editor. Empty text falls back to the device model. |
| Top status bar > Font size | Sets the top-bar font size from 8 to 36. |
| Top status bar > Font | Sets the top-bar font face or restores the default font. |
| Top status bar > Separator | Selects a preset separator for top-bar items. |
| Top status bar > Show bottom border | Draws a separator below the reader top status bar. |
| Top status bar > Use border as progress bar | Fills the bottom border to show reading progress. Enabling it also enables the border. |
| Top status bar > Chapter marks | Draws table-of-contents marks on the progress border. Enabling it also enables the progress border. |
| Top status bar > Colored status icons | Uses the library status-bar colors for Wi-Fi, storage, memory, brightness, and battery icons on supported color screens. |
| Top status bar > Hide in CBZ/PDF files | Hides the top bar for CBZ and PDF documents. |
| Reader themes > Enable reader themes | Enables ZenOS reader themes. |
| Reader themes > Dark mode | Selects the theme used while KOReader night mode is active. |
| Reader themes > Light mode | Selects the theme used while KOReader night mode is inactive. |
| Reader themes > Custom themes | Creates, edits, and deletes custom themes. A custom theme can set its name, background color, text color, and font. |
| Font > Reader font menu | Opens KOReader's reader font submenu when a reader instance is active. |
| Highlight / Lookup > Zen quick lookup | Enables ZenOS quick lookup behavior. |
| Highlight / Lookup > Zen highlight menu | Enables ZenOS's highlight menu. |
| Highlight / Lookup > Show Wikipedia | Shows Wikipedia in lookup options. |
| Highlight / Lookup > Show X-Ray | Shows X-Ray in lookup and highlight menus when the plugin is installed. |
| Highlight / Lookup > Show KOAssistant | Shows KOAssistant in lookup and highlight menus when the plugin is installed. |
| Highlight / Lookup > Show AI assistant | Shows an Assistant plugin button in lookup and highlight menus when the plugin is installed. |
| Highlight / Lookup > Show other items | Shows non-Zen KOReader quick lookup options alongside Zen buttons. |
| Reader > Time until chapter end | Selects `5 min left in chapter`, `5 min left`, abbreviated `5m`/`1h 5m`, or KOReader's default `hh:mm` format for compatible footer layouts. |
| Reader > Enable bottom swipe | Enables bottom-swipe reader menu behavior. This is forced on while page browser is enabled. |
| Reader > Enable page browser | Enables ZenOS page browser. It requires bottom swipe and supports stable page labels when the current book provides a page map. |
| Reader > Restore library location on exit | Returns to the previous library location after leaving the reader. |
| Bottom status bar > Enable bottom status bar | Shows or hides KOReader's bottom reader status bar. |
| Bottom status bar > Zen Presets > Built-in presets | Applies a prebuilt bottom status bar layout. |
| Bottom status bar > Zen Presets > Save current settings as preset | Saves the current bottom status bar setup as a user preset. |
| Bottom status bar > Zen Presets > User presets | Applies or deletes saved bottom status bar presets. |
| Bottom status bar > Left items | Selects and arranges bottom-bar items for the left slot, independent of the top bar. |
| Bottom status bar > Center items | Selects and arranges bottom-bar items for the center slot. |
| Bottom status bar > Right items | Selects and arranges bottom-bar items for the right slot. |
| Bottom status bar > Font | Sets footer font face, size, and bold style. |
| Bottom status bar > Hide in CBZ/PDF files | Hides the footer for CBZ and PDF documents. |
| Bottom status bar > KOReader status bar options | Exposes KOReader's built-in footer/status bar settings. |

## Dictionary lookup menu

![Dictionary lookup menu](/images/zen_os/reader_dict.webp)

Tap and hold a word while reading to open the Zen quick lookup menu. It shows the dictionary definition for the selected word along with ZenOS action buttons. Enable it with **Zen Settings > Reader > Highlight / Lookup > Zen quick lookup**. Wikipedia and installed X-Ray, KOAssistant, and AI Assistant integrations can appear as dedicated buttons; use **Show other items** to retain KOReader's remaining lookup options.

## Highlight menu

![Highlight menu](/images/zen_os/reader_highlight.webp)

Tap + hold and drag to highlight a selection of text and open the Zen highlight menu. It collects highlight, lookup, and annotation actions for the selected text in a single Zen-styled menu. Enable it with **Zen Settings > Reader > Highlight / Lookup > Zen highlight menu**.

## Stable Page Labels

ZenOS uses KOReader page-map labels when a book provides them. The reader page browser shows stable labels on page tiles and during page scrubbing, and the Zen table of contents shows the same labels beside chapter entries. It also handles non-linear book content without breaking page navigation. The page browser's Info button opens Book details, and Home featured widgets use the same page data for current/total progress.

## Status bars

The reader has two independent status bars: a top bar and a bottom bar. Each bar has three slots — left, center, and right — that you customize separately. Drop items like time, battery, Incognito, Wi-Fi, brightness, RAM usage, disk space, custom text, book title, author, chapter, progress percentage, or current/total pages into any slot and arrange their order. The top and bottom bars are configured independently, so you can show different items in each.

## Time until chapter end

Open **Zen Settings > Reader > Time until chapter end** to choose how the current chapter estimate appears: `5 min left in chapter`, `5 min left`, abbreviated `5m`/`1h 5m`, or KOReader's default `hh:mm` format. The abbreviated hour and minute units are localized.
