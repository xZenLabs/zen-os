---
title: Translations
category: Translations
summary: Add or improve a language by editing a gettext .po file and opening a PR to dev.
settingsPath: ''
order: 95
---

<!-- Documentation current through ZenOS v3.3.0. -->

ZenOS is translated through gettext `.po` files in the `locales/` folder. No programming knowledge is needed — you only edit text.

> **Open translation pull requests against the `dev` branch.** Changes are reviewed on `dev` before release.

The `en.po` file is the source catalog. All other locales are translated from it. Generated entries include a role-specific type label, a nearby Lua source excerpt, and `filename.lua:line` references to clarify where each string appears. Any string left as `msgstr ""` falls back to English at runtime — KOReader handles this automatically.

## Supported languages

| Locale | Language |
| --- | --- |
| `en` | English |
| `it` | Italian |
| `es` | Spanish |
| `fr` | French |
| `nl` | Dutch |
| `de` | German |
| `bg` | Bulgarian |
| `cs` | Czech |
| `hu` | Hungarian |
| `pt_BR` | Brazilian Portuguese |
| `pt_PT` | European Portuguese |
| `ro` | Romanian |
| `ru` | Russian |
| `uk` | Ukrainian |
| `el` | Greek |
| `ja` | Japanese |
| `vi` | Vietnamese |
| `zh_CN` | Simplified Chinese |
| `zh_TW` | Traditional Chinese |
| `zh_HK` | Traditional Chinese (Hong Kong) |
| `zh_MO` | Traditional Chinese (Macau) |

## Adding a new language

1. Copy `locales/en.po` to `locales/<lang>.po` using the standard locale code, e.g. `de.po`, `ja.po`, `ko.po`.
2. Open the file in any text editor or a PO editor such as [Poedit](https://poedit.net/).
3. Update the language header field:
   ```
   "Language: de\n"
   ```
4. For each entry, fill in the `msgstr` with your translation:
   ```
   msgid "Quick settings"
   msgstr "Schnelleinstellungen"
   ```
5. Open a Pull Request against the `dev` branch.

## Improving an existing translation

Open the `.po` file for your language, correct or complete the `msgstr` values, and open a Pull Request against `dev`.

## Guidelines

- Never modify the `msgid` — only edit `msgstr`.
- Keep generated context comments and source references intact.
- Keep placeholders intact: `%d`, `%s`, `%%`, and `\n` must appear in `msgstr` exactly as they do in `msgid`.
- Leave `msgstr ""` empty for any string you are unsure about — the English original is shown as a fallback.
- If your language has different plural forms, set `Plural-Forms` in the header accordingly.
