---
title: Zen Mode
category: Interface
summary: Simplify KOReader
settingsPath: Zen Settings > Interface > Zen mode
order: 49
---

<!-- Documentation current through ZenOS v4.3.0. -->

![Zen Mode](/images/zen_os/zen_mode.webp)

Zen Mode cleans up KOReader's top menu. Instead of a dozen tabs you get four: [Controls](/zen-os/docs/controls), Zen Settings, [Launcher](/zen-os/docs/launcher), and Home. It's on when you first install ZenOS.

It also locks the Library to your home folder by default, so you don't wander into the device filesystem by accident. Change that under **Zen Settings > Library > Folders > Home folder > Lock home folder**.

## Turning it off

Turn off **Zen Settings > Interface > Zen mode** to get KOReader's full menu back. No restart needed.

You can also toggle it from:

- A **Zen mode** button in Controls (hidden by default, add it under **Interface > Controls > Buttons**).
- The `ZenOS: Toggle Zen Mode` action on a gesture, Launcher button, or Navbar tab.

[Lockdown Mode](/zen-os/docs/lockdown-mode) keeps Zen Mode on while it's active.
