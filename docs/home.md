---
title: Home
category: Home
summary: Create your own e-reader home page
settingsPath: Zen Settings > Home
order: 10
---

<!-- Documentation current through ZenOS v4.3.0. -->

![ZenOS bookshelf home](/images/zen_os/home_bookshelf.webp)

![ZenOS home](/images/zen_os/zen_home.webp)

![ZenOS home page](/images/zen_os/home_simple.webp)

Home is your start page. Pick the widgets you want, stack them how you like, and save the layout as a preset.

## Widgets

Six built-in widgets: **Date and time**, **Featured book**, **Reading stats**, **Reading goals**, **Book strip**, and **Quotes**. Each one takes up a bit of the screen, so you can only enable what fits. At least one stays on.

With **Edit mode** on (default), tap a widget on Home to jump straight to its settings.

**Where:** Zen Settings > Home > Widgets

## Presets

Apply one of the built-in layouts or save your own. Editing a built-in preset makes you a copy, so the original is never lost.

**Where:** Zen Settings > Home > Presets

## Featured book

Shows one big book with cover, details, and progress. Choose **Recently read**, **To Be Read**, or pick a specific book. You can show the description, wrap it under the cover, style the text, and pick what the left and right progress labels show (percent, time left, pages).

**Where:** Zen Settings > Home > Widgets > Featured book

## Book strip

A row (or two) of covers. Sources include Recent, Favorites, To Be Read, Authors, Series, Languages, Tags, Collections, a folder, Kindle Library (with [kindle.koplugin](https://github.com/kaikozlov/kindle.koplugin)), or up to 40 hand-picked books.

Turn on **Controls** to add up to seven tabs above the strip. Tabs can switch the source (including Unread, Reading, On hold, Finished) or run an action, Control, plugin menu, or KOReader menu.

**Where:** Zen Settings > Home > Widgets > Book strip

## Reading stats and goals

**Reading stats** shows three numbers of your choice: pages today, time today, day streak, pages this week, or time this week.

**Reading goals** tracks daily and weekly pages or time, plus monthly and yearly pages, time, or books.

**Where:** Zen Settings > Home > Widgets > Reading stats / Reading goals

## Quotes

Mix built-in quotes, your own quote files, and your highlights. Swipe sideways to flip through them. Tap a highlight to jump to it in the book. Every quote shows once before the deck reshuffles.

**Where:** Zen Settings > Home > Widgets > Quotes > Quote sources

### Adding your own quotes

Put quotes in `koreader/settings/ZenOS/quotes.lua`, or drop extra `.lua` files in `koreader/settings/ZenOS/quotes/`. Turn each file on under **Quote sources > Custom quotes**.

```text
koreader/settings/ZenOS/
├── quotes.lua
└── quotes/
    ├── philosophy.lua
    └── favorites.lua
```

```lua
return {
    { text = "Quote text", author = "Author", title = "Book title" },
    { text = "Quote text", author = "Author" },
    "Plain quote without author",
}
```

## Other bits

- **Show top status bar** toggles the status bar on Home.
- Date/time, stats, and quotes can auto-size their text to fit, or use a fixed size.
- Books with a page map show the same stable page numbers here as in the reader.
