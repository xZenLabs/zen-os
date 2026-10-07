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

Open **Zen Settings > Library** for four groups: **Appearance**, **Folders**, **Books**, and **Context menu**. Appearance contains Layout, Covers, and Scroll bar. Folders contains Covers, Series, Folder name, Home folder, and Hide up folder, in that order.

The global Font, Wallpaper, and Status bar settings live under **Zen Settings > Interface**. See [Interface](/zen-os/docs/interface) for those options.

## Options

- Change display mode from the current folder's context menu under **Display**.
- Set portrait and landscape mosaic density with sliders and a placeholder-cover preview.
- Set list density and toggle or arrange detailed list fields; file type is off by default.
- Show or hide item underlines and list borders.
- Configure folder covers, folder labels, hidden up-folder rows, and automatic series grouping.
- Optionally flatten subfolders into one library view without changing files on disk.
- Configure cover badges, progress indicators, uniform cover ratios, rounded corners, title and author text, and finished-book dimming.
- Configure the scroll bar as a bar, dots, or page number.
- Set and lock the home folder, add extra home folders, and control delete access.
- Edit book metadata and covers manually or fill them from online providers.
- Choose and arrange the information shown on Book details pages.
- Optionally include new and updated books in To Be Read views.

## Setting reference

Paths below start at **Zen Settings > Library**.

| Setting | Description |
| --- | --- |
| Appearance > Layout > Mosaic > Portrait | Sets portrait columns and rows from 2 to 8 with snapping sliders and a live preview. Default: 3 × 3. Accept saves; Cancel discards changes. |
| Appearance > Layout > Mosaic > Landscape | Sets landscape columns and rows from 2 to 8 with snapping sliders and a live preview. Default: 4 × 2. Accept saves; Cancel discards changes. |
| Appearance > Layout > Mosaic > Reset to default | Restores both portrait and landscape grid defaults. This is the last item in the Mosaic menu. |
| Appearance > Layout > List > Items per page | Sets list density from 4 to 12 items per page. Default: 5. |
| Appearance > Layout > List > Detailed list items | Toggles and arranges Title, Authors, Series, Tags, Filename, Language, File size, Read status, Pages, and File type. Title, Authors, Series, Tags, Read status, and Pages are enabled by default; the other fields are off. |
| Appearance > Layout > List > Hide list borders | Hides borders in list display modes. |
| Appearance > Layout > Show all files from subfolders | Shows books from nested folders in one flat view. It is unavailable at the device root to avoid scanning the entire filesystem. |
| Appearance > Layout > Show item underline | Shows or hides the underline between browser items. |
| Appearance > Covers > Badges > Badge size | Sets badge size to compact, normal, large, or extra large. |
| Appearance > Covers > Badges > Badge color | Sets the badge color from presets or custom RGB values. |
| Appearance > Covers > Badges > Show page count | Shows page count badges on covers. |
| Appearance > Covers > Badges > Show series number on covers | Shows series position badges on covers. |
| Appearance > Covers > Badges > Show favorite badge | Shows a favorite badge on favorite books. |
| Appearance > Covers > Badges > Show new banner | Shows a new-book banner on recently added books. |
| Appearance > Covers > Badges > Show progress bar | Shows KOReader's native progress bar on covers. |
| Appearance > Covers > Badges > Show reading progress | Shows reading progress percentage on mosaic covers. |
| Appearance > Covers > Uniform covers > Uniform covers | Enables uniform mosaic cover sizing. |
| Appearance > Covers > Uniform covers | Selects 2:3 standard covers or 3:4 Kindle covers. |
| Appearance > Covers > Dim finished books | Dims finished books in cover views. |
| Appearance > Covers > Rounded cover corners | Rounds cover corners in supported cover views. |
| Appearance > Covers > Show title below cover (mosaic) | Shows title text below mosaic covers. |
| Appearance > Covers > Show author below cover (mosaic) | Shows author text below mosaic covers. |
| Appearance > Scroll bar | Selects Bar, Dots, or Page number using the style's radio button. Open the Page number row for its format and hold controls. |
| Appearance > Scroll bar > Page number > Page number format | Shows the current page only or page x / y. |
| Appearance > Scroll bar > Page number > Hold to skip | Sets page-number long-press behavior to skip 10 pages, skip 20 pages, or jump to beginning/end. |
| Folders > Covers | Selects gallery, first cover image, stack, or folder-name-only folder covers. Override per folder with a custom cover image (see below). |
| Folders > Covers > Show spine lines | Shows book-spine lines on stacked folder covers. |
| Folders > Covers > Show item count | Shows item counts on folder covers. |
| Folders > Series > Group book series into folders | Automatically groups books that share series metadata into generated series folders, sorted by series position. The folders are virtual — they reorganize the view without moving files on disk. |
| Folders > Series > Hide grouped series | Hides multi-book series groups from the folder view. Available only when automatic series grouping is enabled; books remain accessible from the Series tab. |
| Folders > Folder name | Controls folder name visibility, opaque background, and center or bottom placement. |
| Folders > Home folder > Set home folder | Opens a folder chooser for the primary library root. |
| Folders > Home folder > Lock home folder | Selects Off, Only in Zen mode, or On for navigation outside the home folder. |
| Folders > Home folder > Additional home folders | Adds or removes extra library roots. |
| Folders > Hide up folder | Hides the parent-folder row. |
| Books > Book details | Chooses and arranges the metadata, reading progress, and timing fields shown in full-screen Book details. Tags can optionally open their Library view. |
| Books > Metadata > Hardcover | Enables Hardcover lookup. A read-only catalog token is required. |
| Books > Metadata > Google Books | Enables Google Books lookup. An API key is required. |
| Books > Metadata > Open Library | Enables Open Library lookup without an API credential. |
| Books > Metadata > Match selection | Automatically picks the best result or always opens the match chooser. |
| Books > Metadata > Keep an EPUB metadata backup | Keeps one restorable copy before ZenOS writes metadata into an EPUB. |
| Books > Double-tap to open a book | Requires two rapid taps on the same book in Library, Home, or Book switcher before opening it. Keyboard controls are unchanged. |
| Books > Double-tap to open a book > Single tap to open context menu | Makes a single tap open the context menu when double-tap opening is enabled. |
| Books > Include new books in TBR | Includes unread books and books modified since they were last opened in To Be Read views without changing their saved read status. |
| Books > Treat file updates as New | Shows modified books as New until they are opened or their read status is changed. |
| Context menu > Archive | Shows archive actions in the library context menu. |
| Context menu > Plugin actions | Shows actions provided by installed plugins in the library context menu. |
| Context menu > Allow delete | Enables or disables delete actions in the library context menu. |

## To Be Read

To add a book to To Be Read, hold it in the Library and choose **Read status > To Be Read**. It then appears in To Be Read Navbar tabs and Home widgets that use that source. **Include new books in TBR** also includes unread or modified books without changing their saved read status.

## Metadata editor

![Metadata editor](/images/zen_os/metadata_editor.webp)

Open **Edit > Edit metadata** from a book's context menu, or choose **Edit** on a ZenOS Book details page. The editor can change the filename, cover, title, authors, series and position, genres, language, publisher, and description. Close a book before editing its metadata.

**Find metadata** searches every enabled provider and can use the book's ISBN or a title and author query. Hardcover and Google Books require credentials; enter them under **Zen Settings > Library > Books > Metadata**. They are stored locally as plain text and never logged. Open Library requires no credential. Search results show available editions with their format, publisher, language, page count, and cover so you can choose the correct match.

### Metadata provider credentials

The easiest setup is through **Zen Settings > Library > Books > Metadata**:

1. **Hardcover:** Sign in to [Hardcover's API page](https://hardcover.app/account/api), create a personal access token with only the `read:catalog` permission, and copy the token value. Open **Hardcover > Hardcover API token** in ZenOS and paste it without a leading `Bearer ` prefix. The same Hardcover submenu can display this page as a QR code.
2. **Google Books:** In Google Cloud, select or create a project, [enable the Books API](https://console.cloud.google.com/apis/library/books.googleapis.com), then open [Credentials](https://console.cloud.google.com/apis/credentials) and choose **Create credentials > API key**. Restrict the key to the **Books API**, copy it, and paste it under **Google Books > Google Books API key**. See [Google's API-key instructions](https://developers.google.com/books/docs/v1/using#acquiring_and_using_an_api_key) for more detail.

To install the credentials manually instead, put each raw value on one line in the following file:

| Credential | File |
| --- | --- |
| Hardcover token | `koreader/settings/ZenOS/hardcover_token.txt` |
| Google Books API key | `koreader/settings/ZenOS/google_books_api_key.txt` |

Use the exact filenames above. Do not add a variable name, quotes, or `Bearer `; these files contain only the credential. Keep them private and out of shared backups.

For EPUB files, ZenOS writes supported metadata into the book after confirmation. Enable **Keep an EPUB metadata backup** if you want a **Restore** action; the editor keeps one backup beside the EPUB. Other formats, including PDF, keep the original document unchanged and save KOReader metadata overrides in the book's sidecar data. Cover changes use KOReader's custom-cover file.

## Custom folder covers

Long-press a folder and open **Edit > Set folder cover** to see a full-screen vertical mosaic of cover slots and their current previews. Each row places the preview on the left, **Cover N** vertically centered, and a Zen **Clear** button at the far right. Tap a cover or press OK/Enter on its focused row to choose an image; press and hold it or tap **Clear** to remove the reference. Single-cover mode offers one slot; gallery and stack modes show all four slots together on one page without pagination. Previews scale to fit the page while using the same aspect ratio, crop mode, and rounded-corner styling as the Library file picker. A gallery or stack with only one chosen or automatic cover is displayed as one full-size cover, and chosen covers are not filled out with automatic book covers.

ZenOS stores only a reference to each chosen image: it does not copy the image into the folder or modify the source file, so the source must remain available at the selected location. Folder covers accept case-insensitive `.jpg` and `.jpeg` files. You can also manage them manually as `cover.jpg`, `cover.jpeg`, `cover1.jpg`, `cover1.jpeg`, and the equivalent names through `cover4`; these managed images stay hidden in the Library file list and override covers generated from the folder's contents. PNG, WebP, GIF, and other formats are not treated as folder covers and remain visible.

## Context menu

Tap and hold any book, folder, or the current folder in the Library/Navbar. This opens the context menu. It collects details, file management, read status, sorting, filtering, and display actions for the selected item. Available actions depend on what you held — a book, a folder, or empty space in the current folder.

![Context menu](/images/zen_os/context_menu.webp)

## Display mode & sorting
Tap + Hold on the Navbar (or any empty space) to open the context menu for the folder you are viewing (including your libraries Home folder). From here you can change the folder's display mode, sorting, and status filter on the fly. Each folder remembers its own display and sorting preferences independently, so you can browse one folder as a mosaic sorted by title and another as a detailed list sorted by recently read, and each keeps its settings across sessions.

## Filesystem
To navigate the complete filesystem, set **Zen Settings > Library > Folders > Home folder > Lock home folder** to **Off**.

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
