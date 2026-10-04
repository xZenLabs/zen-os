---
title: Navbar
category: Interface
summary: The customizable bottom navigation bar
settingsPath: Zen Settings > Interface > Navbar
order: 48
---

<!-- Documentation current through ZenOS v3.3.0. -->

![Navbar](/images/zen_os/navbar.webp)

## Overview

The Navbar adds a bottom navigation bar to the library. Tabs can open library views, folders, plugin integrations, page controls, menu actions, custom dispatcher actions, launchable plugin menus, or native KOReader submenus.

Navbar settings live under **Zen Settings > Interface > Navbar**.

## Options

- Show and arrange up to 7 visible tabs.
- Hide or show icons.
- Add tabs for Unread, Reading, On hold, and Finished books.
- Add custom tabs with dispatcher actions, controls, plugin menus, native KOReader submenus, icons, and labels.
- Select the destination used at startup and by the physical Home button.
- Configure Library, Folder, Home, Manga, and News tab labels or actions.
- Control active-tab styling, top border, label size, and icon size.

Under **Styling > Active tab**, choose **Underline** or **Filled** using the radio control. Filled appears directly below Underline. Open **Underline** to move the line above the icon. Open **Filled** to pick **Outline color** for the icon and **Fill color** for the squircle behind it; the defaults are a white icon on a muted blue (#4F6F8F) squircle. With icons hidden, the active label uses the fill color. **Active tab outline color** is available when **Colored** and **Underline** are selected.

The **Fill color** picker also has an **Opacity** slider from 0% (transparent) to 100% (opaque), with a default of 60%. Opacity affects the squircle background; icons and labels stay opaque. Color and opacity changes repaint the navbar when settings close.

## Manga And News Tabs

The Manga and News tabs are flexible launchers. Each one can open a dedicated plugin or jump straight to a folder of your choice.

- **Manga tab** opens [Rakuyomi](https://github.com/tachibana-shin/rakuyomi), another manga reader, or a folder. Set the destination with **Manga tab action**, and use **Manga folder presets** to pin it to the home folder, the last folder, or the current folder.
- **News tab** opens QuickRSS, KOReader's built-in RSS Reader, or a folder. Set the destination with **News tab action**, and use **News folder presets** for the same home, last, or current folder shortcuts.

Folder mode makes either tab a one-tap shortcut to wherever you keep that content, even if you do not use the associated plugin.

## Folder And Tag Tabs

The built-in **Folder** tab opens a folder you choose. Its presets can point to the home folder, the last folder, or the current folder, and Folder can be selected as the default tab. Its label and icon can be changed without removing or re-adding the folder. Add as many separate **Folder** tabs as you need, each with its own path, label, and icon. Use **Specific tag** for a direct shortcut to one tag or **All tags** for the grouped tag browser. Each specific-tag tab can also have its own label and icon.

## Kindle Library And Status Tabs

On Kindle devices with [kindle.koplugin](https://github.com/kaikozlov/kindle.koplugin) installed, the **Kindle Library** tab opens the device's native Kindle library with ZenOS covers, metadata, status bar, display modes, and book context menus. Its settings can hide the plugin's synthetic Kindle Library folder when the Navbar tab is enough.

Unread, Reading, To Be Read, On hold, and Finished can each be used as a direct library tab. **To Be Read** is a built-in tab; add the other status tabs from the tab picker.

## Grouped Views

The Authors, Series, Languages, and All tags tabs group your library by metadata instead of by folder. Each grouped view keeps its own display mode, sort field, and sort direction.

- **Authors** groups books by author. It sorts by `First name` or `Last name`, with a separate ascending or descending order.
- **Series** groups books by series, ordered by series position inside each group. Series names sort by title (ignoring leading articles) or natural title, with an independent direction.
- **Languages** groups books by their localized language name, using the same title modes and direction.
- **All tags** groups books by tag/keyword. Tag names use the same title modes and direction; book sorting remains configurable separately.

Adjust a grouped view's display and sort from its context menu while that tab is open. Changes are saved per view.

## Setting reference

| Setting | Description |
| --- | --- |
| Tabs | Opens the tab arranger. At least 1 tab must remain visible and no more than 7 tabs can be visible. |
| Tabs > Built-in tabs | Includes Library, Folder, Kindle Library when available, Manga, News, Continue, History, Favorites, Collections, Authors, Series, Languages, Home, Single tag, All tags, To Be Read, Search, Calibre Search, Stats, Exit, Previous page, Next page, and Menu. |
| Tabs > Add > Tab | Adds an unused built-in destination or an Unread, Reading, On hold, or Finished status tab. |
| Tabs > Add > Control | Adds a Navbar tab that runs a selected Controls control. |
| Tabs > Add > Folder | Adds an independently configured folder tab. |
| Tabs > Add > Specific tag | Adds a tab that opens one selected tag. |
| Tabs > Add > Action | Adds a user-defined tab that runs a dispatcher action with a suggested icon. |
| Tabs > Add > Plugin Menu | Scans for launchable plugin menus and adds the selected plugin menu as a tab with a suggested icon. |
| Tabs > Add > KOReader menu | Adds a native submenu from the library-valid KOReader menu tree. |
| Custom tabs > Show in navbar | Shows or hides a custom tab. |
| Custom tabs > Action | Selects the dispatcher action run by an action tab. |
| Custom tabs > Plugin | Selects the launchable plugin menu run by a plugin tab. |
| Custom tabs > KOReader menu | Selects the native KOReader submenu opened by a menu tab. |
| Custom tabs > Icon | Selects a bundled, KOReader, or user icon, including for added folder and specific-tag tabs. |
| Custom tabs > Label | Sets a custom label; leaving it empty restores the folder name, tag name, action title, or plugin title. |
| Custom tabs > Delete | Deletes the custom tab and removes it from the order list. |
| Default tab | Selects the destination ZenOS opens at startup and when the device's physical Home button is pressed. |
| Tabs > Home > Label | Sets the Home tab label. |
| Tabs > Books > Label | Sets the Library tab label to Books, Home, Library, or custom text. |
| Tabs > Folder | Selects a folder destination, changes its label or icon, or uses the home, last, or current folder preset. |
| Tabs > Kindle Library > Hide Kindle Library folder | Hides kindle.koplugin's synthetic folder while keeping the Navbar and Book strip destinations available. |
| Tabs > Manga | Opens Rakuyomi, another manga reader, or a selected folder. |
| Tabs > Manga > Folder presets | Sets the Manga folder to the home folder, last folder, or current folder. |
| Tabs > News | Opens QuickRSS, RSS Reader, or a selected folder. |
| Tabs > News > Folder presets | Sets the News folder to the home folder, last folder, or current folder. |
| Styling > Show top border | Draws a line above the navbar. |
| Styling > Labels > Show labels | Shows tab labels. This cannot be disabled when icons are hidden. |
| Styling > Labels > Label size | Sets navbar label text size from 10 to 28. |
| Styling > Icons > Show icons | Shows tab icons. This cannot be disabled when labels are hidden. |
| Styling > Icons > Icon size | Sets navbar icon size from 24 to 48. |
| Styling > Active tab > Underline | Adds an underline to the active tab. |
| Styling > Active tab > Underline above icon | Places the active underline above the icon. |
| Styling > Active tab > Colored | Uses an accent color for the active tab. |
| Styling > Active tab > Active tab color | Sets the active tab color from presets or custom RGB values. |
