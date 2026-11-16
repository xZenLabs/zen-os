---
title: FAQ
category: FAQ
summary: Answers to common questions about ZenOS.
settingsPath: ''
order: 6
---

<!-- Documentation current through ZenOS v4.3.0. -->

## How do I install ZenOS?

See [Installation](/zen-os/docs/installation).

## ZenOS isn't starting or showing in the plugins list

Most likely a nested folder. Inside `zenos.koplugin` you should see `main.lua` right away, not another `zenos.koplugin` folder. Make sure you grabbed the zip from [Releases](https://github.com/xZenLabs/zen-os/releases).

![zenos.koplugin folder inside the KOReader plugins directory](/images/zen_os/plugins_folder.webp)

## How do I get to the reader menu?

Swipe up in a book, then tap **Aa**.

![Page browser menu](/images/zen_os/page_browser_menu.webp)

## No books found

Point your home folder at where your books are (a dedicated `/books` folder works best): **Zen Settings > Library > Folders > Home folder > Set home folder**.

Books need to be DRM-free, like EPUB or PDF. Kindle formats (KFX, AZW3) and Send to Kindle books won't open directly. On Kindle, install [kindle.koplugin](https://github.com/kaikozlov/kindle.koplugin) to get at those.

## How do I open my Kindle library?

Install [kindle.koplugin](https://github.com/kaikozlov/kindle.koplugin) and restart. **Kindle Library** then shows up as a Navbar tab and a Home Book strip source. The first open of each book takes a moment while it's prepared.

## Calibre put all my books in author folders

Turn on **Zen Settings > Library > Books > Show all files from subfolders**.

## How do I browse the whole filesystem?

Set **Zen Settings > Library > Folders > Home folder > Lock home folder** to **Off**.

## Which plugins and patches conflict with ZenOS?

Most patches not made for ZenOS will cause trouble, so remove them. These plugins also conflict:

| Plugin | What to do |
| --- | --- |
| Project: Title | Remove |
| QuickMenu | Remove |
| Simple UI | Disable |
| Visual Overhaul Suite (VOS) | Disable |
| Appearance | Disable |
| Burrow | Disable |
| QuickUI | Disable |
| Reader Menu Redesign | Disable |
| Shortcuts Toolbar | Disable |
| Neo QuickSettings | Disable |

ZenOS disables most of these for you on first launch and asks to restart.
