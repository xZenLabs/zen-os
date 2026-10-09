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

The `en.po` file is the source catalog. All other locales are translated from it. Entries include a role-specific type label, context for translators, and `filename.lua:line` references. Any string left as `msgstr ""` falls back to English at runtime — KOReader handles this automatically.

Sync preserves existing human-readable `#. Context:` descriptions while refreshing source references. If a locale has no readable context, it reuses the description from `en.po`. Otherwise it uses a `-- Translators: ...` note immediately above the Lua translation call, or a nearby code excerpt when no note exists. Legacy code excerpts are refreshed on each sync.

Each locale's context descriptions use that locale's language to explain the UI purpose and intended meaning. These are guidance for translators, so natural explanations are more useful than literal translations of the English context. Product names and format placeholders stay intact.

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
| `id` | Indonesian |
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

- Never modify the `msgid` — put translated text in `msgstr`.
- Keep generated type labels and source references intact. You can improve `#. Context:` descriptions in the locale's language; sync preserves them.
- Keep placeholders intact: `%d`, `%s`, `%%`, and `\n` must appear in `msgstr` exactly as they do in `msgid`.
- Leave `msgstr ""` empty for any string you are unsure about — the English original is shown as a fallback.
- If your language has different plural forms, set `Plural-Forms` in the header accordingly.
