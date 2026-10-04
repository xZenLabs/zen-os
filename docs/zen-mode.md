---
title: Zen Mode
category: Interface
summary: Simplify KOReader
settingsPath: Zen Settings > Interface > Controls > Buttons > Zen mode
order: 49
---

<!-- Documentation current through ZenOS v3.0.0. -->

![Controls](/images/zen_os/quicksettings.webp)

![Zen Mode](/images/zen_os/zen_mode.webp)

## Introduction

Zen Mode simplifies KOReader. When you first start ZenOS, you will be in Zen Mode. This cleans up the top menu bar and replaces it with four focused items: [Controls](/zen-os/docs/controls), Zen Settings (unified ZenOS and KOReader settings), [Launcher](/zen-os/docs/launcher), and the Home button.

By default, the Home folder lock applies only in Zen Mode, so you cannot accidentally go back out of your library into the device filesystem. To change this, choose **Zen Settings > Library > Home folder > Lock home folder** and select Off, Only in Zen Mode, or Always.

Exiting Zen Mode with the toggle in Controls (icon below) will re-enable the top KOReader menu bar icons like Settings, Tools, etc.

![Zen Mode](/images/zen_os/zen_mode.webp)

## Options

- Toggle Zen Mode from the Controls/Launcher Zen button or the `ZenOS: Toggle Zen Mode` dispatcher action.

## Setting reference

| Setting | Description |
| --- | --- |
| Controls > Zen mode button | Toggles Zen Mode from the Controls panel. |
| Dispatcher > ZenOS: Toggle Zen Mode | Provides the same toggle as a dispatcher action for gestures, custom buttons, launcher buttons, or navbar tabs. |
| Behavior > Filtered menu tabs | Hides most default KOReader menu tabs and keeps Controls available. |
| Behavior > Live menu update | Settings, Controls, and dispatcher toggles update the top menu immediately without restarting KOReader. |
| Lockdown Mode > Zen Mode dependency | Lockdown Mode turns Zen Mode on and prevents turning it off while Lockdown Mode remains active. |
