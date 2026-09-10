---
title: FAQ
category: FAQ
summary: Answers to common questions about ZenOS.
settingsPath: ''
order: 6
---

<!-- Documentation current through ZenOS v3.0.0. -->

## How do I install ZenOS?

See the [Installation](/zen-os/docs/installation) guide for full installation instructions.

## ZenOS is not starting and doesn't show in the Plugins list

Make sure you downloaded the [release](https://github.com/xZenLabs/zen-os/releases) and did not leave a second folder inside `zenos.koplugin`. The installed `zenos.koplugin` folder must contain `main.lua` and the other ZenOS code files directly, not another nested `zenos.koplugin` folder.

![zenos.koplugin folder inside the KOReader plugins directory](/images/zen_os/plugins_folder.webp)

## How do I access the reader menu?

Swipe up while in a book, then tap the **Aa** icon.

![Page browser menu](/images/zen_os/page_browser_menu.webp)

## No books found

Set the Home folder to the location where your books are, preferably a dedicated folder such as `/books`, under **Zen Settings > Library > Home folder > Set home folder**. Books must use a KOReader-supported, DRM-free format. KOReader can only read open format books and cannot read proprietary formats such `azw3`, `kfx`, `mobi` etc. You will need to convert your books to an open format to use KOReader

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

## How do I navigate the entire filesystem?
Set **Zen Settings > Library > Home folder > Lock home folder** to **Off**.
