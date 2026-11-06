---
title: Navbar
category: Interface
summary: The customizable bottom navigation bar
settingsPath: Zen Settings > Interface > Navbar
order: 48
---

<!-- Documentation current through ZenOS v4.3.0. -->

![Navbar](/images/zen_os/navbar.webp)

The bar at the bottom of the Library. Up to seven tabs.

## Tabs

Built-in tabs include Library, Folder, Home, Continue, History, Favorites, Collections, Authors, Series, Languages, Tags, To Be Read, Search, Stats, Manga, News, Previous/Next page, and Menu.

Use **Add** for more:

- **Tab**: any unused built-in, or a status tab (Unread, Reading, On hold, Finished).
- **Folder** / **Specific tag**: as many as you want, each with its own label and icon.
- **Control**, **Action**, **Plugin Menu**, **KOReader menu**: run or open anything.

**Default tab** sets where ZenOS opens at startup and what the physical Home button does.

**Where:** Zen Settings > Interface > Navbar > Tabs

## Grouped views

**Authors**, **Series**, **Languages**, and **All tags** group your books by metadata instead of folders. Hold on the tab to change its display and sort. Each one remembers its own settings.

## Manga and News

Each can open a plugin or a folder:

- **Manga**: [Rakuyomi](https://github.com/tachibana-shin/rakuyomi), another manga reader, or a folder.
- **News**: QuickRSS, KOReader's RSS Reader, or a folder.

Folder mode works even if you don't use the plugin.

**Where:** Zen Settings > Interface > Navbar > Tabs > Manga / News

## Kindle Library

On Kindle with [kindle.koplugin](https://github.com/kaikozlov/kindle.koplugin) installed, the **Kindle Library** tab opens your native Kindle books with ZenOS covers, display modes, and menus. You can hide the plugin's extra folder if the tab is enough.

## Styling

- Show or hide labels and icons, and set their size.
- **Show top border** above the navbar.
- **Active tab**: Underline, Filled, or Outlined. Uses your accent color by default, or set custom colors and fill opacity.

**Where:** Zen Settings > Interface > Navbar > Styling
