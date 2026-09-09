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
        back = [("modules/menu/patches/app_launcher.lua", 1, 'id = "__back", label = _("Back")', "button")]
        settings = [
            ("modules/menu/app_launcher/native_menu.lua", 1, 'setting = _("Settings")', "menu"),
            ("modules/settings/zen_settings_page.lua", 2, 'title = _("Settings")', "title"),
        ]
        self.assertTrue(translation_utils.format_entry("Back", sources=back).startswith("#. Type: button\n"))
        settings_entry = translation_utils.format_entry("Settings", sources=settings)
        self.assertTrue(settings_entry.startswith("#. Type: title\n"))
        self.assertIn('#. Context: title = _("Settings")', settings_entry)
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


if __name__ == "__main__":
    unittest.main()
