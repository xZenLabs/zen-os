---
title: Home
category: Home
summary: Create your own e-reader home page
settingsPath: Zen Settings > Home
order: 10
---

<!-- Documentation current through ZenOS v3.0.0. -->

![ZenOS bookshelf home](/images/zen_os/home_bookshelf.webp)

![ZenOS home](/images/zen_os/zen_home.webp)

![ZenOS home page](/images/zen_os/home_simple.webp)

## Overview

Build a personal Home page from date and time, featured book, reading stats, reading goals, book strip, and quotes widgets. The layout uses a responsive capacity grid so it can make better use of taller or wider screens while keeping widget proportions predictable. Use a built-in preset or save your own layout.

## Options

- Show and arrange any combination of the six built-in widgets that fits the screen's capacity. At least one widget remains enabled.
- Use Edit mode to open widget settings directly from Home.
- Apply, save, rename, and delete home page presets.
- Show or hide the home page top status bar.
- Configure automatic or manual font sizing for date/time, stats, and quotes.
- Set Featured content to Recently read, To Be Read, or one custom book.
- Set Strip content to a library source, specific tag, folder, or up to 40 custom books.
- Add up to seven Strip control tabs for library sources, tags, folders, actions, Controls, plugin menus, or KOReader menus.
- Configure text styles, progress labels, interactivity, filters, and widget-specific display options.
- Track daily, weekly, monthly, and yearly reading goals using pages, time, or supported book-count targets.
- Use stable page labels in featured-widget progress when a book provides a page map.

## Setting reference

| Setting | Description |
| --- | --- |
| Widgets | Opens the widget arranger. Widgets show their relative size and must fit the responsive Home capacity. |
| Widgets > Built-in widgets | Includes Date and time, Featured book, Reading stats, Reading goals, Book strip, and Quotes. |
| Edit mode | Lets supported widgets open their own settings directly from Home. |
| Presets > Built-in presets | Applies bundled home page layouts. Editing a built-in preset creates an editable user copy. |
| Presets > Save current home page as preset | Saves the current home page configuration as a user preset. |
| Presets > User presets | Applies, renames, or deletes saved home page presets. |
| Show top status bar | Shows or hides the top status bar on the home page. |
| Widgets > Date and time > Automatic font size | Fits the time and date to the available widget height, up to the configured maximum. |
| Widgets > Date and time > Time / Date | Sets the font face and manual fallback size for each line. |
| Widgets > Featured book > Content | Selects Recently read, To Be Read, or Custom. Custom lets you choose one book. |
| Widgets > Featured book > Show description | Shows featured-book description text. |
| Widgets > Featured book > Wrap description text | Lets description overflow continue below the cover and uses a full-width progress bar. Disabled by default. |
| Widgets > Featured book > Interactive | Allows the featured book to respond to selection. |
| Widgets > Featured book > Top status bar | Shows the featured widget status bar and configures its bottom border and bold text. |
| Widgets > Featured book > Text styles | Sets title, author, series, and description font face, size, and bold style. |
| Widgets > Featured book > Progress labels | Selects left and right progress labels: off, percent, time to book end, current/total pages, or total pages. Current/total and total pages use stable page labels when the book provides a page map. |
| Widgets > Book strip > Content | Selects Recent, Favorites, To Be Read, Authors, Series, Tags, Collections, a specific tag, a folder, or custom books when Strip controls are hidden. |
| Widgets > Book strip > Controls > Show controls | Adds source and action tabs above the strip. The first visible source tab becomes the active content source. |
| Widgets > Book strip > Controls > Tabs | Shows and arranges up to seven tabs. Add a built-in source, specific tag, folder, dispatcher action, Control, plugin menu, or KOReader menu. |
| Widgets > Book strip > Controls > Font | Sets the strip-control label font, size, and weight. |
| Widgets > Book strip > Show book titles | Shows titles below strip covers. |
| Widgets > Book strip > Show badges | Shows cover badges in the strip. |
| Widgets > Book strip > Interactive | Allows strip books and controls to respond to selection. |
| Widgets > Book strip > Max books shown | Sets 3–5 books for one row or 2–10 books for two rows; narrower layouts may show fewer. |
| Widgets > Book strip > Two rows | Expands the strip to two rows when enough Home capacity is available. |
| Widgets > Book strip > Center books | Centers short rows. |
| Widgets > Book strip > Recent filters | Hides unread, On hold, or finished books when Recent is the active source. |
| Widgets > Book strip > Custom books | Adds or removes selected books, up to 40. |
| Widgets > Reading goals > Daily / Weekly | Shows a pages or time goal for the selected period. |
| Widgets > Reading goals > Monthly / Yearly | Shows a pages, time, or books goal for the selected period. |
| Widgets > Reading goals > Font size | Sets the reading-goals text size. |
| Widgets > Reading stats > Stat separators | Selects dividing lines, outlined boxes, or no stat separators. |
| Widgets > Reading stats > Automatic font size | Fits the three stat slots to the available height, up to the configured maximum. Disable it to set a fixed font size. |
| Widgets > Reading stats > Stat slot 1–3 | Selects pages today, time today, day streak, pages this week, or time this week for each slot. |
| Widgets > Quotes > Quote sources | Selects any combination of default quotes, custom quote files, and annotations. |
| Widgets > Quotes > Quote sources > Custom quotes | Turns individual quote files on or off. Select multiple files to combine them. |
| Widgets > Quotes > New quote | Changes the quote daily or whenever Home refreshes. |
| Widgets > Quotes > Automatic font size | Fits quote text to the available area up to the configured maximum. Disable it to use a fixed size. |
| Widgets > Quotes > Show author | Shows the quote author when available. |
| Widgets > Quotes > Show title | Shows the book title when available. |

Opening a book from Featured or Book strip uses the same non-blocking opening banner as the Library.

## Stable Page Labels

Home featured widgets use KOReader page-map data when it is available. That means progress labels can show the same stable page labels used in the reader, page browser, and table of contents instead of only calculated file pages.

## Custom quotes

Add personal quotes to `settings/ZenOS/quotes.lua`. Put additional `.lua` quote
files in `settings/ZenOS/quotes/`; ZenOS creates this folder automatically and
does not scan other settings files. Under **Zen Settings > Home > Widgets >
Quotes > Quote sources > Custom quotes**, turn on each file you want to use.
Selected files are combined and can still be mixed with the default list and
annotations. Turning off the last file disables custom quotes. Each entry can
be a `{ text, author, title }` table, the older `{ text, author }` form, or a
plain string without attribution.

```text
settings/ZenOS/
├── quotes.lua
└── quotes/
    ├── philosophy.lua
    └── favorites.lua
```

`quotes.lua` remains the primary file for existing installations. Additional
files can use any other `.lua` filename and must be placed directly in the
`quotes/` folder. Every file uses the same format:

```lua
return {
    -- Existing formats remain supported:
    -- { text = "Quote text", author = "Author" },
    -- "Plain quote without author",

    -- The title field is optional:
    -- { text = "Quote text", author = "Author", title = "Book title" },
}
```

Annotation quotes are collected from books in KOReader's reading history and
book-information cache. Tap an annotation quote to open its book at the saved
location. Swipe horizontally on the widget to move between quotes. Quotes use a
persistent shuffled deck, so every enabled quote is shown before the list is
reshuffled.
