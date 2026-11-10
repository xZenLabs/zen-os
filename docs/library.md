---
title: Library
category: Library
summary: All your books in one place
settingsPath: Zen Settings > Library
order: 30
---

<!-- Documentation current through ZenOS v4.3.0. -->

![Library cover view](/images/zen_os/library_covers_full.webp)

![Library list view](/images/zen_os/library_list_full.webp)

![Context menu](/images/zen_os/context_menu.webp)

![Metadata editor](/images/zen_os/metadata_editor.webp)

The Library is where your books live. Settings are split into **Appearance**, **Folders**, **Books**, and **Context menu**. Font, wallpaper, and status bar are global, so they live under [Interface](/zen-os/docs/interface).

## Display mode and sorting

Hold on empty space (or the Navbar) to open the menu for the folder you're in. From there change **Display** (Mosaic, List detailed, List basic), **Sort folder by**, and **Filter by status**. Each folder remembers its own choices.

## Layout

- **Mosaic** sets the grid for portrait (default 3×3) and landscape (default 4×2) with a live preview.
- **List** sets items per page (4–12) and which fields show in the detailed list.
- Toggle item underlines and list borders.

**Where:** Zen Settings > Library > Appearance > Layout

## Covers and badges

Badges for page count, series number, favorites, new books, and reading progress. Pick badge size and color (or follow the accent color). **Text size** sets the font inside the badges, and **Opening banner text size** sets the font of the strip shown while a book opens; both range from 6 to 24 and a size the box cannot hold is reduced to fit. You can also use uniform 2:3 or 3:4 covers, round the corners, dim finished books, and show title/author under covers.

**Where:** Zen Settings > Library > Appearance > Covers

## Scroll bar

Bar, dots, or page number. Page number can show `x / y` and lets you hold to skip 10, 20, or jump to the start/end.

**Where:** Zen Settings > Library > Appearance > Scroll bar

## Folders

- **Covers**: gallery, first cover, stack, or name only. Can show spine lines and item counts.
- **Series**: auto-group books from the same series into virtual folders. Nothing moves on disk.
- **Folder name**: show/hide, background, and position.
- **Home folder**: set your library root, add extra roots, and lock navigation to it (Off, Only in Zen mode, On).
- **Hide up folder**: hides the `..` row.

**Where:** Zen Settings > Library > Folders

To browse the full filesystem, set **Folders > Home folder > Lock home folder** to **Off**.

### Custom folder covers

Hold a folder, then **Edit > Set folder cover**. Tap a slot to pick a `.jpg`/`.jpeg`, or hold/tap **Clear** to remove it. ZenOS only stores a link to the image, so don't move the original.

You can also drop `cover.jpg` (or `cover1.jpg` through `cover4.jpg`) into the folder. Those stay hidden in the file list.

## Books

- **Book details**: pick and order what shows on the full-screen details page.
- **Double-tap to open a book**: helps with accidental opens. Optionally make a single tap open the context menu.
- **Include new books in TBR**: unread and updated books show up in To Be Read.
- **Treat file updates as New**: modified books get the New badge until opened.
- **Show all files from subfolders**: flattens nested folders into one view. Great for Calibre's author folders.

**Where:** Zen Settings > Library > Books

## To Be Read

Hold a book and pick **Read status > To Be Read**. It'll show up in TBR Navbar tabs and Home widgets.

## Metadata editor

Hold a book and choose **Edit > Edit metadata**, or tap **Edit** on its Book details page. Change the title, authors, series, genres, language, publisher, description, filename, and cover. Close the book first.

**Find metadata** searches Hardcover, Google Books, and Open Library and lets you pick the right edition.

EPUBs get the metadata written into the file. Turn on **Keep an EPUB metadata backup** if you want a **Restore** button. Other formats (like PDF) stay untouched; changes are saved in KOReader's sidecar.

**Where:** Zen Settings > Library > Books > Metadata

### Provider keys

Open Library works out of the box. The other two need a key:

1. **Hardcover**: go to [Hardcover's API page](https://hardcover.app/account/api), make a token with only `read:catalog`, and paste it under **Sources > Hardcover > Hardcover API token** (no `Bearer ` prefix). That menu can also show the page as a QR code.
2. **Google Books**: in Google Cloud, [enable the Books API](https://console.cloud.google.com/apis/library/books.googleapis.com), then **[Credentials](https://console.cloud.google.com/apis/credentials) > Create credentials > API key**. Restrict it to the Books API and paste it under **Sources > Google Books**.

Or put the raw value in a file:

| Key | File |
| --- | --- |
| Hardcover | `koreader/settings/ZenOS/hardcover_token.txt` |
| Google Books | `koreader/settings/ZenOS/google_books_api_key.txt` |

Keys are stored locally as plain text and never logged. Keep them out of shared backups.

## Context menu

Hold any book or folder to open its menu.

**Books:** Details, Read status (Unread, Reading, To Be Read, On hold, Finished), add/remove from collection, and **Edit** for select, cut, copy, paste, edit metadata, refresh, and delete. Setting Unread also clears progress.

**Folders:** Details, rename, new folder, move, sort, cut/copy/paste, and delete.

Toggle **Archive**, **Plugin actions**, and **Allow delete** under **Zen Settings > Library > Context menu**.
