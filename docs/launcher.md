---
title: Launcher
category: Interface
summary: Customizable app launcher with action buttons, plugin buttons, and folders.
settingsPath: Zen Settings > Interface > Launcher
order: 47
---

<!-- Documentation current through ZenOS v4.3.0. -->

![Launcher](/images/zen_os/launcher.webp)

![Book switcher in Reader Launcher](/images/zen_os/reader_launcher_book_switcher.webp)

![Book details in Reader Launcher](/images/zen_os/reader_launcher_book_details.webp)

Launcher is a tab in the top menu with pages for your current book, recent books, and your own shortcut buttons.

## Pages

- **Book details**: progress, time left, and today's reading for the current book (reader only).
- **Book switcher**: recent books, so you can hop between them fast.
- **Buttons**: your shortcuts.

Reorder the pages under **Order**. Turn on **Open menu to Launcher** to make it the first tab you see.

**Where:** Zen Settings > Interface > Launcher

## Buttons

Use **Add** to create:

- **Control**: runs a button from Controls.
- **Action**: runs any dispatcher action.
- **Plugin Menu**: opens a menu from an installed plugin.
- **KOReader menu**: opens a native menu like Network or Tools.
- **Open folder** / **Specific tag**: jumps to a folder or tag.
- **Folder**: groups buttons together.
- **Row break**: starts a new row, with an optional title.

Each button has its own label and icon. Hold one to move it into or out of a folder.

Plugins installed with ZenPM get a button added automatically, and it's removed when you uninstall.

**Where:** Zen Settings > Interface > Launcher > Buttons

## Other settings

- **Show labels** under buttons (on by default).
- **Hide reader actions in library** hides reader-only buttons while browsing.
- **Show Launcher in Controls** (under Controls) moves Launcher into the Controls panel.
