import json
import os
import tempfile
from pathlib import Path

import pytest

from zen_driver import ZenDriver, launch, stop, wait_for_socket
from test_emulator_reader_tools import _write_reader_epub, _wait_command

pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires real KOReader emulator"
)


@pytest.mark.parametrize("custom_icons", [False, True])
def test_reader_and_launcher_add_buttons_share_the_active_plus_icon(custom_icons):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-reader-add-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        _write_reader_epub(library / "reader.epub")
        pack = home / "icons" / "zen" / "add"
        pack.mkdir(parents=True)
        (pack / "pack.json").write_text(json.dumps({"schema_version": 1, "id": "add", "name": "Add"}))
        (pack / "plus.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">'
            '<path d="M3 12h18M12 3v18" stroke="#000" stroke-width="4"/></svg>'
        )
        settings = home / "settings" / "ZenOS"
        settings.mkdir(parents=True)
        (settings / "app_launcher.lua").write_text(
            'return {entries={{id="test",type="action",label="Test",action={}}}}\n'
        )
        config = ('return {features={custom_icons_enabled=' + str(custom_icons).lower()
                  + '},custom_icons={active_pack="add"},'
                  'reader_controls={buttons_initialized=true,annotations_merged=true,contrast_split=true,'
                  'entries={{id="reader_font",type="reader_control",control="font",label="Font",'
                  'icon="appbar.textsize"}}}}')
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library, zen_config_source=config)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.command("open_settings_page")["ok"]
            icons = []
            for path in [("Reader", "Reader controls", "Buttons"), ("Interface", "Launcher", "Buttons")]:
                while "Reader" not in driver.command("settings_page_state")["settings"]["labels"]:
                    assert driver.command("settings_page_back")["ok"]
                for label in path:
                    result = driver.command("settings_page_select", label=label)
                    assert result["ok"], result
                reader_buttons = {"Vocabulary builder", "Page Browser", "KOReader reader menu"}
                if path[0] == "Reader":
                    assert {"Font", *reader_buttons}.issubset(
                        driver.command("arrange_page_state")["arrange"]["labels"]
                    )
                icon = driver.command("arrange_page_state")["arrange"]["action_icon"]
                icons.append(icon)
                if custom_icons:
                    assert Path(icon).resolve() == (pack / "plus.svg").resolve()
                else:
                    assert icon.endswith("/plugins/zenos.koplugin/icons/plus.svg")
                assert driver.command("arrange_page_action")["ok"]
                assert {"Action", "Control", "Plugin Menu", "KOReader menu"}.issubset(
                    driver.command("arrange_page_state")["arrange"]["labels"]
                )
                if path[0] == "Reader":
                    assert reader_buttons.isdisjoint(driver.command("arrange_page_state")["arrange"]["labels"])
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("arrange_page_back")["ok"]
            assert icons[0] == icons[1]
        finally:
            stop(process)


@pytest.mark.parametrize("configured", [False, True])
def test_reader_settings_hierarchy_icons_and_bottom_swipe(configured):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-reader-settings-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "reader.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        config = """return {
            reader_bottom_swipe = { entries = {{ id = 'swipe_1', type = 'quick_setting',
                label = 'Settings', quick_setting_id = 'zen_settings' }}, next_id = 1 },
        }""" if configured else None
        process = launch(runtime, home, socket, library, zen_config_source=config)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))

            def state():
                return driver.command("settings_page_state")["settings"]

            def select(label, **params):
                result = driver.command("settings_page_select", label=label, **params)
                assert result["ok"], result

            def open_reader():
                assert driver.command("open_settings_page")["ok"]
                while "Reader" not in state()["labels"]:
                    assert driver.command("settings_page_back")["ok"]
                select("Reader")

            open_reader()
            assert state()["labels"] == ["Appearance", "Highlight / Lookup",
                                          "Bottom swipe gesture", "Page Browser", "Table of contents",
                                          "Footnotes and pinned pages", "Annotation viewer",
                                          "Restore library location on exit", "Reader controls", "End of book"]
            assert [item.get("icon_glyph") for item in state()["items"]] == [
                "\uead7", "\uea48", "\uee3e",
                "\uec6b", None, None, None, "\ue76e", "\ue7bd", "\ue7c0",
            ]
            select("Reader controls")
            assert state()["labels"] == ["Buttons"]
            assert driver.command("settings_page_back")["ok"]
            select("Appearance")
            assert state()["labels"] == ["Top status bar", "Bottom status bar", "Align status bars with book margins",
                                          "Reader themes", "Flash on every CBZ page turn"]
            driver.screenshot(Path(__file__).resolve().parents[2] / ".artifacts/reader-appearance.png")
            select("Bottom status bar")
            select("Status bar items")
            chapter = next(label for label in state()["labels"] if label.startswith("Time left to finish chapter"))
            select(chapter)
            assert state()["labels"] == ["Time until chapter end"]
            select("Time until chapter end")
            assert state()["labels"] == ["5 min left in chapter", "5 min left", "5m", "hh:mm"]
            assert all(item["radio"] for item in state()["items"])
            assert driver.command("close_settings_page")["ok"]
            open_reader()
            select("Bottom swipe gesture")
            assert state()["labels"] == ["KOReader reader menu", "Reader controls", "Zen page browser", "None", "Custom"]
            assert all(item["radio"] for item in state()["items"])
            select("None")
            assert [item["checked"] for item in state()["items"]] == [False, False, False, True, False]
            assert driver.command("close_settings_page")["ok"]
            assert not driver.command("activate_reader_control", name="page_browser")["activated"]
            open_reader()
            select("Bottom swipe gesture")
            select("Reader controls")
            assert [item["checked"] for item in state()["items"]] == [False, True, False, False, False]
            assert driver.command("close_settings_page")["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            controls = _wait_command(driver, "reader_controls", lambda result: result.get("menu_open"))
            assert controls["active_tab"] == "reader_controls"
            assert controls["menu_bottom"] == controls["screen_height"]
            driver.command("reader_controls", action="close")
            open_reader()
            select("Bottom swipe gesture")
            select("None")
            select("Custom", control=not configured)
            assert state()["title"] == "Bottom swipe gesture"
            assert driver.command("zen_settings_stack_state")["arrange_count"] == 0
            assert state()["labels"] == [
                "Action", "Control", "Plugin Menu", "KOReader menu",
            ]
            select("Action")
            assert state()["title"] == "Bottom swipe gesture"
            assert len(state()["labels"]) == 2
            assert state()["labels"][0].startswith("Action:")
            assert state()["labels"][1] == "Delete"
            assert driver.command("settings_page_back")["ok"]
            assert state()["labels"] == ["Action", "Control", "Plugin Menu", "KOReader menu"]
            assert driver.command("settings_page_back")["ok"]
            assert state()["title"] == "Bottom swipe gesture"
            assert state()["labels"] == ["KOReader reader menu", "Reader controls", "Zen page browser", "None", "Custom"]
            assert [item["checked"] for item in state()["items"]] == [False, False, False, True, False]
            assert driver.command("close_settings_page")["ok"]
            assert not driver.command("activate_reader_control", name="page_browser")["activated"]
            open_reader()
            select("Bottom swipe gesture")
            select("Custom", control=True)
            select("Action")
            select(state()["labels"][0])
            select("Reader")
            select("Page browser")
            for _level in range(4):
                assert driver.command("settings_page_back")["ok"]
            assert state()["labels"] == ["KOReader reader menu", "Reader controls", "Zen page browser", "None", "Custom"]
            assert [item["checked"] for item in state()["items"]] == [False, False, False, False, True]
            assert driver.command("close_settings_page")["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            browser = _wait_command(driver, "page_browser_state",
                                    lambda result: result.get("page_browser", {}).get("layout") == "carousel")
            assert browser["page_browser"]["header_icons"] == [
                "more_vertical.svg", "view_carousel_outline.svg", "font.svg", "bookmark_outline.svg",
                "lookup_highlight.svg", "toc.svg", "close.svg",
            ]
        finally:
            stop(process)
