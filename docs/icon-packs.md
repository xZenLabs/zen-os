---
title: Custom Icon Packs
category: Extras
summary: Install or create icon packs for ZenOS and its KOReader menu surfaces
settingsPath: Zen Settings > Extras > Custom icon pack
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
KOReader or open **Zen Settings > Extras > Custom icon pack**. ZenOS validates and
unpacks ZIP files automatically. A successfully installed ZIP is deleted.

If the same pack is already installed, a valid ZIP replaces it atomically. The
existing folder is restored if validation or extraction fails. Invalid ZIPs are
kept so they can be inspected or replaced. Installation errors are shown in the
pack submenu and written to the KOReader log.

Turn on **Enable custom icons**, choose the unpacked pack, and restart KOReader.
Packs are never selected automatically, so the bundled ZenOS and KOReader
icons remain the default.

When custom icons are disabled, icon resolution is unchanged. When enabled,
the selected pack is checked first; a missing pack icon falls through to the
same bundled ZenOS and KOReader icons used without a pack. Installing or
selecting a pack does not modify those fallback files.

## Create a pack

Download `zen-icon-pack.zip` from [xZenLabs/zen-icon-pack](https://github.com/xZenLabs/zen-icon-pack), then extract it. It contains the replaceable icons for ZenOS's Navbar,
KOReader's top menu tabs, the bottom reader configuration-bar tabs,
highlight/dictionary/lookup actions, chevrons, dialogs, bookmarks,
and shared reader controls. The current sample contains 62 icons from the
2026.07 baseline; unrelated settings, network, and utility artwork is
intentionally omitted.

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
  "name": "My Pack"
}
```

`version` and `author` are optional strings. Pack IDs and icon names may use
letters, numbers, dots, dashes, and underscores. IDs must start with a letter
or number, and the folder name must exactly match the ID.

Icons must be `.svg` or `.png` files at the pack root. SVG is preferred when
both formats exist. Use a transparent background and artwork that remains
legible in black and white on e-ink screens. Every safely named root icon is
loaded: it can replace a matching ZenOS or KOReader icon, or be selected for
a Navbar or Launcher icon. Use `large_chevron_up.svg` to replace the large
up chevron in the top-menu footer.

The sample ZIP also includes `ICON-LIST.md`, a human-readable catalog of every
included icon, its exact replacement filename, and the Navbar, top-menu,
bottom-menu, lookup, or shared control it changes.

## Fallbacks and recovery

A pack may be incomplete. For each missing icon, ZenOS falls back to its
bundled icon and then KOReader's normal icon. With no pack selected, the
existing loose files directly under `/koreader/icons` continue to work.

If a pack is removed while selected, ZenOS starts with fallback icons and
shows the selection as unavailable. Choose another pack or **Loose icons**, or
turn off **Enable custom icons**, then restart. A failed ZIP installation never
removes the previously installed version.

ZenOS normally recovers its own hidden `.zen-stage-<id>` and
`.zen-backup-<id>` transaction folders on the next scan. For manual recovery,
close KOReader and make a backup of `/koreader/icons/zen` first. Remove or
replace the retained invalid ZIP. If an installed `<id>` folder is missing but
`.zen-backup-<id>` remains, rename the backup to `<id>`; stale `.zen-stage-*`
folders can then be removed. Never move pack files outside `icons/zen` as part
of recovery.
