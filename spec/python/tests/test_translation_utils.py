import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import mock_open, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
import translation_utils


class TranslationUtilsTest(unittest.TestCase):
    def test_google_api_key_reads_env_file_without_overriding_environment(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch("builtins.open", mock_open(read_data='GOOGLE_TRANSLATE_API_KEY="file-key"\n')):
            self.assertEqual("file-key", translation_utils.google_api_key())
        with patch.dict(os.environ, {"GOOGLE_TRANSLATE_API_KEY": "environment-key"}):
            self.assertEqual("environment-key", translation_utils.google_api_key())

    def test_google_cloud_translation_batches_and_restores_placeholders(self):
        response = io.BytesIO(json.dumps({
            "data": {"translations": [
                {"translatedText": "⟪ZENFMT0⟫ Std."},
                {"translatedText": "Hallo"},
            ]},
        }).encode())
        with patch.dict(os.environ, {"GOOGLE_TRANSLATE_API_KEY": "test-key"}), \
                patch("urllib.request.urlopen", return_value=response) as urlopen:
            self.assertEqual(
                {"%1h": "%1 Std.", "Hello": "Hallo"},
                translation_utils.translate_strings("de", ["%1h", "Hello"]),
            )

        request = urlopen.call_args.args[0]
        self.assertEqual(translation_utils.GOOGLE_TRANSLATE_URL, request.full_url)
        self.assertEqual("test-key", request.get_header("X-goog-api-key"))
        self.assertEqual(["⟪ZENFMT0⟫h", "Hello"], json.loads(request.data)["q"])

    def test_extraction_ignores_comments_and_supports_gettext_aliases(self):
        with tempfile.TemporaryDirectory() as tmp:
            lua_path = Path(tmp) / "menu.lua"
            lua_path.write_text(
                '-- _("Dead")\nlocal live = _("Live")\n'
                '--[[ gettext("Also dead") ]]\n'
                'local labels = { gettext("First name"), __("p.") }\n',
                encoding="utf-8",
            )

            self.assertEqual(
                ["Live", "First name", "p."],
                [msgid for msgid, _line, _context, _kind in translation_utils.extract_from_file(str(lua_path))],
            )
            self.assertEqual(("⟪ZENFMT0⟫h", ["%1"]), translation_utils._protect_format_tokens("%1h"))
            self.assertEqual("zh-TW", translation_utils.GOOGLE_LOCALES["zh_HK"])
            self.assertEqual("zh-TW", translation_utils.GOOGLE_LOCALES["zh_MO"])

    def test_context_comments_are_complete_and_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lua_path = root / "menu.lua"
            lua_path.write_text(
                'local items = {\n    text = _("Open"),\n    cancel = _("Cancel"),\n'
                '    other_cancel = _("Cancel"),\n}\n',
                encoding="utf-8",
            )
            sources = {}
            for msgid, line, context, kind in translation_utils.extract_from_file(str(lua_path)):
                sources.setdefault(msgid, []).append((lua_path.name, line, context, kind))

            po_path = root / "fr.po"
            po_path.write_text(
                'msgid ""\nmsgstr ""\n"Language: fr\\n"\n\n'
                'msgid ""\n"Can"\n"cel"\n'
                'msgstr ""\n"Annu"\n"ler"\n',
                encoding="utf-8",
            )
            existing = translation_utils.parse_po(str(po_path))
            self.assertEqual({"Cancel": "Annuler"}, existing)
            translation_utils.rewrite_po(
                str(po_path), existing, sources,
                [], remove_dead=False, alphabetize=True,
            )
            first = po_path.read_text(encoding="utf-8")

            self.assertIn("#. Type: button", first)
            self.assertIn('#. Context: text = _("Open"), cancel = _("Cancel"),', first)
            self.assertIn("#: menu.lua:3 menu.lua:4", first)
            self.assertIn('msgstr "Annuler"', first)

            translation_utils.rewrite_po(
                str(po_path), translation_utils.parse_po(str(po_path)), sources,
                [], remove_dead=False, alphabetize=True,
            )
            self.assertEqual(first, po_path.read_text(encoding="utf-8"))

            escaped = 'Annuler "maintenant" à C:\\books\nNext\titem\r'
            self.assertEqual(
                escaped,
                translation_utils.parse_po_text(
                    translation_utils.format_entry("Cancel", escaped)
                )["Cancel"],
            )

    def test_type_labels_prioritize_specific_uses(self):
        back = [("modules/menu/patches/app_launcher.lua", 1, "Button label in the Launcher panel.", "button")]
        settings = [
            ("modules/menu/app_launcher/native_menu.lua", 1, "Menu entry in the Launcher menu selector.", "menu"),
            ("modules/settings/zen_settings_page.lua", 2, "Title in the Zen Settings menu.", "title"),
        ]
        self.assertTrue(translation_utils.format_entry("Back", sources=back).startswith("#. Type: button\n"))
        settings_entry = translation_utils.format_entry("Settings", sources=settings)
        self.assertTrue(settings_entry.startswith("#. Type: title\n"))
        self.assertIn('#. Context: Title in the Zen Settings menu. Menu entry in the Launcher menu selector.', settings_entry)
        self.assertEqual("setting", translation_utils.translation_type(
            "modules/settings/reader_settings.lua", 'text = _("Show clock")', "", "Show clock",
        ))
        self.assertEqual("description", translation_utils.translation_type(
            "quickstart.lua", 'description = _("Choose a layout")', "", "Choose a layout",
        ))
        self.assertEqual("unit", translation_utils.translation_type("stats.lua", '_(" days")', "", " days"))
        self.assertEqual("format", translation_utils.translation_type("date.lua", '_("%1, %2")', "", "%1, %2"))
        self.assertEqual("message", translation_utils.translation_type(
            "library.lua", 'return _("No books found")', "", "No books found",
        ))

    def test_translator_notes_explain_meaning_without_changing_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            lua_path = Path(tmp) / "about_settings.lua"
            note = "Settings menu showing total device storage and storage usage details."
            lua_path.write_text(
                f'-- Translators: {note}\ntext = _("Storage")\ntext = _("Device")\n',
                encoding="utf-8",
            )
            entries = translation_utils.extract_from_file(str(lua_path))
            self.assertEqual(("Storage", 2, note, "setting"), entries[0])
            self.assertIn('text = _("Device")', entries[1][2])
            self.assertFalse(translation_utils.is_human_context(entries[1][2]))
            self.assertEqual("Device", entries[1][0])

    def test_device_and_reading_goal_contexts_describe_actual_uses(self):
        root = Path(translation_utils.SCRIPT_DIR)
        device = {item[0]: item[2] for item in translation_utils.extract_from_file(
            str(root / "modules/settings/sections/about_settings.lua"),
        )}
        goals = {item[0]: item[2] for item in translation_utils.extract_from_file(
            str(root / "common/reading_goals.lua"),
        )}
        self.assertIn("total device storage", device["Storage"])
        self.assertIn("remaining, used, and total", device["Storage"])
        self.assertIn("pages read, books finished, or reading minutes per year", goals["Yearly"])

    def test_shared_contexts_are_deduplicated_and_bounded(self):
        sources = [(path, i, context, "label") for i, (path, context) in enumerate([
            ("app_launcher.lua", "Label in the Launcher panel."),
            ("app_launcher.lua", "Label in the Launcher panel."),
            ("reader_footer.lua", "Label in the reading screen."),
            ("context_menu.lua", "Label in the book library."),
            ("quickstart_pages.lua", "Label in the setup guide."),
        ], start=1)]
        entry = translation_utils.format_entry("Shared", sources=sources)
        self.assertEqual(1, entry.count("Label in the Launcher panel."))
        self.assertIn("Label in the reading screen.", entry)
        self.assertIn("Label in the book library.", entry)
        self.assertIn("Also used elsewhere in ZenOS.", entry)
        self.assertNotIn("Label in the setup guide.", entry)

    def test_translator_note_takes_priority_over_code_context(self):
        path = "modules/settings/sections/about_settings.lua"
        note = "Settings menu showing total device storage and storage usage details."
        sources = [
            (path, 1, 'title = _("Storage")', "title"),
            (path, 2, note, "setting"),
        ]
        entry = translation_utils.format_entry("Storage", sources=sources)
        self.assertIn("#. Context: " + note, entry)
        self.assertNotIn('title = _("Storage")', entry)

    def test_rewrite_preserves_human_context_for_multiline_msgids_and_refreshes_refs(self):
        with tempfile.TemporaryDirectory() as tmp:
            po_path = Path(tmp) / "hu.po"
            note = "Settings menu showing total device storage and storage usage details."
            po_path.write_text(
                'msgid ""\nmsgstr ""\n"Language: hu\\n"\n\n'
                f'#. Context: {note}\n#: old.lua:1\n'
                'msgid ""\n"Sto"\n"rage"\nmsgstr "Tárhely"\n',
                encoding="utf-8",
            )
            sources = {"Storage": [("about_settings.lua", 76, "A different source note.", "setting")]}
            translation_utils.rewrite_po(
                str(po_path), translation_utils.parse_po(str(po_path)), sources,
                [], remove_dead=False, alphabetize=True,
            )
            first = po_path.read_text(encoding="utf-8")
            self.assertIn("#. Context: " + note, first)
            self.assertIn("#: about_settings.lua:76", first)
            self.assertNotIn("A different source note.", first)
            self.assertNotIn("old.lua:1", first)
            self.assertEqual({"Storage": "Tárhely"}, translation_utils.parse_po(str(po_path)))
            sources["Storage"][0] = ("about_settings.lua", 100, 'text = _("Storage")', "setting")
            translation_utils.rewrite_po(
                str(po_path), translation_utils.parse_po(str(po_path)), sources,
                [], remove_dead=False,
            )
            self.assertEqual({"Storage": note}, translation_utils.read_po_contexts(str(po_path)))
            self.assertIn("#: about_settings.lua:100", po_path.read_text(encoding="utf-8"))

    def test_missing_blank_and_legacy_contexts_use_current_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            po_path = Path(tmp) / "hu.po"
            po_path.write_text(
                'msgid ""\nmsgstr ""\n"Language: hu\\n"\n\n'
                '#. Context: text = _("Legacy")\nmsgid "Legacy"\nmsgstr "Régi"\n\n'
                '#. Context:    \nmsgid "Blank"\nmsgstr "Üres"\n\n'
                'msgid "Missing"\nmsgstr "Hiányzó"\n',
                encoding="utf-8",
            )
            self.assertEqual({}, translation_utils.read_po_contexts(str(po_path)))
            self.assertEqual({}, translation_utils.read_po_contexts(str(Path(tmp) / "en.po")))
            sources = {name: [("new.lua", 20, f'return _("{name}")', "label")]
                       for name in ("Legacy", "Blank", "Missing")}
            translation_utils.rewrite_po(
                str(po_path), translation_utils.parse_po(str(po_path)), sources,
                [], remove_dead=False,
            )
            content = po_path.read_text(encoding="utf-8")
            for name in sources:
                self.assertIn(f'#. Context: return _("{name}")', content)
            self.assertNotIn('Context: text = _("Legacy")', content)

    def test_locale_reuses_english_context_when_appending_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            note = "Settings and Home label for yearly reading goals."
            (root / "en.po").write_text(
                'msgid ""\nmsgstr ""\n"Language: en\\n"\n\n'
                + translation_utils.format_entry("Yearly", "Yearly", context=note),
                encoding="utf-8",
            )
            po_path = root / "hu.po"
            po_path.write_text('msgid ""\nmsgstr ""\n"Language: hu\\n"\n', encoding="utf-8")
            sources = {"Yearly": [("reading_goals.lua", 28, 'text = _("Yearly")', "label")]}
            with patch("sys.stdout", new=io.StringIO()):
                translation_utils.write_updated_po(str(po_path), {}, ["Yearly"], sources)
            self.assertEqual({"Yearly": note}, translation_utils.read_po_contexts(str(po_path)))
            self.assertEqual({"Yearly": ""}, translation_utils.parse_po(str(po_path)))
            self.assertIn("#: reading_goals.lua:28", po_path.read_text(encoding="utf-8"))

    def test_sync_preserves_descriptions_and_inherits_english_context_with_fresh_refs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            english_note = "Settings menu showing total device storage."
            local_note = "A készülék beállításaiban megjelenő tárhelykapacitás."
            yearly_note = "Settings label for pages, books, or reading time per year."
            for locale, storage, yearly in (("en", "Storage", "Yearly"), ("hu", "Tárhely", "Éves")):
                (root / f"{locale}.po").write_text(
                    f'msgid ""\nmsgstr ""\n"Language: {locale}\\n"\n\n'
                    + translation_utils.format_entry("Storage", storage,
                        context=english_note if locale == "en" else local_note) + "\n"
                    + translation_utils.format_entry("Yearly", yearly,
                        context=yearly_note if locale == "en" else 'text = _("Yearly")') + "\n"
                    + translation_utils.format_entry("Dead", "Dead", context="Old description."),
                    encoding="utf-8",
                )
            sources = {
                "Storage": [("about_settings.lua", 90, 'text = _("Storage")', "setting")],
                "Yearly": [("reading_goals.lua", 40, 'text = _("Yearly")', "label")],
                "New": [("menu.lua", 50, 'text = _("New")', "menu")],
            }
            with patch.object(translation_utils, "LOCALES_DIR", str(root)), \
                    patch.object(translation_utils, "translate_strings",
                        side_effect=lambda locale, labels: {label: label if locale == "en" else "Új" for label in labels}), \
                    patch("sys.stdout", new=io.StringIO()):
                translation_utils.sync_catalogs(["hu.po", "en.po"], sources)
            for locale, note in (("en", english_note), ("hu", local_note)):
                path = root / f"{locale}.po"
                self.assertEqual({"Storage": note, "Yearly": yearly_note},
                    translation_utils.read_po_contexts(str(path)))
                content = path.read_text(encoding="utf-8")
                self.assertIn("#: about_settings.lua:90", content)
                self.assertIn("#: reading_goals.lua:40", content)
                self.assertIn('#. Context: text = _("New")', content)
                self.assertNotIn('msgid "Dead"', content)
            self.assertEqual({"Storage": "Tárhely", "Yearly": "Éves", "New": "Új"},
                translation_utils.parse_po(str(root / "hu.po")))


if __name__ == "__main__":
    unittest.main()
