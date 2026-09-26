---
title: FAQ
category: FAQ
summary: Answers to common questions about ZenOS.
settingsPath: ''
order: 6
---

<!-- Documentation current through ZenOS v3.3.0. -->

## How do I install ZenOS?

See the [Installation](/zen-os/docs/installation) guide for full installation instructions.

## ZenOS is not starting and doesn't show in the Plugins list

Make sure you downloaded the [release](https://github.com/xZenLabs/zen-os/releases) and did not leave a second folder inside `zenos.koplugin`. The installed `zenos.koplugin` folder must contain `main.lua` and the other ZenOS code files directly, not another nested `zenos.koplugin` folder.

![zenos.koplugin folder inside the KOReader plugins directory](/images/zen_os/plugins_folder.webp)

## How do I access the reader menu?

Swipe up while in a book, then tap the **Aa** icon.

![Page browser menu](/images/zen_os/page_browser_menu.webp)

## No books found

Set the Home folder to the location where your books are, preferably a dedicated folder such as `/books`, under **Zen Settings > Library > Home folder > Set home folder**. Sideloaded books must use an open, DRM-free format such as EPUB or PDF. ZenOS cannot natively open books delivered through Amazon Send to Kindle or Kindle formats such as KFX and AZW3. On Kindle devices, you can install [kindle.koplugin](https://github.com/kaikozlov/kindle.koplugin) to access books books from the native Kindle library.

## How do I open my native Kindle library?

Install [kindle.koplugin](https://github.com/kaikozlov/kindle.koplugin) on a Kindle device and restart KOReader. **Kindle Library** then becomes available as a Navbar tab and Home Book strip source. The plugin prepares a book on its first open and caches it for later use.

## Calibre loads all my books into folders of the authors, how can I fix that?

Enable the setting **Zen Settings > Library > Layout > Show all files from subfolders**.

## Which plugins and patches are incompatible with ZenOS?

Most patches not made specifically for ZenOS should not be used. Remove or disable them to avoid any conflicts.

Disable each item before using ZenOS unless its action is **Remove**; those plugins must be deleted from KOReader's plugins folder.

| Plugin | Action |
| --- | --- |
| Project: Title | Remove |
| Simple UI | Disable |
| Visual Overhaul Suite (VOS) | Disable |
| QuickMenu | Remove |
| Appearance | Disable |
| Burrow | Disable |
| QuickUI | Disable |
| Reader Menu Redesign | Disable |
| Shortcuts Toolbar | Disable |
| Page Scrubber | Disable |
| Neo QuickSettings | Disable |

## How do I navigate the entire filesystem?
Set **Zen Settings > Library > Home folder > Lock home folder** to **Off**.
