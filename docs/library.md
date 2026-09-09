---
title: Library
category: Library
summary: All your books in one place
settingsPath: Zen Settings > Library
order: 30
---

<!-- Documentation current through ZenOS v3.3.0. -->

![Library cover view](/images/zen_os/library_covers_full.webp)

![Library list view](/images/zen_os/library_list_full.webp)

![Context menu](/images/zen_os/context_menu.webp)

![Metadata editor](/images/zen_os/metadata_editor.webp)

## Overview

Library settings control the KOReader library. Customize the top status bar, layout, folder display, background image, book details, and metadata tools. Tap and hold on any item in the Library or the Navbar and it will bring up the Context Menu. This is a detailed menu of actions for the currently selected item.

## Options

- Configure the top status bar with left, center, and right item slots.
- Set the library font face and font size.
- Choose display mode, mosaic density, list density, item underlines, and list borders.
- Configure folder covers, folder labels, hidden up-folder rows, and automatic series grouping.
- Optionally flatten subfolders into one library view without changing files on disk.
- Configure cover badges, progress indicators, uniform cover ratios, rounded corners, title and author text, and finished-book dimming.
- Configure the scroll bar as a bar, dots, or page number.
- Set a custom Library background image.
- Set and lock the home folder, add extra home folders, and control delete access.
- Edit book metadata and covers manually or fill them from online providers.
- Choose and arrange the information shown on Book details pages.
- Optionally include new and updated books in To Be Read views.

## Setting reference

| Setting | Description |
| --- | --- |
| Status bar > Enable custom status bar | Shows ZenOS's library status bar. |
| Status bar > Custom text | Sets custom status text. Empty text falls back to the device model. |
| Status bar > Show bottom border | Draws a separator below the status bar. |
| Status bar > Bold text | Uses bold text in the status bar. |
| Status bar > Colored status icons | Uses colored status icons when supported. |
| Status bar > Left items | Selects and arranges Bluetooth, Incognito, Wi-Fi, disk space, RAM usage, brightness, battery, time, or custom text for the left slot. |
| Status bar > Center items | Selects and arranges status items for the center slot. |
| Status bar > Right items | Selects and arranges status items for the right slot. |
| Status bar > Separator | Selects dot, bar, dash, bullet, space, small space, none, or a custom separator. |
| Metadata > Hardcover | Enables Hardcover lookup. A read-only catalog token is required. |
| Metadata > Google Books | Enables Google Books lookup. An API key is required. |
| Metadata > Open Library | Enables Open Library lookup without an API credential. |
| Metadata > Match selection | Automatically picks the best result or always opens the match chooser. |
| Metadata > Keep an EPUB metadata backup | Keeps one restorable copy before ZenOS writes metadata into an EPUB. |
| Font > Font | Sets the global ZenOS font family, or restores the default font. Applies everywhere except the reader. |
| Font > Font size | Sets the global base text size from 10 to 40. |
| Layout > Display mode | Selects classic, mosaic with covers, mosaic with text, detailed list with covers and metadata, detailed list with metadata, or detailed list with covers and filenames. |
| Layout > Items per page | Sets portrait mosaic columns and rows, landscape mosaic columns and rows, and list items per page. |
| Layout > Show all files from subfolders | Shows books from nested folders in one flat view. It is unavailable at the device root to avoid scanning the entire filesystem. |
| Layout > Show item underline | Shows or hides the underline between browser items. |
| Layout > Hide list borders | Hides borders in list display modes. |
| Folders > Hide up folder | Hides the parent-folder row. |
| Folders > Series > Group book series into folders | Automatically groups books that share series metadata into generated series folders, sorted by series position. The folders are virtual — they reorganize the view without moving files on disk. |
| Folders > Series > Hide grouped series | Hides multi-book series groups from the folder view. Available only when automatic series grouping is enabled; books remain accessible from the Series tab. |
| Folders > Covers | Selects gallery, first cover image, stack, or folder-name-only folder covers. Override per folder with a custom cover image (see below). |
| Folders > Show spine lines | Shows book-spine lines on stacked folder covers. |
| Folders > Show item count | Shows item counts on folder covers. |
| Folders > Folder name | Controls folder name visibility, opaque background, and center or bottom placement. |
| Covers > Badge size | Sets badge size to compact, normal, large, or extra large. |
| Covers > Badge color | Sets the badge color from presets or custom RGB values. |
| Covers > Show page count | Shows page count badges on covers. |
| Covers > Show series number on covers | Shows series position badges on covers. |
| Covers > Show favorite badge | Shows a favorite badge on favorite books. |
| Covers > Show new banner | Shows a new-book banner on recently added books. |
| Covers > Show KOReader progress bar | Shows KOReader's native progress bar on covers. |
| Covers > Show progress percent on mosaic covers | Shows reading progress percentage on mosaic covers. |
| Covers > Uniform covers | Enables uniform mosaic cover sizing. |
| Covers > Uniform cover ratio | Selects 2:3 standard covers or 3:4 Kindle covers. |
| Covers > Dim finished books | Dims finished books in cover views. |
| Covers > Rounded cover corners | Rounds cover corners in supported cover views. |
| Covers > Show title below cover (mosaic) | Shows title text below mosaic covers. |
| Covers > Show author below cover (mosaic) | Shows author text below mosaic covers. |
| Scroll bar > Style | Selects bar, dots, or page number scrolling. |
| Scroll bar > Page number format | Shows the current page only or page x / y when page-number style is active. |
| Scroll bar > Hold to skip | Sets page-number long-press behavior to skip 10 pages, skip 20 pages, or jump to beginning/end. |
| Background > Enable | Shows the selected background image behind Library surfaces. |
| Background > Image | Opens a file chooser for a JPG or JPEG background image. Hold this row to clear the selected image. |
| Home folder > Set home folder | Opens a folder chooser for the primary library root. |
| Home folder > Lock home folder | Selects Off, Only in Zen Mode, or Always for navigation outside the home folder. |
| Home folder > Additional home folders | Adds or removes extra library roots. |
| Book details | Chooses and arranges the metadata, reading progress, and timing fields shown in full-screen Book details. Tags can optionally open their Library view. |
| Include new books in TBR | Includes unread books and books modified since they were last opened in To Be Read views without changing their saved read status. |
| Library > Allow delete | Enables or disables delete actions in the library context menu. |

## Fonts

The library **Font** settings set the global ZenOS font. You can change the font family and base size, and it applies across the whole interface — library, navbar, home, menus, status bars — everything except the reader.

The reader has its own separate font controls, so you can give the reading view a different font, size, and bold setting from the rest of the UI.

## Metadata editor

![Metadata editor](/images/zen_os/metadata_editor.webp)

Open **Edit > Edit metadata** from a book's context menu, or choose **Edit** on a ZenOS Book details page. The editor can change the filename, cover, title, authors, series and position, genres, language, publisher, and description. Close a book before editing its metadata.

**Find metadata** searches every enabled provider and can use the book's ISBN or a title and author query. Hardcover and Google Books require credentials; enter them under **Zen Settings > Library > Metadata**. They are stored locally as plain text and never logged. Open Library requires no credential. Search results show available editions with their format, publisher, language, page count, and cover so you can choose the correct match.

For EPUB files, ZenOS writes supported metadata into the book after confirmation. Enable **Keep an EPUB metadata backup** if you want a **Restore** action; the editor keeps one backup beside the EPUB. Other formats, including PDF, keep the original document unchanged and save KOReader metadata overrides in the book's sidecar data. Cover changes use KOReader's custom-cover file.

## Custom folder covers

Long-press a folder and open **Edit > Set folder cover** to see a full-screen vertical mosaic of cover slots and their current previews. Each row places the preview on the left, **Cover N** vertically centered, and a Zen **Clear** button at the far right. Tap a cover or press OK/Enter on its focused row to choose an image; press and hold it or tap **Clear** to remove the reference. Single-cover mode offers one slot; gallery and stack modes show all four slots together on one page without pagination. Previews scale to fit the page while using the same aspect ratio, crop mode, and rounded-corner styling as the Library file picker. A gallery or stack with only one chosen or automatic cover is displayed as one full-size cover, and chosen covers are not filled out with automatic book covers.

ZenOS stores only a reference to each chosen image: it does not copy the image into the folder or modify the source file, so the source must remain available at the selected location. Folder covers accept case-insensitive `.jpg` and `.jpeg` files. You can also manage them manually as `cover.jpg`, `cover.jpeg`, `cover1.jpg`, `cover1.jpeg`, and the equivalent names through `cover4`; these managed images stay hidden in the Library file list and override covers generated from the folder's contents. PNG, WebP, GIF, and other formats are not treated as folder covers and remain visible.

## Library Background

Use **Zen Settings > Library > Background > Enable** and **Zen Settings > Library > Background > Image** to add a custom JPG/JPEG background to the Library. Changing or clearing the background refreshes the Library, Home, and Navbar surfaces so the new image is applied without hunting through separate settings.

## Context menu

Tap and hold any book, folder, or the current folder in the Library/Navbar. This opens the context menu. It collects details, file management, read status, sorting, filtering, and display actions for the selected item. Available actions depend on what you held — a book, a folder, or empty space in the current folder.

![Context menu](/images/zen_os/context_menu.webp)

## Display mode & sorting
Tap + Hold on the Navbar (or any empty space) to open the context menu for the folder you are viewing (including your libraries Home folder). From here you can change the folder's display mode, sorting, and status filter on the fly. Each folder remembers its own display and sorting preferences independently, so you can browse one folder as a mosaic sorted by title and another as a detailed list sorted by recently read, and each keeps its settings across sessions.

## Filesystem
To navigate the complete filesystem, set **Zen Settings > Library > Home folder > Lock home folder** to **Off**.

### Book actions

| Action | Description |
| --- | --- |
| Details | Shows the book's cover, selected metadata, description, progress, and actions in a fullscreen view. Choose **Edit** to open the ZenOS metadata editor. |
| Read status | Sets the book to Unread, Reading, To Be Read, On hold, or Finished. Setting Unread also clears reading progress (percent, last page, and position). |
| Add to collection | Adds the book to a chosen collection, including Favorites. |
| Remove from collection | Removes the book from the collection when viewed inside one. |
| Edit > Select | Enters multi-select mode for batch actions on multiple items. |
| Edit > Cut | Cuts the book to the clipboard for moving. |
| Edit > Copy | Copies the book to the clipboard. |
| Edit > Paste | Pastes a clipboard item into the current location. |
| Edit > Edit metadata | Opens the native metadata editor for manual changes or online lookup. |
| Edit > Refresh | Clears and rebuilds the book's cached metadata and cover. |
| Edit > Delete | Deletes the book after confirmation. Only shown when Allow delete is enabled. |

### Folder actions

| Action | Description |
| --- | --- |
| Details | Shows a folder cover preview and the recursive book count. |
| Rename | Renames the folder. |
| New folder | Creates a new folder inside the current location. |
| Move | Moves the folder to a chosen destination. |
| Sort library by | Sets the library-wide sort: Title, Authors, Series, or Recently read, with a forward or reverse order. Shown on the home folder. |
| Sort folder by | Sets a sort override for this folder only, independent of the library sort. Includes a Clear action to remove the override. |
| Edit > Cut, Copy, Paste | Moves or copies the folder using the clipboard. |
| Edit > Delete | Deletes the folder after confirmation. Only shown when Allow delete is enabled. |

### Current folder actions

Hold on empty space to bring up the Context Menu for the folder you are viewing.

| Action | Description |
| --- | --- |
| Display | Sets the display mode for the current folder: Mosaic, List (detailed), or List (basic). This per-folder override is independent of the global display mode. |
| Filter by status | Filters the current view by read status: All, Unread, Reading, To Be Read, On hold, or Finished. Multiple statuses can be combined; selecting all or none clears the filter. The filter persists across sessions. |
| Sort folder by | Sets a per-folder sort override for the current folder. |
