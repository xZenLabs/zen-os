---
title: Translations
category: Translations
summary: Add or improve a language by editing a gettext .po file and opening a PR to dev.
settingsPath: ''
order: 95
---

<!-- Documentation current through ZenOS v4.3.0. -->

Translations live in `.po` files in `locales/`. No coding needed, you're just editing text.

> **Open translation PRs against `dev`.**

`en.po` is the source. Anything left as `msgstr ""` shows in English.

## Languages

English, Italian, Spanish, French, Dutch, German, Bulgarian, Czech, Hungarian, Indonesian, Polish, Brazilian Portuguese, European Portuguese, Romanian, Russian, Ukrainian, Greek, Japanese, Vietnamese, and Chinese (Simplified, Traditional, Hong Kong, Macau).

## Add a language

1. Copy `locales/en.po` to `locales/<lang>.po` (e.g. `ko.po`).
2. Open it in a text editor or [Poedit](https://poedit.net/).
3. Set the header: `"Language: ko\n"`
4. Fill in each `msgstr`:
   ```
   msgid "Quick settings"
   msgstr "Schnelleinstellungen"
   ```
5. Open a PR to `dev`.

To fix an existing language, edit its `.po` and open a PR.

## Tips

- Don't touch `msgid`. Only edit `msgstr`.
- Keep placeholders exactly as they are: `%d`, `%s`, `%%`, `\n`.
- Not sure about a string? Leave it empty and it'll show in English.
- Each entry has a `#. Context:` note explaining where it shows up. Feel free to improve those in your language.
- Set `Plural-Forms` in the header if your language needs it.
