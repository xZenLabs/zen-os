---
title: Custom Icon Packs
category: Interface
summary: Install or create icon packs for ZenOS and its KOReader menu surfaces
settingsPath: Zen Settings > Interface > Custom icons > Custom icon pack
order: 65
---

## Install an icon pack

Custom packs belong in the `/koreader/icons/zen` folder inside KOReader's data directory.
ZenOS creates this folder automatically and scans only its immediate children.
A typical installation is:

```text
/koreader/icons/zen/
├── my-pack.zip
└── another-pack/
    ├── pack.json
    ├── appbar.navigation.svg
    ├── chevron.left.svg
    └── quick_wifi.svg
```

Copy either a pack folder or ZIP into `/koreader/icons/zen`, then restart
KOReader or open **Zen Settings > Interface > Custom icons > Custom icon pack**. ZenOS validates and
unpacks ZIP files automatically. A successfully installed ZIP is deleted.

If the same pack is already installed, a valid ZIP replaces it atomically. The
existing folder is restored if validation or extraction fails. Invalid ZIPs are
kept so they can be inspected or replaced. Installation errors are shown in the
pack submenu and written to the KOReader log.

Turn on the **Custom icons** switch under **Zen Settings > Interface**, choose the unpacked pack, and restart KOReader.
Packs are never selected automatically, so the bundled ZenOS and KOReader
icons remain the default.

**Invert with dark mode** is enabled by default under **Custom icons**.
Turn it off to keep custom icon colors in night mode. This applies immediately
to loose icons and the selected pack; bundled fallback icons follow night mode.
Black or very dark custom icons still invert to stay visible on dark backgrounds.
Selecting or enabling a pack with `"color": true` in `pack.json`, or "color" or
"colour" in its display name (regardless of capitalization), automatically
turns this setting off.

When custom icons are disabled, icon resolution is unchanged. When enabled,
the selected pack is checked first; a missing pack icon falls through to the
same bundled ZenOS and KOReader icons used without a pack. Installing or
selecting a pack does not modify those fallback files.

## Create a pack

Download `zen-icon-pack.zip` from [xZenLabs/zen-icon-pack](https://github.com/xZenLabs/zen-icon-pack), then extract it. It contains the replaceable icons for ZenOS's Navbar,
KOReader's top menu tabs, the bottom reader configuration-bar tabs,
highlight/dictionary/lookup actions, chevrons, dialogs, bookmarks,
and shared reader controls. The current sample contains 189 icons, including
highlight styling, annotation sorting, and reference controls. Packs may include
additional icon filenames listed below.

1. Rename the `zen-icon-pack` folder to a safe ID such as `my-pack`.
2. Set the same `id` and your display `name` in `pack.json`.
3. Replace any canonical icon files while keeping their filenames unchanged.
4. Keep the whole folder for a complete pack, or remove unchanged icons to
   make a partial pack.
5. ZIP the top-level pack folder, not only its contents.

ZIPs may contain only regular files and directories beneath that one top-level
folder. ZenOS rejects unsafe paths, links and special entries, archives larger
than 25 MiB, more than 512 entries, files larger than 5 MiB, or more than 50 MiB
of expanded data.

An example `pack.json` is:

```json
{
  "schema_version": 1,
  "id": "my-pack",
  "name": "My Pack",
  "color": true
}
```

`color` is an optional boolean; set it to `true` for a color pack.
`version` and `author` are optional strings. Pack IDs and icon names may use
letters, numbers, dots, dashes, and underscores. IDs must start with a letter
or number, and the folder name must exactly match the ID.

Icons must be `.svg` or `.png` files at the pack root. SVG is preferred when
both formats exist. Use a transparent background and artwork that remains
legible in black and white on e-ink screens. Every safely named root icon is
loaded: it can replace a matching ZenOS or KOReader icon, or be selected for
a Navbar or Launcher icon. Use `large_chevron_up.svg` to replace the large
up chevron in the top-menu footer.

Highlight menus use `font.svg` (Style), `paint_palette.svg` (Color), `edit.svg`
(Note), `trash.svg` (Delete), and `more_vertical.svg`. The settings gear in the More
menu uses `appbar.settings.svg`. These names also work as loose icon overrides
under `/koreader/icons` when no pack is selected.

Reader references use `pin.svg`, `pin_remove.svg`, and `return.svg`. Annotation
lists use `filter.svg` and `sort.svg`; their item menus use `settings_note_plus_outline.svg` (Add note)
and `annotations.svg` (Edit note).
Page-preview bookmark actions use `bookmark.svg` and `bookmark_remove.svg`.
Page browser and reader controls use `annotations.svg` (Annotations), `font.svg` (Font), or `appbar.contrast.svg` (Contrast).
Both use `bookmark_outline.svg` for Bookmarks and `view_carousel_outline.svg` for Book switcher.
Reader controls uses `moon_outline.svg` for Themes.

Zen Settings rows use `settings_*.svg` names (for example `settings_cog.svg`,
`settings_magnify.svg`, `settings_folder_outline.svg`), plus `info.svg`, `grid.svg`,
`more_vertical.svg`, `pin.svg`, and `view_carousel_outline.svg`. The full list is the
`icons/settings_*.svg` set bundled with ZenOS; any name a pack omits keeps the bundled icon.
Library and OPDS context menus share these names, for example `settings_content_copy.svg` (Copy),
`settings_book_open_variant.svg` (Read now), `settings_download.svg` (Download), and
`settings_sync.svg` (Sync). They also use `bookmark_outline.svg` (Read status), `filter.svg`
(Filter), `font.svg` (Title sort), `view_carousel_outline.svg` (Page stream), and
`skip_right.svg` (Stream from page).
Page browser search buttons share `quick_search.svg` with Settings; close buttons use KOReader's `close.svg`.

Quick Settings and its menus use `airplane.svg`, `app_menu.svg`,
`brightness.svg`, `network.svg`, `quick_battery.svg`, and `warmth.svg`.
Statistics use `book_open.svg`, `calendar.svg`, and `flame.svg`.
Lookup actions use `lookup_ai.svg` and `lookup_extend.svg`. The update badge
and its quickstart illustration use `zen_ui_update.svg`.

The sample ZIP also includes `ICON-LIST.md`, a human-readable catalog of every
included icon, its exact replacement filename, and the Navbar, top-menu,
bottom-menu, lookup, or shared control it changes.

## Fallbacks and recovery

A pack may be incomplete. For each missing icon, ZenOS falls back to its
bundled icon and then KOReader's normal icon. With no pack selected, the
existing loose files directly under `/koreader/icons` continue to work.

If a pack is removed while selected, ZenOS starts with fallback icons and
shows the selection as unavailable. Choose another pack or **Loose icons**, or
turn off the **Custom icons** switch in **Interface**, then restart. A failed ZIP installation never
removes the previously installed version.

ZenOS normally recovers its own hidden `.zen-stage-<id>` and
`.zen-backup-<id>` transaction folders on the next scan. For manual recovery,
close KOReader and make a backup of `/koreader/icons/zen` first. Remove or
replace the retained invalid ZIP. If an installed `<id>` folder is missing but
`.zen-backup-<id>` remains, rename the backup to `<id>`; stale `.zen-stage-*`
folders can then be removed. Never move pack files outside `icons/zen` as part
of recovery.
