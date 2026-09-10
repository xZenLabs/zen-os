---
title: Launcher
category: Launcher
summary: Customizable app launcher with action buttons, plugin buttons, and folders.
settingsPath: Zen Settings > Launcher
order: 40
---

<!-- Documentation current through ZenOS v3.0.0. -->

![Launcher](/images/zen_os/launcher.webp)

![Book switcher in Reader Launcher](/images/zen_os/reader_launcher_book_switcher.webp)

![Book details in Reader Launcher](/images/zen_os/reader_launcher_book_details.webp)

![Full-screen book details](/images/zen_os/reader_book_details.webp)

## Overview

Launcher adds a configurable tab to the ZenOS menu. It can create shortcut buttons for Controls, dispatcher actions, detected launchable plugins, and native KOReader submenus. Place these buttons inside folders for more organization.

## Options

- Enable or disable the Launcher feature.
- Show optional Book details and Book switcher pages.
- Arrange Book details, Book switcher, and Buttons pages.
- Show launcher button labels. This is enabled by default.
- Hide reader action buttons when the launcher is shown from the library.
- Arrange launcher buttons.
- Add action buttons backed by dispatcher actions.
- Add buttons that run a chosen Controls control.
- Add plugin buttons from launchable plugin menus found on the device.
- Automatically add launchable plugin menus for new plugins installed by ZenPM and remove those buttons when ZenPM uninstalls their plugins. Existing and manually added buttons are left unchanged.
- Add context-aware KOReader submenu buttons, such as Network, Tools, or Style tweaks.
- Add folders and arrange buttons inside each folder.
- Insert a row break to start later buttons on a new row, with an optional centered title.
- Configure each button or folder label and icon.
- Move Control, action, plugin-menu, and KOReader-menu buttons into folders or back to the root launcher.

## Setting reference

| Setting | Description |
| --- | --- |
| Enable | Enables or disables the Launcher feature. |
| Buttons | Opens the launcher button arranger. |
| Book switcher | Shows recent books as a launcher page, optionally only while reading. |
| Book details | Shows information for the current book as a reader-only launcher page. |
| Book details > Items | Toggles and orders read time, time remaining, pages today, time today, pages, and the progress bar. Today totals include all books read since local midnight. |
| Order | Arranges the Book details, Book switcher, and Buttons pages. |
| Open menu to Launcher | Opens the top menu on the Launcher tab. |
| Show labels | Shows launcher button labels. Enabled by default; disabling it hides the labels. |
| Hide reader actions in library | When enabled, action buttons bound to reader-only dispatcher actions are hidden (and inactive) while the launcher is opened from the library. Disabled by default. |
| Buttons > Add > Open folder | Adds an independently configured folder destination button. This is separate from a Launcher folder used to group buttons. |
| Buttons > Add > Specific tag | Adds a button that opens one selected tag. |
| Buttons > Add > Control | Adds a launcher button that runs a selected Controls control. |
| Buttons > Add > Action | Adds a launcher button that runs a dispatcher action, with a suggested icon. |
| Buttons > Add > Plugin Menu | Scans for launchable plugin menus and adds the selected plugin menu as a launcher button with a suggested icon. |
| Buttons > Add > KOReader menu | Adds a native KOReader submenu available in the current library or reader context. |
| Buttons > Add > Row break | Inserts a row break in the Launcher button layout, with an optional centered title. |
| Control button > Control | Selects the Controls control run by the button. |
| Buttons > Add > Folder | Adds a launcher folder. |
| Action button > Action | Selects the dispatcher action run by the button. |
| Action button > Icon | Selects a bundled, KOReader, or user icon. |
| Action button > Label | Sets a custom label or leaves it empty to use the action title. |
| Plugin button > Plugin | Selects the launchable plugin menu run by the button. |
| Plugin button > Icon | Selects a bundled, KOReader, or user icon. |
| Plugin button > Label | Sets the plugin button label. |
| KOReader menu button > KOReader menu | Selects the native submenu opened by the button. |
| KOReader menu button > Icon | Selects a bundled, KOReader, or user icon. |
| KOReader menu button > Label | Sets the button label. |
| Folder > Label | Sets the folder label. |
| Folder > Icon | Sets the folder icon. |
| Folder > Folder buttons | Opens the arranger for buttons inside the folder. |
| Folder buttons > Add > Control | Adds a Controls control inside the folder. |
| Folder buttons > Add > Open folder | Adds a folder destination inside the launcher folder. |
| Folder buttons > Add > Specific tag | Adds a one-tag destination inside the launcher folder. |
| Folder buttons > Add > Action | Adds an action button inside the folder. |
| Folder buttons > Add > Plugin Menu | Adds a detected plugin menu button inside the folder. |
| Folder buttons > Add > KOReader menu | Adds a native KOReader submenu button inside the folder. |
| Folder buttons > Add > Row break | Starts later folder buttons on a new row. |
| Button movement > Move to folder | Moves a Control, action, plugin-menu, or KOReader-menu button into an existing launcher folder. |
| Button movement > Move out of folder | Moves a button from a folder back to the root launcher. |
| Button or folder > Delete | Deletes a button, or deletes a folder and its buttons after confirmation. |
