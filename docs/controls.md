---
title: Controls
category: Interface
summary: All your controls in one place
settingsPath: Zen Settings > Interface > Controls
order: 46
---

<!-- Documentation current through ZenOS v3.3.0. -->

![Controls panel](/images/zen_os/quicksettings.webp)

## Overview

Controls adds a fast control panel to KOReader. It allows you to toggle Wi-Fi, frontlight, rotation, ZenOS modes, brightness, and warmth controls with a single swipe. You can also add action, plugin-menu, and KOReader-menu buttons for quick access.

## Options

- Choose and arrange up to 9 visible buttons.
- Show or hide button labels.
- Configure the rotate button to cycle rotation or apply a fixed 90, 180, or 270 rotation.
- Add action buttons backed by dispatcher actions.
- Add plugin buttons from launchable plugin menus found on the device.
- Add KOReader menu buttons for native submenus available in the current library or reader context.
- Get an automatically suggested icon when creating an action, plugin, or KOReader menu button.
- Use the screenshot button with a configurable countdown timer.
- Show brightness and warmth sliders, or combine them when the device supports both controls.
- Hold a slider's minus button to turn the frontlight off or set warmth to zero.
- Set an optional timeout that automatically turns Incognito Mode off.
- Optionally turn Wi-Fi on and off with the Tailscale control.
- Flip the left-hand/right-hand icon used by Controls and the Library/Home menu tab.
- Show or hide the Zen Settings button in Controls.
- Reset Controls to defaults without deleting saved custom buttons.

## Setting reference

| Setting | Description |
| --- | --- |
| Buttons | Opens the button arranger. Disabled buttons are dimmed when the 9-button limit is reached. |
| Buttons > Built-in buttons | Includes Wi-Fi, Bluetooth, night mode, frontlight, autorotate, rotate, Zen Mode, Lockdown, Incognito, USB, file search, restart, exit, sleep, screenshot, sync, cloud, OPDS, Calibre, Calibre Search, Z-Library, LocalSend, Tailscale, ZenFM, Filebrowser, QuickRSS, Notion, reading streak, statistics progress, statistics calendar, battery stats, and supported game plugins when detected. |
| Buttons > Autorotate | Changes the Autorotate button label and icon. An empty label restores the default. |
| Buttons > Rotate action | Sets the rotate button to cycle rotation or apply 90, 180, or 270 rotation directly. |
| Buttons > Add > Folder | Adds an independently configured folder destination button. |
| Buttons > Add > Specific tag | Adds a button that opens one selected tag. |
| Buttons > Add > Action | Creates a user-defined Controls button that runs a dispatcher action, with a suggested icon. New buttons are added to the order list and shown when there is room under the 9-button limit. |
| Buttons > Add > Plugin Menu | Scans for launchable plugin menus and adds the selected plugin menu as a Controls button with a suggested icon. |
| Buttons > Add > KOReader menu | Adds a native KOReader submenu, such as Network, Tools, or Style tweaks, with a suggested icon. Reader-only menus remain visible but dimmed in the library. |
| Action button > Action | Selects the dispatcher action run by the button. |
| Action button > Icon | Selects a bundled, KOReader, or user icon. |
| Action button > Label | Sets a custom label or leaves it empty to use the action title. |
| Plugin button > Plugin | Selects the launchable plugin menu run by the button. |
| Plugin button > Icon | Selects a bundled, KOReader, or user icon. |
| Plugin button > Label | Sets the plugin button label. |
| KOReader menu button > KOReader menu | Selects the native submenu opened by the button. |
| KOReader menu button > Icon | Selects a bundled, KOReader, or user icon. |
| KOReader menu button > Label | Sets the button label. |
| Custom button > Show | Shows or hides the button in Controls. |
| Custom button > Delete | Deletes the button and removes it from the order list. |
| Buttons > Screenshot > Timer | Sets the screenshot countdown from 0 to 10 seconds. You can also hold the Screenshot button to change it. |
| Buttons > Incognito > Timeout | Turns Incognito Mode off automatically after the selected number of minutes. Off keeps it active until you toggle it yourself. |
| Buttons > Tailscale > Toggle Wi-Fi with Tailscale | Turns Wi-Fi on before starting Tailscale and off after stopping it. Available when the Tailscale plugin is installed. |
| Show labels | Shows or hides labels beneath Controls buttons. |
| Show brightness slider | Shows the frontlight brightness slider in Controls. |
| Show warmth slider | Shows the warmth slider on devices with natural light support. |
| Unified brightness/warmth slider | Combines brightness and warmth into one slider on devices with both controls. |
| Flip LH/RH icon | Flips the Controls and Library/Home icons. |
| Show Zen Settings in Controls | Shows or hides the Zen Settings button in Controls. |
| Reset to defaults | Restores Controls defaults. Action, plugin, and KOReader menu buttons are disabled and kept in your saved configuration. |
