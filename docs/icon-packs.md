---
title: Custom Icon Packs
category: Interface
summary: Install or create icon packs for ZenOS and its KOReader menu surfaces
settingsPath: Zen Settings > Interface > Custom icons > Custom icon pack
order: 65
---

<!-- Documentation current through ZenOS v4.3.0. -->

Swap out ZenOS and KOReader icons with your own. Any icon a pack doesn't include falls back to the normal one, so partial packs are fine.

## Install a pack

1. Copy the pack's folder or `.zip` into `/koreader/icons/zen/` (ZenOS creates it for you).
2. Turn on **Zen Settings > Interface > Custom icons** and pick the pack under **Custom icon pack**.
3. Restart KOReader.

```text
/koreader/icons/zen/
├── my-pack.zip
└── another-pack/
    ├── pack.json
    ├── appbar.navigation.svg
    └── quick_wifi.svg
```

Zips get checked and unpacked automatically, then deleted. If something's wrong, the zip is kept and the error shows in the pack menu. A bad zip never removes the version you already had.

**Invert with dark mode** is on by default. Turn it off to keep your icon colors in night mode. Color packs turn it off automatically.

## Make a pack

Grab `zen-icon-pack.zip` from [xZenLabs/zen-icon-pack](https://github.com/xZenLabs/zen-icon-pack). It has every replaceable icon plus `ICON-LIST.md`, which says what each file changes.

1. Rename the folder to your pack ID, like `my-pack`.
2. Set the same `id` and your `name` in `pack.json`.
3. Replace the icons you want. Keep the filenames. Delete the ones you didn't change if you like.
4. Zip the whole folder (not just what's inside).

```json
{
  "schema_version": 1,
  "id": "my-pack",
  "name": "My Pack",
  "color": true
}
```

`color`, `version`, and `author` are optional. Set `color: true` for color packs.

### Rules

- Icons are `.svg` or `.png` at the pack root. SVG wins if both exist.
- IDs and filenames: letters, numbers, `.`, `-`, `_`. Must start with a letter or number. Folder name must match the ID.
- Use transparent backgrounds and keep things readable in black and white.
- Zip limits: 25 MiB zip, 512 entries, 5 MiB per file, 50 MiB unpacked. No links or weird paths.

Any extra icon you include can also be picked as a Navbar or Launcher icon.

## Icon names worth knowing

`ICON-LIST.md` has the full list. A few common ones:

- **Settings rows**: `settings_*.svg` (e.g. `settings_cog.svg`, `settings_folder_outline.svg`)
- **Highlight menu**: `font.svg`, `paint_palette.svg`, `edit.svg`, `trash.svg`, `more_vertical.svg`
- **Pins and return**: `pin.svg`, `pin_remove.svg`, `return.svg`
- **Bookmarks**: `bookmark.svg`, `bookmark_remove.svg`, `bookmark_outline.svg`
- **Controls**: `airplane.svg`, `brightness.svg`, `warmth.svg`, `network.svg`, `quick_battery.svg`
- **Stats**: `book_open.svg`, `calendar.svg`, `flame.svg`
- **Update badge**: `zen_ui_update.svg`

## Recovery

If a selected pack goes missing, ZenOS just uses the default icons. Pick another pack or turn off **Custom icons**.

If an install gets interrupted, ZenOS cleans up its `.zen-stage-<id>` and `.zen-backup-<id>` folders on the next scan. To fix it by hand: close KOReader, back up `/koreader/icons/zen`, and rename `.zen-backup-<id>` back to `<id>` if the pack folder is missing.
