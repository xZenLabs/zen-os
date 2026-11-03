import math
import os
import tempfile
import time
from pathlib import Path

import pytest

from zen_driver import ZenDriver, launch, stop, wait_for_socket
from test_emulator_reader_tools import _write_reader_epub, _wait_command

pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires real KOReader emulator"
)


def _enable_reader_tabs(driver, labels, disable=()):
    driver.command("reader_controls", action="edit_buttons")
    arrange = driver.command("arrange_page_state")["arrange"]
    for label in [*disable, *labels]:
        index = arrange["labels"].index(label) + 1
        page = (index - 1) // arrange["items_per_page"] + 1
        assert driver.command("arrange_page_go_to", page=page)["ok"]
        assert driver.command("arrange_page_select", index=index, toggle=True)["ok"]
    assert driver.command("close_arrange_page")["ok"]


@pytest.mark.parametrize("custom_icons,night", [(False, False), (True, False), (True, True)])
def test_standalone_reader_modals_have_no_leading_icon_or_focus_target(custom_icons, night):
    from PIL import Image

    with tempfile.TemporaryDirectory(prefix="zen-toc-focus-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "toc.epub"
        _write_reader_epub(book)
        pack = home / "icons" / "zen" / "toc"
        pack.mkdir(parents=True)
        (pack / "pack.json").write_text('{"schema_version":1,"id":"toc","name":"TOC"}')
        (pack / "chevron.left.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">'
            '<path d="M15 5L8 12l7 7" fill="none" stroke="black" stroke-width="2"/></svg>'
        )
        (home / "settings.reader.lua").write_text(
            'return {home_dir=' + repr(str(library.resolve())) + ',night_mode=' + str(night).lower() + '}')
        config = home / "settings" / "ZenOS"
        config.mkdir(parents=True)
        (config / "config.lua").write_text(
            'return {updater={update_auto_check=false},features={custom_icons_enabled='
            + str(custom_icons).lower() + '},custom_icons={active_pack="toc"}}')
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library, initialize_settings=False)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            output = Path(__file__).resolve().parents[2] / ".artifacts" / "toc-focus"
            output.mkdir(parents=True, exist_ok=True)
            name = f"{'pack' if custom_icons else 'stock'}-{'night' if night else 'day'}"
            for kind in ("toc", "bookmarks", "book_info"):
                assert driver.command("reader_controls", action=kind)["ok"]
                state = _wait_command(driver, "hardware_overlay_state",
                                      lambda result: result.get("overlay", {}).get("kind") == kind)["overlay"]
                assert state["show_back"] is False and state["focused"] == "close"
                bounds = state["leading_bounds"]
                area = (bounds["x"], bounds["y"], bounds["x"] + bounds["w"], bounds["y"] + bounds["h"])
                path = output / f"{kind}-{name}-no-leading-icon.png"
                driver.screenshot(path)
                low, high = Image.open(path).convert("L").crop(area).getextrema()
                assert low == high
                assert driver.command("hardware_overlay_key", key="Return")["handled"]
                assert not driver.command("hardware_overlay_state").get("overlay")
                assert driver.command("reader_controls", action=kind)["ok"]
                for key in ("Left", "Down", "Up", "Left"):
                    driver.command("hardware_overlay_key", key=key)
                    assert driver.command("hardware_overlay_state")["overlay"]["focused"] != "back"
                assert driver.command("hardware_overlay_key", key="Back")["handled"]
                assert not driver.command("hardware_overlay_state").get("overlay")
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert driver.command("annotation_viewer_action", action="seed")["ok"]
            assert driver.command("annotation_viewer_action", action="tab", tab="bookmarks")["ok"]
            assert driver.command("annotation_viewer_action", action="details")["ok"]
            details = driver.command("page_browser_state")["page_browser"]
            assert details["annotation_left_icon"] is False
            assert details["annotation_empty_focus_row"] is False
            assert driver.command("annotation_viewer_action", action="close_details")["ok"]
        finally:
            stop(process)


def test_book_switcher_reader_surfaces_and_dispatch():
    with tempfile.TemporaryDirectory(prefix="zen-reader-switcher-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        first, second = library / "first.epub", library / "second.epub"
        for book in (first, second):
            _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(first)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            assert driver.command("annotation_viewer_action", action="open", file=str(second.resolve()))["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(second.resolve()))
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id="book_switcher")
            state = driver.command("reader_controls", action="paint")
            assert state["section"] == "book_switcher"
            assert state["switcher_books"] == [str(first.resolve())]
            driver.command("reader_controls", action="choose", id=str(first.resolve()))
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(first.resolve()))
            assert driver.command("reader_controls")["menu_open"] is False

            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            state = driver.command("page_browser_state")["page_browser"]
            assert "history.svg" not in state["header_icons"]
            assert driver.command("annotation_viewer_action", action="close")["ok"]
            assert driver.command("annotation_viewer_action", action="dispatch", name="zen_ui_show_book_switcher")["ok"]
            state = driver.command("page_browser_state")["page_browser"]
            assert state["active_tab"] == "book_switcher" and state["top_is_browser"]
            assert "history.svg" in state["header_icons"]
            assert [book["path"] for book in state["switcher_books"]] == [str(second.resolve())]
            for book in state["switcher_books"]:
                bounds = book["bounds"]
                assert bounds["y"] >= state["header_height"]
                assert bounds["y"] + bounds["h"] <= state["screen_height"] - state["edge_padding"]
            screenshot = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser" / "book-switcher.png"
            screenshot.parent.mkdir(parents=True, exist_ok=True)
            driver.screenshot(screenshot)
            assert driver.command("activate_reader_control", name="page_browser_pages")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_book_switcher")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_switch_book")["activated"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(second.resolve()))
            assert driver.command("page_browser_state")["ok"] is False
        finally:
            stop(process)


@pytest.mark.parametrize("count,chevrons,rtl", [(1, False, False), (7, False, False),
                                              (12, False, False), (12, True, False), (7, False, True)])
def test_reader_control_tabs_evenly_fill_each_page(count, chevrons, rtl):
    with tempfile.TemporaryDirectory(prefix="zen-even-reader-tabs-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        entries = ['{id="reader_font",type="reader_control",control="font",label="Font",icon="appbar.textsize"}']
        entries.extend(f'{{id="extra_{i}",type="action",label="Extra {i}",icon="lightning",action={{}}}}'
                       for i in range(1, count - 1))
        if count > 1:
            entries.append('{id="reader_page",type="reader_control",control="page",label="Page",icon="appbar.pageview"}')
        config = ('return {reader_controls={buttons_initialized=true,annotations_merged=true,'
                  'contrast_split=true,menu_buttons_added=true,book_switcher_added=true,show_page_chevrons='
                  + str(chevrons).lower() + ',entries={' + ','.join(entries) + '}}}')
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library,
                         language="ar" if rtl else "en", zen_config_source=config)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            driver.command("reader_controls", action="open")
            state = driver.command("reader_controls", action="paint")
            pages = state["button_pages"]
            visible = set()
            for page in range(pages):
                visible.update(entry["id"] for entry in state["header"])
                tabs = sorted(state["reader_tab_bounds"], key=lambda tab: tab["x"])
                assert tabs[0]["x"] == 0
                assert tabs[-1]["x"] + tabs[-1]["w"] == state["screen_width"]
                assert max(tab["w"] for tab in tabs) - min(tab["w"] for tab in tabs) <= 1
                gaps = [right["x"] - left["x"] - left["w"] for left, right in zip(tabs, tabs[1:])]
                assert not gaps or max(gaps) - min(gaps) <= 1
                active = next((tab for tab in state["header"] if tab["id"] == state["section"]), None)
                if active:
                    gap = state["reader_tab_gap"][0]
                    assert gap["s"] == active["x"] and gap["e"] == active["x"] + active["w"]
                else:
                    assert not state.get("reader_tab_gap")
                if page + 1 < pages:
                    driver.command("reader_controls", action="buttons_next")
                    state = driver.command("reader_controls", action="paint")
            assert len(visible) == min(count, 8)
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            selected = "page" if 1 < count <= 8 else "font"
            driver.command("reader_controls", action="choose", id=selected, tap=True)
            state = driver.command("reader_controls", action="paint")
            assert state["section"] == selected
            active = next(tab for tab in state["header"] if tab["id"] == state["section"])
            gap = state["reader_tab_gap"][0]
            assert gap["s"] == active["x"] and gap["e"] == active["x"] + active["w"]
            output = Path(__file__).resolve().parents[2] / ".artifacts" / "reader-controls"
            output.mkdir(parents=True, exist_ok=True)
            driver.screenshot(output / f"even-tabs-{count}-{chevrons}-{rtl}.png")
        finally:
            stop(process)


def test_reader_controls_bottom_tabs_and_swipe():
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library,
                         zen_config_source="return {quick_settings={background_hatching=true}}")
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            driver.command("reader_controls", action="bottom_swipe")
            assert driver.command("reader_controls")["section"] == "book_info"
            driver.command("reader_controls", action="choose", id="font")
            state = driver.command("reader_controls", action="paint")
            assert state["active_tab"] == "reader_controls"
            assert "reader_controls" not in state["tabs"]
            assert state["hatched_background"] is False
            assert state["menu_bottom"] == state["screen_height"]
            assert state["menu_top"] > 0
            assert state["reader_status_row"] is False
            assert state["footer_visible"] is False
            assert state["native_reader_tabs"] and state["reader_tab_line_on_top"]
            assert len(state["reader_tab_gap"]) == 1
            assert min(tab["y"] for tab in state["header"]) > state["bounds"]["font_size"]["y"]
            assert len({tab["h"] for tab in state["header"]}) == 1
            assert state["header"][0]["h"] < (state["screen_height"] - state["menu_top"]) / 2
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            driver.command("reader_controls", action="choose", id="page", tap=True)
            state = driver.command("reader_controls", action="paint")
            assert state["section"] == "page"
            assert state["reader_tab_separators"].count("solid") == 2
            assert state["menu_bottom"] == state["screen_height"]
            assert min(tab["y"] for tab in state["header"]) > max(slider["y"] for slider in state["slider_bounds"].values())
            driver.screenshot(Path("/tmp/zen-reader-bottom-tabs.png"))
            driver.command("reader_controls", action="key", key="Back")
            assert driver.command("reader_controls")["menu_open"] is False
            state = driver.command("reader_controls", action="swipe_open")
            assert state["menu_open"] and state["active_tab"] != "reader_controls"
            top_tab = state["active_tab"]
            driver.command("reader_controls", action="open")
            state = driver.command("reader_controls", action="resize")
            assert state["active_tab"] == "reader_controls"
            assert state["hatched_background"] is False
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            driver.command("reader_controls", action="swipe", direction="south")
            assert driver.command("reader_controls")["menu_open"] is False
            assert driver.command("reader_controls", action="swipe_open")["active_tab"] == top_tab
        finally:
            stop(process)


@pytest.mark.parametrize("extension", ["epub", "pdf", "cbz"])
def test_reader_controls_paginate_three_settings_with_the_shared_pager(extension):
    from fixtures import build_library

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / f"controls.{extension}"
        if extension == "epub":
            _write_reader_epub(book)
        elif extension == "pdf":
            _write_pdf(book)
        else:
            book = Path(build_library(library)["cbz"])
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            driver.command("reader_controls", action="open")
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            sections = ["font", "page"] if extension == "epub" else ["contrast", "page", "document"]
            for section in sections:
                first = driver.command("reader_controls", action="choose", id=section)
                assert first["section"] == section and first["page"] == 1
                for page in range(1, first["page_num"] + 1):
                    state = driver.command("reader_controls", action="paint")
                    assert state["page"] == page
                    assert "Advanced" not in state["controls"]
                    assert 1 <= state["settings_rows"] <= 3
                    if page < first["page_num"]:
                        assert state["settings_rows"] == 3
                    assert state["menu_bottom"] == state["screen_height"]
                    assert state["menu_top"] > 0
                    assert state["config"] == first["config"]
                    if first["page_num"] > 1:
                        assert len(state["pager_buttons"]) == 2
                        assert state["pager"]["y"] < min(tab["y"] for tab in state["header"])
                        driver.command("reader_controls", action="pager")
                    else:
                        assert not state.get("pager") and not state["pager_buttons"]
                if first["page_num"] > 1:
                    assert driver.command("reader_controls")["page"] == 1
                    driver.command("reader_controls", action="pager", direction="previous")
                    assert driver.command("reader_controls")["page"] == first["page_num"]
                    driver.command("reader_controls", action="swipe", zone="settings")
                    assert driver.command("reader_controls")["page"] == 1
                    driver.command("reader_controls", action="swipe", zone="settings", direction="east")
                    assert driver.command("reader_controls")["page"] == first["page_num"]
            driver.command("reader_controls", action="choose", id=sections[0])
            driver.command("reader_controls", action="paint")
            driver.screenshot(Path(f"/tmp/zen-reader-paginated-{extension}.png"))
        finally:
            stop(process)


def test_page_browser_aa_embeds_zen_controls():
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library,
                         zen_config_source='return {features={page_browser=true},'
                                           'reader_bottom_swipe={mode="page_browser"},'
                                           'quick_settings={background_hatching=true}}')
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            _wait_command(driver, "page_browser_state", lambda result: result.get("page_browser", {}).get("layout"))
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            state = driver.command("reader_controls", action="paint")
            assert state["active_tab"] == "aa"
            assert "reader_controls" not in state["tabs"]
            assert state["menu_open"] is False
            assert "font_size" in state["controls"]
            assert state["font_face"] in state["font_family_label"]
            assert state["menu_top"] > 0
            assert state["menu_bottom"] <= state["screen_height"]
            assert state["hatched_background"] is False
            assert driver.command("page_browser_state")["page_browser"]["active_tab"] == "aa"
            assert driver.command("reader_overlay_state")["overlays"]["aa_menu"] is False
            assert state["zen_buttons"]["font_face"] and state["outlined"]["font_face"]
            assert state["font_family_label"] == state["font_face"]
            assert state["font_family_radius"] == state["section_tab_radius"]
            assert state["icons"]["font_face_more_height"] == state["icons"]["font_size_more_height"]
            assert state["bounds"]["font_face_more"]["w"] == state["bounds"]["font_size_more"]["w"]
            assert state["bounds"]["font_face_more"]["h"] == state["bounds"]["font_size_more"]["h"]
            driver.screenshot(Path("/tmp/zen-page-browser-font-family-button.png"))
            original_face = state["font_face"]
            driver.command("reader_controls", action="choose", id="font_face_more", tap=True)
            popup = driver.command("reader_controls", action="setting_menu")
            assert popup["buttons"] == ["Set as default", "Reset"]
            assert popup["anchor"] == state["bounds"]["font_face_more"]
            driver.command("reader_controls", action="setting_menu", button="Set as default")
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            assert driver.command("native_settings_confirm", accept=True)["ok"]
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            driver.command("reader_controls", action="choose_font", index=1)
            driver.command("reader_controls", action="choose", id="font_face_more")
            driver.command("reader_controls", action="setting_menu", button="Reset")
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            assert driver.command("reader_controls")["font_face"] == original_face
            state = driver.command("reader_controls", action="choose", id="font_size_increase")
            driver.command("reader_controls", action="choose", id="font_size_more", tap=True)
            popup = driver.command("reader_controls", action="setting_menu")
            assert popup["buttons"] == ["Set as default", "Reset"]
            assert not popup["scrollable"]
            assert popup["positions"]["Set as default"]["y"] < popup["positions"]["Reset"]["y"]
            assert popup["anchor"] == driver.command("reader_controls")["bounds"]["font_size_more"]
            assert state["config"]["font_size"] == popup["value"]
            assert popup["bounds"]["x"] >= 8
            assert popup["bounds"]["y"] + popup["bounds"]["h"] <= state["screen_height"] - 8
            driver.screenshot(Path("/tmp/zen-page-browser-setting-menu.png"))
            driver.command("reader_controls", action="setting_menu", close=True)
        finally:
            stop(process)


def test_reader_controls_native_settings_defaults_profiles_and_direct_actions():
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            _enable_reader_tabs(driver, ["Vocabulary builder"], disable=["Book switcher"])
            state = driver.command("reader_controls", action="open")
            assert state["ok"], state
            assert state["section"] == "book_info"
            assert state["header"][0]["id"] == "book_info"
            assert not {"toc", "bookmarks", "search"} & {entry["id"] for entry in state["header"]}
            assert state["card_actions"] == ["search", "bookmarks", "toc"]
            state = driver.command("reader_controls", action="choose", id="font")
            assert state["section"] == "font"
            assert "reader_controls" not in state["tabs"]
            driver.screenshot(Path("/tmp/zen-reader-controls-font.png"))
            assert state["active_tab"] == "reader_controls"
            assert state["button_pages"] >= 1
            assert len({entry["y"] for entry in state["header"]}) == 1
            assert len(state["header"]) <= 8
            assert state["page_chevrons"] is False
            assert "previous" not in state["bounds"] and "next" not in state["bounds"]
            assert state["font_face"] in state["font_family_label"]
            first_ids = [entry["id"] for entry in state["header"]]
            second = driver.command("reader_controls", action="buttons_next")
            if state["button_pages"] > 1:
                assert second["button_page"] == 2
                assert first_ids != [entry["id"] for entry in second["header"]]
            driver.command("reader_controls", action="buttons_next")
            assert "Advanced" not in state["controls"]
            original = state["config"]["font_size"]
            driver.command("reader_controls", action="key", key="Right")
            assert driver.command("reader_controls")["config"]["font_size"] == original
            driver.command("reader_controls", action="focus_slider")
            driver.command("reader_controls", action="key", key="Right")
            assert driver.command("reader_controls")["config"]["font_size"] > original
            assert driver.command("reader_controls", action="slider")["ok"]
            state = _wait_command(driver, "reader_controls", lambda result: result["config"]["font_size"] != original)
            size = state["config"]["font_size"]
            margins = state.get("default_margins")
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            driver.command("reader_controls", action="choose", id="font_size", hold=True)
            assert not driver.command("native_settings_confirm", accept=False)["ok"]
            assert driver.command("reader_controls").get("default_size") != size
            driver.command("reader_controls", action="choose", id="font_size_more")
            picker = driver.command("reader_controls", action="setting_menu")
            assert "Apply" not in picker["buttons"] and "Close" not in picker["buttons"]
            assert "Set as default" in picker["buttons"]
            driver.command("reader_controls", action="setting_menu", button="Set as default")
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            assert driver.command("native_settings_confirm", accept=True)["ok"]
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            state = driver.command("reader_controls")
            assert state["default_size"] == size
            assert state.get("default_margins") == margins
            driver.command("reader_controls", action="choose", id="page")
            state = driver.command("reader_controls")
            assert state["section"] == "page"
            assert "table:" not in state["labels"]["h_page_margins"]
            assert state["labels"]["h_page_margins"].startswith("Left/Right:")
            assert "sync_t_b_page_margins" not in state["controls"]
            assert state["config"]["sync_t_b_page_margins"] == 1
            for synced in (0, 1):
                driver.command("reader_controls", action="choose", id="t_page_margin_more")
                driver.command("reader_controls", action="setting_menu", button="Sync")
                assert not driver.command("reader_controls", action="setting_menu")["ok"]
                state = driver.command("reader_controls")
                assert state["config"]["sync_t_b_page_margins"] == synced
                assert "t_page_margin" in state["controls"]
                assert ("b_page_margin" in state["controls"]) is not bool(synced)
            assert state["labels"]["t_page_margin"].startswith("Top/Bottom:")
            driver.command("reader_controls", action="slider", index=2)
            state = driver.command("reader_controls")
            assert state["config"]["t_page_margin"] == state["config"]["b_page_margin"]
            driver.command("reader_controls", action="close")
            theme = {"enabled": True, "light_mode": {"text": "#302818", "background": "#eee0bf"},
                     "dark_mode": {"text": "#dddddd", "background": "#222222"}}
            assert driver.command("reader_controls", action="theme", theme=theme)["ok"]
            captured = driver.command("reader_controls", action="capture", name="Reader test")
            assert captured["profile"]["settings"]["zen_reader"]["theme"] == theme
            assert "last_xpointer" not in captured["profile"]["settings"]["zen_reader"]["book"]
            driver.command("reader_controls", action="setting", name="font_size", value=size + 4)
            driver.command("reader_controls", action="theme", theme={"enabled": False})
            assert driver.command("reader_controls")["config"]["font_size"] != size
            assert driver.command("reader_controls", action="apply_profile", name="Reader test")["ok"]
            state = driver.command("reader_controls")
            assert state["config"]["font_size"] == size
            assert state["theme"] == theme
            other = library / "other.epub"
            _write_reader_epub(other)
            assert driver.command("reader_controls", action="switch_book", path=str(other.resolve()))["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(other.resolve()))
            assert driver.command("reader_controls")["theme"] == theme
            assert driver.command("reader_controls")["config"]["font_size"] == size
            driver.command("reader_controls", action="setting", name="font_size", value=size + 2)
            assert driver.command("reader_controls", action="switch_book", path=str(book.resolve()))["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(book.resolve()))
            assert driver.command("reader_controls")["config"]["font_size"] == size
            assert driver.command("reader_controls")["theme"] == theme
            for control, expected in [("toc", "toc"), ("search", "search")]:
                driver.command("reader_controls", action="open")
                driver.command("reader_controls", action="choose", id=control)
                overlay = _wait_command(driver, "hardware_overlay_state", lambda result: result.get("overlay", {}).get("kind") == expected)
                assert overlay["overlay"]["kind"] == expected
                if control == "toc":
                    assert overlay["overlay"]["show_back"] is False
                elif control == "search":
                    assert "Search" in overlay["overlay"]["title"]
                assert driver.command("hardware_overlay_key", key="Back")["handled"]
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id="bookmarks")
            viewer = _wait_command(driver, "annotation_viewer_state", lambda result: result.get("ok"))
            assert viewer["tab"] == "bookmarks"
            assert not driver.command("page_browser_state").get("page_browser", {}).get("top_is_browser")
            assert driver.command("reader_controls")["menu_open"] is False
            assert driver.command("annotation_viewer_action", action="close")["ok"]
            # Tapping the card opens only Book details, not the icon actions in it.
            driver.command("reader_controls", action="open")
            assert driver.command("reader_controls", action="real_tap", id="book_info_card", dx=40)["ok"]
            overlay = _wait_command(driver, "hardware_overlay_state",
                                    lambda result: result.get("overlay", {}).get("kind") == "book_info")["overlay"]
            assert overlay["kind"] == "book_info"
            assert driver.command("reader_controls", action="windows")["count"] == 2
            assert driver.command("hardware_overlay_key", key="Back")["handled"]
            driver.command("reader_controls", action="open")
            state = driver.command("reader_controls", action="paint")
            assert state["reader_status_row"] is False
            assert state["menu_open"] and state["section"] == "book_info"
            driver.screenshot(Path("/tmp/zen-reader-controls-book-info.png"))
            driver.command("reader_controls", action="choose", id="themes")
            state = driver.command("reader_controls")
            assert "Light tan" in state["controls"]
            driver.command("reader_controls", action="choose", id="Light tan")
            state = driver.command("reader_controls")
            assert state["theme"]["light_mode"]["background"] == "#e8dcc5"
            assert state["global_themes"]["light_mode"] == "light_tan"
            assert state["radios"]["Light tan"]
            assert state["hatched_background"] is False
            driver.command("reader_controls", action="paint")
            driver.command("reader_controls", action="close")
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id="themes")
            assert driver.command("reader_controls")["hatched_background"] is False
            driver.command("reader_controls", action="choose", id="Reader theme settings")
            assert driver.command("arrange_page_state")["ok"]
            assert driver.command("arrange_page_select", index=1, toggle=True)["ok"]
            assert driver.command("reader_controls")["hatched_background"] is False
            assert driver.command("close_arrange_page")["ok"]

            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id="vocabulary")
            _wait_command(driver, "reader_overlay_state",
                          lambda result: result.get("overlays", {}).get("vocabulary_builder"))
            assert driver.command("reader_controls")["menu_open"] is False

        finally:
            stop(process)


def test_reader_margin_pickers_native_pairs_and_defaults():
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            driver.command("reader_controls", action="open")
            state = driver.command("reader_controls", action="choose", id="page")
            original_size = state.get("default_size")
            for name in ["h_page_margins", "t_page_margin", "b_page_margin"]:
                current = state["config"]
                values = current[name] if name == "h_page_margins" else [
                    current["t_page_margin"], current["b_page_margin"]]
                saved = [values[0] + 1, values[1] + 2]
                driver.command("reader_controls", action="setting", name=name, value=saved)
                driver.command("reader_controls", action="choose", id=name + "_more")
                popup = driver.command("reader_controls", action="setting_menu")
                assert popup["buttons"] == (["Sync"] if name != "h_page_margins" else []) + [
                    "Set as default", "Reset"]
                assert not popup["scrollable"]
                assert [popup["left_value"], popup["right_value"]] == saved
                driver.command("reader_controls", action="setting_menu", button="Set as default")
                assert driver.command("native_settings_confirm", accept=False)["ok"]
                assert not driver.command("reader_controls", action="setting_menu")["ok"]
                driver.command("reader_controls", action="choose", id=name + "_more")
                driver.command("reader_controls", action="setting_menu", button="Set as default")
                assert driver.command("native_settings_confirm", accept=True)["ok"]
                assert not driver.command("reader_controls", action="setting_menu")["ok"]
                state = driver.command("reader_controls")
                assert state.get("default_size") == original_size
                if name == "h_page_margins":
                    assert state["default_margins"] == saved
                else:
                    assert [state["default_top"], state["default_bottom"]] == saved
                driver.command("reader_controls", action="setting", name=name,
                               value=[saved[0] + 1, saved[1] + 1])
                driver.command("reader_controls", action="choose", id=name + "_more")
                driver.command("reader_controls", action="setting_menu", button="Reset")
                assert not driver.command("reader_controls", action="setting_menu")["ok"]
                state = driver.command("reader_controls")
                current = state["config"]
                restored = current[name] if name == "h_page_margins" else [
                    current["t_page_margin"], current["b_page_margin"]]
                assert restored == saved
            driver.command("reader_controls", action="choose", id="t_page_margin_more")
            driver.command("reader_controls", action="setting_menu", button="Sync")
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            driver.command("reader_controls", action="choose", id="t_page_margin_more")
            popup = driver.command("reader_controls", action="setting_menu")
            assert not popup["paired"] and popup["positions"]["Sync"]["checked"]
            assert popup["positions"]["Reset"]["y"] > popup["positions"]["Set as default"]["y"]
            driver.command("reader_controls", action="setting_menu", close=True)
            state = driver.command("reader_controls", action="choose", id="t_page_margin_increase")
            value = state["config"]["t_page_margin"]
            assert state["config"]["b_page_margin"] == value
            assert state["config"]["sync_t_b_page_margins"] == 1
            driver.command("reader_controls", action="choose", id="t_page_margin_more")
            driver.command("reader_controls", action="setting_menu", button="Set as default")
            assert driver.command("native_settings_confirm", accept=True)["ok"]
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            state = driver.command("reader_controls")
            assert state["default_top"] == state["default_bottom"] == value
            driver.command("reader_controls", action="choose", id="t_page_margin_more")
            driver.command("reader_controls", action="setting_menu", button="Sync")
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            driver.command("reader_controls", action="choose", id="t_page_margin_more")
            popup = driver.command("reader_controls", action="setting_menu")
            assert popup["paired"] and not popup["positions"]["Sync"]["checked"]
            driver.command("reader_controls", action="setting_menu", close=True)
            assert driver.command("reader_controls")["config"]["sync_t_b_page_margins"] == 0
        finally:
            stop(process)


@pytest.mark.parametrize("control,label,swipe_mode", [
    ("page_browser", "Page Browser", "none"),
    ("koreader_menu", "KOReader reader menu", "none"),
    ("koreader_menu", "KOReader reader menu", "page_browser"),
])
def test_reader_optional_menu_buttons_work_without_changing_the_swipe_gesture(control, label, swipe_mode):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-reader-browser-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        config = ('return {reader_bottom_swipe={mode="' + swipe_mode
                  + '"},features={zen_mode=true,page_browser=false,reader_bottom_menu=false}}')
        process = launch(runtime, home, socket_path, library, zen_config_source=config)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            driver.command("reader_controls", action="open")
            state = driver.command("reader_controls", action="choose", id=control)
            assert not driver.command("reader_overlay_state")["overlays"]["page_browser"]
            assert not driver.command("reader_overlay_state")["overlays"]["aa_menu"]
            assert control not in [entry["id"] for entry in state["header"]]
            _enable_reader_tabs(driver, [], disable=["Book switcher"])
            driver.command("reader_controls", action="edit_buttons")
            editor = driver.command("arrange_page_state")["arrange"]
            index = editor["labels"].index(label) + 1
            assert editor["checked"][index - 1] is False
            assert driver.command("arrange_page_go_to", page=math.ceil(index / editor["items_per_page"]))["ok"]
            assert driver.command("arrange_page_select", index=index, toggle=True)["ok"]
            assert driver.command("arrange_page_state")["arrange"]["checked"][index - 1] is True
            assert driver.command("arrange_page_close_button")["ok"]
            driver.command("reader_controls", action="close")
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id=control)
            if control == "page_browser":
                browser = _wait_command(driver, "page_browser_state",
                                        lambda result: result.get("page_browser", {}).get("layout") == "carousel")
                assert browser["page_browser"]["header_icons"] == ["more_vertical.svg", "view_carousel_outline.svg", "font.svg", "bookmark_outline.svg",
                                                                   "lookup_highlight.svg", "toc.svg", "close.svg"]
                assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
                assert driver.command("page_browser_state")["page_browser"]["active_tab"] == "aa"
                assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
                assert driver.command("activate_reader_control", name="page_browser_reader_controls")["activated"]
                controls = _wait_command(driver, "reader_controls", lambda result: result.get("menu_open"))
                assert controls["active_tab"] == "reader_controls"
                assert controls["menu_bottom"] == controls["screen_height"]
                driver.command("reader_controls", action="close")
                driver.command("reader_controls", action="open")
                driver.command("reader_controls", action="choose", id="page_browser")
                assert driver.command("page_browser_key", key="Back")["handled"]
                assert not driver.command("activate_reader_control", name="page_browser")["activated"]
            else:
                overlay = _wait_command(driver, "reader_overlay_state",
                                        lambda result: result.get("overlays", {}).get("aa_menu"))
                assert overlay["overlays"]["page_browser"] is False
            assert driver.command("reader_controls")["menu_open"] is False
        finally:
            stop(process)


def _write_pdf(path, pages=1):
    page_ids = [3] + list(range(6, pages + 5))
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Kids [{' '.join(f'{page} 0 R' for page in page_ids)}] /Count {pages} >>".encode(),
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length 50 >>\nstream\nBT /F1 20 Tf 40 500 Td (Reader controls PDF) Tj ET\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    objects.extend([objects[2]] * (pages - 1))
    data, offsets = b"%PDF-1.4\n", [0]
    for number, content in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{number} 0 obj\n".encode() + content + b"\nendobj\n"
    start = len(data)
    data += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010} 00000 n \n".encode() for offset in offsets[1:])
    data += f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()
    path.write_bytes(data)


@pytest.mark.parametrize("extension", ["pdf", "cbz"])
@pytest.mark.parametrize("night_mode", [False, True])
def test_contrast_paginated_document_inversion(extension, night_mode):
    from fixtures import build_library

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        if extension == "cbz":
            book = Path(build_library(library)["cbz"])
        else:
            book = library / "controls.pdf"
            _write_pdf(book)
        (home / "settings.reader.lua").write_text(
            'return { home_dir = ' + repr(str(library.resolve()))
            + ', night_mode = ' + str(night_mode).lower() + ' }\n', encoding="utf-8",
        )
        config_dir = home / "settings" / "ZenOS"
        config_dir.mkdir(parents=True)
        (config_dir / "config.lua").write_text(
            'return { updater = { update_auto_check = false } }\n', encoding="utf-8",
        )
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library, initialize_settings=False)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            state = driver.command("reader_controls", action="open")
            assert state["section"] == "book_info"
            state = driver.command("reader_controls", action="choose", id="contrast")
            assert state["section"] == "contrast"
            assert "nightmode_document_1" not in state["controls"]
            state = driver.command("reader_controls", action="choose", id="nightmode_document_1")
            assert ("nightmode_document_1" in state["controls"]) is night_mode
            assert ("nightmode_document_2" in state["controls"]) is night_mode
            if night_mode:
                for index, value in [(2, 1), (1, 0)]:
                    driver.command("reader_controls", action="choose", id=f"nightmode_document_{index}")
                    state = driver.command("reader_controls", action="paint")
                    assert state["config"]["nightmode_document"] == value
                    assert state["selections"][f"nightmode_document_{index}"]
            driver.command("reader_controls", action="choose", id="contrast")
            assert "nightmode_document_1" not in driver.command("reader_controls")["controls"]
        finally:
            stop(process)


def _page_with(driver, control):
    state = driver.command("reader_controls", action="paint")
    for _page in range(state["page_num"]):
        if control in state["controls"]:
            return state
        driver.command("reader_controls", action="next_page")
        state = driver.command("reader_controls", action="paint")
    raise AssertionError(f"{control} not on any page")


@pytest.mark.parametrize("extension", ["pdf", "cbz"])
def test_fixed_layout_reader_controls(extension):
    from fixtures import build_library

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        if extension == "cbz":
            book = Path(build_library(library)["cbz"])
        else:
            book = library / "controls.pdf"
            _write_pdf(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            state = driver.command("reader_controls", action="open")
            assert state["section"] == "book_info"
            assert state["header"][0]["label"] == "Book info"
            header_ids = [entry["id"] for entry in state["header"]]
            for _page in range(1, state["button_pages"]):
                state = driver.command("reader_controls", action="buttons_next")
                header_ids.extend(entry["id"] for entry in state["header"])
            assert "themes" not in header_ids
            assert "font" not in header_ids and "contrast" in header_ids
            assert not {"toc", "bookmarks", "search", "highlights"} & set(header_ids)
            driver.command("reader_controls", action="buttons_next")
            driver.command("reader_controls", action="choose", id="page")
            driver.command("reader_controls", action="inject_rakuyomi_option")
            state = driver.command("reader_controls", action="paint")
            assert state["page"] == 1 and "page_margin" in state["controls"]
            assert "page_scroll_1" in state["controls"] and "rakuyomi_view_mode_1" in state["controls"]
            assert "trim_page_1" not in state["controls"] and "line_spacing" not in state["controls"]
            driver.command("reader_controls", action="choose", id="rakuyomi_view_mode_3")
            assert driver.command("reader_controls")["config"]["rakuyomi_view_mode"] == 2
            driver.command("reader_controls", action="choose", id="page_margin_increase")
            driver.command("reader_controls", action="choose", id="page_margin_more")
            picker = driver.command("reader_controls", action="setting_menu")
            assert picker["ok"] and not picker["paired"]
            assert "Apply" not in picker["buttons"] and "Close" not in picker["buttons"]
            driver.command("reader_controls", action="setting_menu", close=True)
            assert driver.command("reader_controls")["config"]["page_margin"] == picker["value"]
            state = driver.command("reader_controls", action="paint")
            assert "auto_straighten" not in state["controls"]
            for i, degrees in enumerate([0, 5, 10, 15, 25], 1):
                driver.command("reader_controls", action="choose", id=f"auto_straighten_{i}")
                assert driver.command("reader_controls")["config"]["auto_straighten"] == degrees
            driver.command("reader_controls", action="choose", id="auto_straighten_more")
            picker = driver.command("reader_controls", action="setting_menu")
            driver.command("reader_controls", action="setting_menu", button="Reset")
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            assert driver.command("reader_controls")["config"]["auto_straighten"] == picker["default_value"]
            driver.screenshot(Path(f"/tmp/zen-reader-page-advanced-{extension}.png"))
            state = driver.command("reader_controls", action="choose", id="contrast")
            assert "contrast" in state["controls"]
            assert "Advanced" not in state["controls"]
            assert next(entry for entry in state["header"] if entry["id"] == "contrast")["label"] == "Contrast"
            assert state["icons"]["contrast"].endswith("/appbar.contrast.svg")
            for name in ["white_threshold", "saturation"]:
                assert (name in state["controls"]) is state[name + "_available"]
                if state[name + "_available"]:
                    previous = state["config"][name]
                    if name == "white_threshold":
                        assert state["slider_states"][name]["value"] == 0
                        assert state["slider_states"][name]["default_value"] == 0
                    driver.command("reader_controls", action="choose", id=name + "_increase")
                    changed = driver.command("reader_controls")
                    current = changed["config"][name]
                    assert current < previous if name == "white_threshold" else current > previous
                    if name == "white_threshold":
                        assert current == previous - 1
            contrast = state["config"]["contrast"]
            driver.command("reader_controls", action="choose", id="contrast_increase")
            assert driver.command("reader_controls")["config"]["contrast"] > contrast
            driver.command("reader_controls", action="paint")
            driver.screenshot(Path(f"/tmp/zen-reader-font-{extension}.png"))
            if state["white_threshold_available"]:
                driver.command("reader_controls", action="choose", id="white_threshold_decrease")
            state = driver.command("reader_controls", action="paint")
            assert state["header"]
            assert not state.get("pager") and state["page_num"] == 1
            assert "page_opt_1" not in state["controls"]
            driver.command("reader_controls", action="choose", id="document")
            for option in state["color_options"]:
                if option["available"] and option["name"] in ("page_opt", "background_cleanup"):
                    for index, value in enumerate(option["values"], 1):
                        name = option["name"] + "_" + str(index)
                        state = driver.command("reader_controls", action="choose", id=name)
                        assert name in state["controls"]
                        assert driver.command("reader_controls")["config"][option["name"]] == value
            driver.command("reader_controls", action="paint")
            driver.screenshot(Path(f"/tmp/zen-reader-color-advanced-{extension}.png"))
            driver.command("reader_controls", action="choose", id="contrast")
            driver.command("reader_controls", action="inject_color_option")
            state = driver.command("reader_controls", action="paint")
            start, end = state["step_styles"]["contrast_decrease"], state["step_styles"]["contrast_increase"]
            driver.command("reader_controls", action="choose", id="zen_test_color_3")
            state = driver.command("reader_controls", action="paint")
            assert state["config"]["zen_test_color"] == 8
            assert state["selections"]["zen_test_color_3"]
            tabs = [state["bounds"][f"zen_test_color_{index}"] for index in range(1, 4)]
            scale = min(state["screen_width"], state["screen_height"]) / 600
            inset = math.ceil(2 * scale)
            assert tabs[0]["x"] - inset == start["glyph_x"]
            assert tabs[-1]["x"] + tabs[-1]["w"] + inset == end["glyph_x"] + end["glyph_w"]
            for name in ["hw_dithering", "sw_dithering"]:
                driver.command("reader_controls", action="dithering_option", name=name)
                for index, enabled in [(2, True), (1, False)]:
                    driver.command("reader_controls", action="choose", id=f"{name}_{index}")
                    state = driver.command("reader_controls")
                    assert state["config"][name] == int(enabled)
                    assert state["document_dithering"][name] is enabled
            state = driver.command("reader_controls", action="choose", id="document")
            assert state["section"] == "document"
            controls = []
            for page in range(state["page_num"]):
                state = driver.command("reader_controls")
                controls.extend(state["controls"])
                driver.command("reader_controls", action="next_page")
            assert "zoom_mode_genus_1" in controls
            driver.command("reader_controls", action="choose", id="zoom_mode_genus_2")
            assert driver.command("reader_controls")["config"]["zoom_mode_genus"] == 3
            driver.command("reader_controls", action="choose", id="zoom_mode_type_3")
            assert driver.command("reader_controls")["config"]["zoom_mode_type"] == 0
            state = driver.command("reader_controls", action="paint")
            assert state["bounds"]["zoom_mode_genus_1"]["h"] == math.ceil(48 * scale)
            assert state["icons"]["zoom_mode_genus_1_height"] == math.ceil(32 * scale)
            assert "trim_page_1" in state["controls"]
            driver.command("reader_controls", action="choose", id="trim_page_2")
            assert driver.command("reader_controls")["config"]["trim_page"] == 1
            driver.command("reader_controls", action="choose", id="trim_page_1")
            assert driver.command("reader_controls")["config"]["trim_page"] == 3
            driver.command("reader_controls", action="choose", id="zoom_mode_genus_3")
            state = _page_with(driver, "zoom_direction_1")
            assert state["config"]["zoom_mode_genus"] == 2
            assert all(f"zoom_range_number_{index}" in state["controls"] for index in range(1, 9))
            assert "zoom_direction_8" in state["controls"]
            assert state["bounds"]["zoom_direction_1"]["y"] < state["bounds"]["zoom_range_number_1"]["y"]
            assert state["icons"]["zoom_direction_1"].endswith("/direction.LRTB.svg")
            assert state["icons"]["zoom_direction_1_height"] == math.ceil(32 * scale)
            state = _page_with(driver, "zoom_overlap_h")
            assert len(set(state["label_ends"].values())) == 1
            assert state["headings"]["Overlap"]["bold"]
            assert state["headings"]["Overlap"]["y"] < state["bounds"]["zoom_overlap_h"]["y"]
            assert state["headings"]["Overlap"]["x"] < state["slider_bounds"]["zoom_overlap_h"]["x"]
            assert state["labels"]["zoom_overlap_h"].startswith("Horizontal:")
            assert state["labels"]["zoom_overlap_v"].startswith("Vertical:")
            driver.command("reader_controls", action="choose", id="zoom_range_number_8")
            state = driver.command("reader_controls", action="paint")
            assert state["config"]["zoom_range_number"] == 8
            assert state["selections"]["zoom_range_number_8"]
            state = _page_with(driver, "zoom_overlap_h")
            for name in ["zoom_overlap_h", "zoom_overlap_v"]:
                previous = state["config"][name]
                expected = previous + 1
                driver.command("reader_controls", action="choose", id=name + "_increase")
                state = driver.command("reader_controls", action="paint")
                assert state["config"][name] == expected > previous
                assert state["slider_states"][name]["default_value"] is not None
            driver.command("reader_controls", action="choose", id="zoom_direction_8")
            state = driver.command("reader_controls", action="paint")
            assert state["config"]["zoom_direction"] == 0
            driver.screenshot(Path(f"/tmp/zen-reader-split-{extension}.png"))
            driver.command("reader_controls", action="choose", id="zoom_mode_genus_5")
            state = _page_with(driver, "zoom_factor")
            previous = state["config"]["zoom_factor"]
            driver.command("reader_controls", action="choose", id="zoom_factor_increase")
            assert driver.command("reader_controls")["config"]["zoom_factor"] > previous
            assert "text_wrap" not in controls
            driver.command("reader_controls", action="paint")
            driver.screenshot(Path(f"/tmp/zen-reader-controls-{extension}.png"))
        finally:
            stop(process)


@pytest.mark.parametrize("flipped", [False, True])
def test_reader_bottom_menu_with_top_tabs_replaced_by_controls(flipped):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        config = ("return {quick_settings={flip_lh_rh_icon=" + str(flipped).lower() +
                  ",show_buttons={launcher=true,zen_settings=true,library_home=true}},"
                  "reader_controls={entries={{id='custom_bookmarks',type='action',label='Custom bookmarks',"
                  "icon='bookmark',action={bookmarks=true}},{id='disabled',type='action',label='Disabled',"
                  "icon='bookmark',enabled=false,action={bookmarks=true}}},next_id=2}}")
        process = launch(runtime, home, socket_path, library, zen_config_source=config)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            _enable_reader_tabs(driver, [], disable=["Book switcher"])
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="paint")
            state = driver.command("reader_controls")
            assert "app_launcher" not in state["tabs"]
            assert "zen_ui" not in state["tabs"]
            assert "zen_library_home" not in state["tabs"]
            assert "reader_controls" not in state["tabs"]
            driver.command("reader_controls", action="tab", id="quicksettings")
            state = driver.command("reader_controls", action="tab", id="reader_controls")
            assert state["native_reader_tabs"]
            assert state["menu_bottom"] == state["screen_height"]
            assert "disabled" not in state["controls"]
            driver.screenshot(Path(f"/tmp/zen-reader-controls-left-{flipped}.png"))
            driver.command("reader_controls", action="choose", id="custom_bookmarks")
            overlay = _wait_command(driver, "hardware_overlay_state", lambda result: result.get("overlay", {}).get("kind") == "bookmarks")
            assert overlay["overlay"]["kind"] == "bookmarks"
            assert driver.command("hardware_overlay_key", key="Back")["handled"]
        finally:
            stop(process)


@pytest.mark.parametrize("launcher_first", [False, True])
def test_reader_menu_keeps_its_default_and_reader_buttons_remain_editable(launcher_first):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        if launcher_first:
            settings = home / "settings" / "ZenOS"
            settings.mkdir(parents=True)
            (settings / "app_launcher.lua").write_text("return {open_first=true}\n", encoding="utf-8")
        process = launch(runtime, home, socket_path, library,
                         zen_config_source="return {reader_controls={open_first=true}}")
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            state = driver.command("reader_controls", action="swipe_open")
            assert state["active_tab"] == ("app_launcher" if launcher_first else "quicksettings")
            state = driver.command("reader_controls", action="open")
            assert state["active_tab"] == "reader_controls"
            driver.command("reader_controls", action="edit_buttons")
            state = driver.command("arrange_page_state")
            assert state["ok"]
            assert state["arrange"]["labels"] == ["Book info", "Font", "Contrast (PDF/CBZ)", "Page", "Document", "Chapters",
                                                      "Bookmarks", "Search", "Profiles", "Themes", "Vocabulary builder",
                                                      "Page Browser", "KOReader reader menu", "Book switcher"]
            assert state["arrange"]["has_action"]
            driver.screenshot(Path("/tmp/zen-reader-buttons-editor.png"))
            assert driver.command("arrange_page_select", index=2, toggle=True)["ok"]
            assert driver.command("arrange_page_state")["arrange"]["checked"][1] is False
            assert driver.command("arrange_page_select", index=2)["ok"]
            labels = driver.command("arrange_page_state")["arrange"]["labels"]
            assert labels[0] == "Label: Font"
            assert labels[1].startswith("Icon:")
            assert len(labels) == 2
            assert driver.command("arrange_page_back")["ok"]
            assert driver.command("arrange_page_select", index=2, toggle=True)["ok"]
            assert driver.command("arrange_page_state")["arrange"]["checked"][1] is True
            assert driver.command("arrange_page_action")["ok"]
            labels = driver.command("arrange_page_state")["arrange"]["labels"]
            assert labels == ["Action", "Control", "Plugin Menu", "KOReader menu"]
            assert driver.command("arrange_page_back")["ok"]
            assert driver.command("arrange_page_state")["arrange"]["labels"][0] == "Book info"
            assert driver.command("arrange_page_close_button")["ok"]
            driver.command("reader_controls", action="close")
            state = driver.command("reader_controls", action="open")
            assert state["active_tab"] == "reader_controls"
            assert state["section"] == "book_info"
            state = driver.command("reader_controls", action="choose", id="font")
            assert state["section"] == "font"
            assert state["header"][0]["id"] == "book_info"
        finally:
            stop(process)


@pytest.mark.parametrize("embedded", [False, True])
def test_reader_font_reset_from_more_menu(embedded):
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket_path, library,
                         zen_config_source='return {updater={update_auto_check=false},'
                                           'page_browser={font_full_page=false}}')
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            fonts = driver.command("ensure_reader_status_fonts")
            assert fonts["ok"], fonts.get("error")
            if embedded:
                assert driver.command("activate_reader_control", name="page_browser")["activated"]
                assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
                driver.command("reader_controls", guard_preview_buffers=True)
            else:
                driver.command("reader_controls", action="open")
                driver.command("reader_controls", action="choose", id="font")
            initial = _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            changed = driver.command("reader_controls", action="choose_font", index=1)
            assert changed["font_face"] != initial["font_face"]
            driver.command("reader_controls", action="choose", id="font_size_increase")
            for name in ("font_face", "font_size"):
                if embedded:
                    _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
                _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
                driver.command("reader_controls", action="choose", id=name + "_more", tap=True)
                popup = driver.command("reader_controls", action="setting_menu")
                assert popup["ok"] and popup["positions"]["Reset"]["enabled"], name
                driver.command("reader_controls", action="setting_menu", button="Reset", tap=True)
                assert not driver.command("reader_controls", action="setting_menu")["ok"]
                state = driver.command("reader_controls", action="paint")
                assert state["font_face"] == initial["font_face"]
            assert state["config"]["font_size"] == initial["config"]["font_size"]
        finally:
            stop(process)


def test_reader_font_pickers_swipes_steps_and_formatting_background():
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library,
                         zen_config_source="return {quick_settings={background_hatching=true}}")
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            _enable_reader_tabs(driver, ["Profiles", "Vocabulary builder"], disable=["Book switcher", "Book info"])
            driver.command("reader_controls", action="open")
            state = _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            assert state["font_face"] in state["font_family_label"]
            assert state["zen_buttons"]["font_face"] and state["outlined"]["font_face"]
            assert state["icons"]["font_face_more_height"] == state["icons"]["font_size_more_height"]
            assert not state["radios"]
            original_face = state["font_face"]
            original_default = state.get("default_font")
            state = driver.command("reader_controls", action="font_family")
            assert state["font_menu"]["open"] and state["font_menu"]["scrollable"]
            assert state["font_menu"]["anchor"] == state["bounds"]["font_face"]
            original_scroll = state["font_menu"]["scroll_y"]
            state = driver.command("reader_controls", action="font_menu", scroll=160)
            assert state["font_menu"]["scroll_y"] > original_scroll
            driver.command("reader_controls", action="choose_font", hold=True)
            assert driver.command("native_settings_confirm", accept=False)["ok"]
            assert driver.command("reader_controls").get("default_font") == original_default
            driver.command("reader_controls", action="choose_font", hold=True)
            assert driver.command("native_settings_confirm", accept=True)["ok"]
            state = driver.command("reader_controls")
            assert state["font_face"] == original_face and state["default_font"]
            driver.command("reader_controls", action="font_menu", close=True)
            state = driver.command("reader_controls", action="swipe", zone="buttons")
            assert state["button_page"] == min(2, state["button_pages"])
            assert state["section"] == "font"
            driver.command("reader_controls", action="swipe", zone="buttons", direction="east")
            assert state["hatched_background"] is False
            size = state["config"]["font_size"]
            state = driver.command("reader_controls", action="choose", id="font_size_increase")
            assert state["config"]["font_size"] == size + 0.5
            assert state["hatched_background"] is False and state["hatching_enabled"]
            state = driver.command("reader_controls", action="choose", id="font_size_decrease")
            assert state["config"]["font_size"] == size
            driver.command("reader_controls", action="choose", id="font_size_increase")
            driver.command("reader_controls", action="choose", id="font_size_more")
            picker = driver.command("reader_controls", action="setting_menu")
            driver.screenshot(Path("/tmp/zen-reader-font-size-picker.png"))
            assert picker["value"] == size + 0.5
            assert "Close" not in picker["buttons"]
            driver.command("reader_controls", action="setting_menu", button="default")
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            assert driver.command("reader_controls")["config"]["font_size"] == size
            state = driver.command("reader_controls", action="choose", id="font_size_increase")
            assert state["config"]["font_size"] == size + 0.5
            driver.command("reader_controls", action="choose", id="font_size_more")
            driver.command("reader_controls", action="setting_menu", button="Set value")
            assert not driver.command("reader_controls", action="setting_menu")["ok"]
            spin = driver.command("reader_controls", action="spin")
            assert spin["ok"] and spin["value"] == size + 0.5 and spin["value_step"] == 0.5
            driver.command("reader_controls", action="spin", value=size + 3)
            assert not driver.command("reader_controls", action="spin")["ok"]
            assert driver.command("reader_controls")["config"]["font_size"] == size + 3
            state = driver.command("reader_controls")
            assert state["font_count"] == 0
            assert "font_base_weight_more" in state["controls"]
            for name in ["font_base_weight", "font_gamma", "word_spacing", "word_expansion"]:
                driver.command("reader_controls", action="choose", id=name + "_more")
                picker = driver.command("reader_controls", action="setting_menu")
                assert picker["ok"], name
                assert "Close" not in picker["buttons"], name
                assert "Set as default" in picker["buttons"], name
                assert picker["paired"] == (name == "word_spacing")
                previous = driver.command("reader_controls")["config"][name]
                delta = 0.25 if name == "font_base_weight" else 1
                driver.command("reader_controls", action="setting_menu", close=True)
                changed = [previous[0] + delta, previous[1]] if name == "word_spacing" else previous + delta
                driver.command("reader_controls", action="setting", name=name, value=changed)
                driver.command("reader_controls", action="choose", id=name + "_more")
                value = driver.command("reader_controls", action="setting_menu")["value"]
                assert value == (changed[0] if name == "word_spacing" else changed)
                if name == "font_gamma":
                    driver.command("reader_controls", action="setting_menu", button="Set as default")
                    assert driver.command("native_settings_confirm", accept=True)["ok"]
                    assert not driver.command("reader_controls", action="setting_menu")["ok"]
                    driver.command("reader_controls", action="choose", id=name + "_more")
                    assert driver.command("reader_controls", action="setting_menu")["default_value"] == value
                if name == "word_spacing":
                    driver.screenshot(Path("/tmp/zen-reader-word-spacing-picker.png"))
                driver.command("reader_controls", action="setting_menu", close=True)
            state = driver.command("reader_controls", action="choose", id="word_spacing_1")
            assert "word_spacing_more" in state["controls"]
            driver.command("reader_controls", action="paint")
            driver.screenshot(Path("/tmp/zen-reader-font-advanced.png"))
            driver.command("reader_controls", action="close")
            state = driver.command("reader_controls", action="open")
            assert state["hatched_background"] is False
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            driver.command("reader_controls", action="paint")
            state = driver.command("reader_controls", action="slider_swipe")
            assert state["config"]["font_size"] > size + 0.5
            driver.command("reader_controls", action="close")
            driver.command("reader_controls", action="open")
            state = driver.command("reader_controls", action="choose_font")
            assert state["hatched_background"] is False
            driver.command("reader_controls", action="close")
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id="page")
            state = driver.command("reader_controls", action="choose", id="h_page_margins_increase")
            assert state["hatched_background"] is False and state["hatching_enabled"]
        finally:
            stop(process)


def test_reader_slider_live_steps_and_menu_reopening():
    from PIL import Image, ImageChops

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        settings = home / "settings" / "ZenOS"
        settings.mkdir(parents=True)
        entries = ",".join(f'{{id="test_{i}",type="action",label="Action {i}",icon="info",action={{}}}}'
                           for i in range(8))
        (settings / "app_launcher.lua").write_text(
            'return {show_book_switcher=true,page_order={"buttons","book_switcher"},entries={' + entries + '}}\n',
            encoding="utf-8")
        socket_path = root / "driver.sock"
        # Keep the reader header static across screenshot comparisons.
        process = launch(runtime, home, socket_path, library,
                         zen_config_source='return {quick_settings={background_hatching=true},'
                                           'reader_top_status_bar={center_order={"custom_text"},'
                                           'custom_text="Reader controls"}}')
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id="font")
            state = _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            original = state["config"]["font_size"]
            slider = state["slider_states"]["font_size"]
            value_cell = state["value_cells"]["font_size"]
            slider_bounds = state["slider_bounds"]["font_size"]

            def aligned_value_cell(current):
                cell = current["value_cells"]["font_size"]
                for key in ["x", "y", "w", "h", "title", "title_x", "title_width"]:
                    assert cell[key] == value_cell[key], (key, value_cell, cell)
                assert cell["title_x"] + cell["title_width"] == cell["x"]
                assert cell["text_width"] <= cell["w"]
                assert cell["text_x"] + cell["text_width"] == cell["x"] + cell["w"]
                assert current["slider_bounds"]["font_size"] == slider_bounds

            target = slider["value"] + 2
            driver.command("reader_controls", action="drag_slider", value=target + 0.3)
            state = _wait_command(driver, "reader_controls", lambda result: result["config"]["font_size"] > original)
            live = state["slider_states"]["font_size"]
            assert live["dragging"] and live["knob_visible"]
            assert live["value"] == target
            assert live["instance"] == slider["instance"]
            assert state["config"]["font_size"] == original + 1
            aligned_value_cell(state)
            driver.command("reader_controls", action="drag_slider", value=target + 2, release=True)
            state = _wait_command(driver, "reader_controls", lambda result: not result["slider_states"]["font_size"]["dragging"])
            assert state["config"]["font_size"] == original + 2
            for value in [slider["maximum"] - 1, slider["minimum"], slider["value"]]:
                driver.command("reader_controls", action="drag_slider", value=value, release=True)
                state = _wait_command(driver, "reader_controls",
                                      lambda result: not result["slider_states"]["font_size"]["dragging"])
                aligned_value_cell(state)
            state = _wait_command(driver, "reader_controls", lambda result: not result["input_inhibited"])
            slider = state["slider_states"]["font_size"]
            track_width = state["slider_bounds"]["font_size"]["w"] - slider["knob_radius"] * 2
            drag_step = math.ceil((state["pan_threshold"] + 2) * (slider["maximum"] - slider["minimum"]) / track_width)
            for step in range(14):
                value = min(slider["maximum"], slider["value"] + drag_step + (step % 3) * 2)
                driver.command("reader_controls", action="touch_slider", start=step == 0, value=value)
                time.sleep(0.25)
                state = driver.command("reader_controls")
                live = state["slider_states"]["font_size"]
                aligned_value_cell(state)
                assert live["dragging"] and live["knob_visible"], (step, live)
                assert abs(live["value"] - value) <= 1, (step, value, live)
                assert live["instance"] == slider["instance"]
            driver.screenshot(root / "drag-label.png")
            driver.command("reader_controls", action="paint")
            driver.screenshot(root / "paint-label.png")
            bounds = state["bounds"]["font_size"]
            box = (bounds["x"], bounds["y"], value_cell["x"] + value_cell["w"], bounds["y"] + bounds["h"])
            with Image.open(root / "drag-label.png") as partial, Image.open(root / "paint-label.png") as full:
                assert ImageChops.difference(partial.crop(box), full.crop(box)).getbbox() is None
            driver.command("reader_controls", action="touch_slider", release=True)
            _wait_command(driver, "reader_controls", lambda result: not result["slider_states"]["font_size"]["dragging"])
            driver.command("reader_controls", action="close")
            driver.command("reader_controls", action="open")
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))

            def reset_and_compare(expected_section=None):
                before = driver.command("reader_controls")
                first, second = root / "before.png", root / "after.png"
                driver.screenshot(first)
                driver.command("reader_controls", action="tab", id=before["active_tab"])
                after = driver.command("reader_controls")
                driver.screenshot(second)
                assert after["hatched_background"] is (expected_section is None)
                if expected_section:
                    assert after["section"] == expected_section
                    assert after["button_page"] == 1
                    assert after["page"] == 1 and "Advanced" not in after["controls"]
                else:
                    assert driver.command("reader_launcher_state")["launcher"]["page"] == 1
                bottom = max(before["menu_bottom"], after["menu_bottom"])
                with Image.open(first) as initial, Image.open(second) as final:
                    if expected_section:
                        box = (0, 0, initial.width, min(before["menu_top"], after["menu_top"]))
                    else:
                        assert bottom < initial.height
                        box = (0, bottom, initial.width, initial.height)
                    assert ImageChops.difference(initial.crop(box), final.crop(box)).getbbox() is None
                return after

            driver.command("reader_controls", action="buttons_next")
            reset_and_compare("book_info")
            reset_and_compare("book_info")
            driver.command("reader_controls", action="choose", id="font")
            driver.command("reader_controls", action="next_page")
            state = reset_and_compare("book_info")
            driver.command("reader_controls", action="choose", id="page")
            reset_and_compare("book_info")
            driver.command("reader_controls", action="tab", id="app_launcher")
            assert driver.command("reader_launcher_state")["launcher"]["page_num"] > 1
            driver.command("reader_controls", action="next_page")
            assert driver.command("reader_launcher_state")["launcher"]["page"] == 2
            reset_and_compare()
            reset_and_compare()
            for tab in ["reader_controls", "quicksettings", "app_launcher"] * 2:
                before = driver.command("reader_controls")
                driver.screenshot(root / "before.png")
                driver.command("reader_controls", action="tab", id=tab)
                after = driver.command("reader_controls")
                driver.screenshot(root / "after.png")
                with Image.open(root / "before.png") as first, Image.open(root / "after.png") as second:
                    bottom = max(before["menu_bottom"], after["menu_bottom"])
                    if bottom == first.height:
                        continue
                    box = (0, bottom, first.width, first.height)
                    assert ImageChops.difference(first.crop(box), second.crop(box)).getbbox() is None
        finally:
            stop(process)


@pytest.mark.parametrize("show_chevrons", [None, False, True])
def test_reader_shared_selection_and_setting_layout(show_chevrons):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        chevrons = "show_page_chevrons=" + str(show_chevrons).lower() if show_chevrons is not None else ""
        config = "return {reader_controls={" + chevrons + "}}"
        settings = home / "settings" / "ZenOS"
        settings.mkdir(parents=True)
        entries = ",".join(f'{{id="test_{i}",type="action",label="Action {i}",icon="info",action={{}}}}'
                           for i in range(8))
        (settings / "app_launcher.lua").write_text("return {entries={" + entries + "}}\n", encoding="utf-8")
        process = launch(runtime, home, socket_path, library, zen_config_source=config)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            _enable_reader_tabs(driver, ["Profiles", "Vocabulary builder"], disable=["Book switcher", "Book info"])
            driver.command("reader_controls", action="open")
            state = driver.command("reader_controls", action="paint")
            assert state["settings_rows"] == 3
            assert "Advanced" not in state["controls"]
            assert state["font_face"] in state["font_family_label"]
            assert state["slider_bounds"]["font_size"]["w"] > 200
            assert state["bounds"]["font_size"]["h"] < state["slider_bounds"]["font_size"]["h"] * 1.5
            assert state["pager"]["y"] > state["bounds"]["font_size"]["y"]
            assert state["footer_margin"] == 0 < state["native_footer_margin"]
            assert state["menu_bottom"] == state["screen_height"]
            assert state["menu_top"] > 0
            reader_header = state["header"]
            driver.command("reader_controls", action="tab", id="app_launcher")
            driver.command("reader_controls", action="paint")
            launcher = driver.command("reader_launcher_state")["launcher"]["buttons"]
            launcher_row = [button for button in launcher if button["y"] == launcher[0]["y"]]
            assert all(entry["h"] < launcher_row[0]["h"] for entry in reader_header)
            driver.command("reader_controls", action="tab", id="reader_controls")
            state = driver.command("reader_controls", action="paint")
            has_arrows = show_chevrons is True and state["button_pages"] > 1
            assert state["page_chevrons"] is (show_chevrons is True)
            if has_arrows:
                arrows = {name: state["bounds"][name] for name in ["previous", "next"]}
                assert arrows["previous"]["w"] >= 48
                assert arrows["next"]["w"] >= 48
                assert arrows["previous"]["x"] + arrows["previous"]["w"] < state["header"][0]["x"]
                assert state["header"][-1]["x"] + state["header"][-1]["w"] < arrows["next"]["x"]
                driver.screenshot(Path("/tmp/zen-reader-chevron-padding.png"))
                _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
                driver.command("reader_controls", action="choose", id="next", tap=True)
                assert driver.command("reader_controls")["button_page"] == 2
                driver.command("reader_controls", action="choose", id="previous", tap=True)
                assert driver.command("reader_controls")["button_page"] == 1
                driver.command("reader_controls", action="choose", id="page", tap=True)
                assert driver.command("reader_controls")["section"] == "page"
                driver.command("reader_controls", action="choose", id="font", tap=True)
                assert driver.command("reader_controls")["section"] == "font"
            else:
                assert "previous" not in state["bounds"] and "next" not in state["bounds"]
                arrows = {}
            for _page in range(state["button_pages"] - 1):
                driver.command("reader_controls", action="buttons_next")
            second = driver.command("reader_controls", action="paint")
            assert len(second["header"]) <= len(state["header"])
            assert state["native_reader_tabs"] and second["native_reader_tabs"]
            assert len({entry["h"] for entry in second["header"]}) == 1
            if has_arrows:
                page_arrows = {name: second["bounds"][name] for name in arrows}
                assert page_arrows["previous"]["x"] + page_arrows["previous"]["w"] < second["header"][0]["x"]
                assert second["header"][-1]["x"] + second["header"][-1]["w"] < page_arrows["next"]["x"]
            if not has_arrows:
                assert "previous" not in second["bounds"] and "next" not in second["bounds"]
            driver.command("reader_controls", action="buttons_next")
            state = driver.command("reader_controls", action="paint")
            scale = min(state["screen_width"], state["screen_height"]) / 600
            inset = math.ceil(2 * scale)
            for name in ["font_size_decrease", "font_size_increase"]:
                style = state["step_styles"][name]
                assert style["size"] == math.ceil(14 * scale) and style["bold"] is False
                assert style["border"] == 0 and style["flash"] is False
                assert state["bounds"][name]["w"] == math.ceil(56 * scale)
            assert state["bounds"]["font_size_more"]["x"] == (
                state["bounds"]["font_size_increase"]["x"] + state["bounds"]["font_size_increase"]["w"])
            assert state["icons"]["font_size_more_height"] == state["title_heights"]["font_size"]
            font_start, font_end = state["step_styles"]["font_size_decrease"], state["step_styles"]["font_size_increase"]
            font_step = state["bounds"]["font_size_increase"]
            driver.command("reader_controls", action="setting", name="font_size", value=12)
            driver.command("reader_controls", action="setting", name="font_base_weight", value=-0.5)
            state = driver.command("reader_controls", action="choose", id="font")
            assert state["pager"] and state["page_num"] > 1
            state = driver.command("reader_controls", action="paint")
            assert state["value_cells"]["font_base_weight"]["text"] == "350"
            for name in ["font_size", "font_base_weight"]:
                cell = state["value_cells"][name]
                assert cell["text_x"] - cell["title_x"] - cell["title_width"] <= cell["text_width"] + 2
            assert state["header"]
            assert state["pager"]["y"] < min(entry["y"] for entry in state["header"])
            for name, value in [("font_kerning", 0), ("font_hinting", 0),
                                ("word_spacing", [75, 50]), ("word_expansion", 0)]:
                driver.command("reader_controls", action="choose", id=name + "_1")
                state = driver.command("reader_controls", action="paint")
                assert state["config"][name] == value
                assert state["selections"][name + "_1"] is True
                assert state["selections"][name + "_2"] is False
                assert state["bounds"][name + "_1"]["y"] == state["bounds"][name + "_2"]["y"]
                cells = [bounds for key, bounds in state["bounds"].items()
                         if key.startswith(name + "_") and key[len(name) + 1:].isdigit()]
                start, end = font_start, font_end
                assert min(cell["x"] for cell in cells) - inset == start["glyph_x"]
                assert max(cell["x"] + cell["w"] for cell in cells) + inset == end["glyph_x"] + end["glyph_w"]
                if name in ["word_spacing", "word_expansion"]:
                    step = font_step
                    assert state["bounds"][name + "_more"]["x"] == step["x"] + step["w"]
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            driver.command("reader_controls", action="choose", id="font_kerning_1", hold=True)
            assert driver.command("native_settings_confirm", accept=False)["ok"]
            driver.command("reader_controls", action="choose", id="font")
            state = driver.command("reader_controls", action="paint")
            assert len({slider["w"] for slider in state["slider_bounds"].values()}) == 1
            assert len({slider["x"] for slider in state["slider_bounds"].values()}) == 1
            assert len(set(state["label_ends"].values())) == 1
            assert set(state["value_cells"]) == set(state["slider_bounds"])
            assert len({cell["x"] + cell["w"] for cell in state["value_cells"].values()}) == 1
            for cell in state["value_cells"].values():
                assert cell["text_width"] <= cell["w"]
                assert cell["text_x"] + cell["text_width"] == cell["x"] + cell["w"]
            for name in ["font_base_weight", "font_gamma"]:
                state = _page_with(driver, name)
                assert state["bounds"][name]["h"] < state["slider_bounds"][name]["h"] * 1.5
                assert state["bounds"][name + "_more"]["x"] == (
                    state["bounds"][name + "_increase"]["x"] + state["bounds"][name + "_increase"]["w"])
                assert state["icons"][name + "_more_height"] == state["title_heights"][name]
            driver.screenshot(Path("/tmp/zen-reader-selection-advanced.png"))
            driver.command("reader_controls", action="choose", id="font")
            state = driver.command("reader_controls", action="paint")
            assert "Advanced" not in state["controls"] and state["font_face"] in state["font_family_label"]
            assert state["header"]
            assert {name: state["bounds"][name] for name in arrows} == arrows
            driver.command("reader_controls", action="setting", name="h_page_margins", value=[30, 30])
            driver.command("reader_controls", action="setting", name="sync_t_b_page_margins", value=1)
            driver.command("reader_controls", action="choose", id="page")
            state = driver.command("reader_controls", action="paint")
            layout_state = state
            cell = state["value_cells"]["h_page_margins"]
            assert cell["text_x"] - cell["title_x"] - cell["title_width"] <= cell["text_width"] + 2
            assert state["bounds"]["h_page_margins"]["y"] < state["bounds"]["t_page_margin"]["y"]
            assert state["bounds"]["t_page_margin"]["y"] < state["bounds"]["view_mode_1"]["y"]
            assert "line_spacing" not in state["controls"]
            margins = state["config"]["h_page_margins"]
            assert margins[0] == margins[1]
            assert state["labels"]["h_page_margins"] == f"Left/Right: {margins[0]}"
            assert "sync_t_b_page_margins" not in state["controls"]
            assert len({slider["w"] for slider in state["slider_bounds"].values()}) == 1
            assert len({slider["x"] for slider in state["slider_bounds"].values()}) == 1
            assert len(set(state["label_ends"].values())) == 1
            assert len({cell["x"] + cell["w"] for cell in state["value_cells"].values()}) == 1
            for cell in state["value_cells"].values():
                assert cell["text_x"] + cell["text_width"] == cell["x"] + cell["w"]
            for name, slider in state["slider_bounds"].items():
                assert state["bounds"][name + "_more"]["x"] == (
                    state["bounds"][name + "_increase"]["x"] + state["bounds"][name + "_increase"]["w"])
                assert state["bounds"][name]["h"] < slider["h"] * 1.5
            assert state["menu_bottom"] == state["screen_height"]
            assert state["menu_top"] > 0
            driver.command("reader_controls", action="choose", id="view_mode_2")
            state = driver.command("reader_controls", action="paint")
            assert state["config"]["view_mode"] == 1
            assert state["selections"]["view_mode_2"] is True
            # View mode and two columns share one row: Page / Continuous / Two column.
            assert "visible_pages_1" not in state["controls"]
            cells = [state["bounds"]["view_mode_1"], state["bounds"]["view_mode_3"]]
            start = layout_state["step_styles"]["t_page_margin_decrease"]
            end = layout_state["step_styles"]["t_page_margin_increase"]
            assert cells[0]["x"] - inset == start["glyph_x"]
            assert cells[1]["x"] + cells[1]["w"] + inset == end["glyph_x"] + end["glyph_w"]
            driver.command("reader_controls", action="choose", id="view_mode_3")
            state = driver.command("reader_controls", action="paint")
            assert state["config"]["view_mode"] == 0 and state["config"]["visible_pages"] == 2
            assert state["selections"]["view_mode_3"] is True
            driver.command("reader_controls", action="choose", id="view_mode_1")
            state = driver.command("reader_controls", action="paint")
            assert state["config"]["view_mode"] == 0 and state["config"]["visible_pages"] == 1
            assert state["selections"]["view_mode_1"] is True
            driver.screenshot(Path("/tmp/zen-reader-selection-page.png"))
            driver.command("reader_controls", action="choose", id="themes")
            state = driver.command("reader_controls", action="paint")
            assert state["zen_buttons"]["Reader theme settings"]
            assert state["outlined"]["Reader theme settings"]
            assert state["theme_count"] == 8
            theme_bounds = [state["bounds"][name] for name in state["radios"]]
            assert len({bounds["x"] for bounds in theme_bounds}) == 2
            assert len({bounds["y"] for bounds in theme_bounds}) == 4
            assert state["bounds"]["Reader theme settings"]["y"] < min(bounds["y"] for bounds in theme_bounds)
            assert state["menu_bottom"] == state["screen_height"]
            assert state["bounds"]["Default"]["y"] < min(entry["y"] for entry in state["header"])
            driver.screenshot(Path("/tmp/zen-reader-selection-themes.png"))
            driver.command("reader_controls", action="capture", name="Test profile")
            driver.command("reader_controls", action="choose", id="profiles")
            state = driver.command("reader_controls", action="paint")
            ends = {state["bounds"][name]["x"] + state["bounds"][name]["w"]
                    for name in ["Defaults", "Save current reader settings", "Test profile", "Manage profiles"]}
            assert len(ends) == 1
            assert ends.pop() <= state["bounds"]["Include reader theme_1"]["x"]
            assert state["selections"]["Include reader theme_2"] is True
            driver.screenshot(Path("/tmp/zen-reader-selection-profiles.png"))
            state = driver.command("reader_controls", action="tab", id="quicksettings")
            assert state["footer_margin"] == state["native_footer_margin"]
        finally:
            stop(process)


def test_reader_theme_chooser_paging_and_selection():
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        themes = ",".join(f'custom_{i}={{name="Theme {i:02}",text="#201810",background="#E8DCC5"}}' for i in range(10))
        process = launch(runtime, home, socket_path, library,
                         zen_config_source="return {reader_themes={custom={" + themes + "}}}")
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id="themes")
            state = driver.command("reader_controls", action="paint")
            assert state["theme_count"] == 8
            # 18 builtin + 10 custom themes, 8 per page.
            assert state["theme_pages"] == 4 and state["theme_page"] == 1
            assert len({state["bounds"][name]["y"] for name in state["radios"]}) == 4
            first = set(state["radios"])
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            driver.command("reader_controls", action="swipe", zone="themes")
            state = driver.command("reader_controls", action="paint")
            assert state["theme_count"] == 8
            assert state["theme_page"] == 2
            assert not first.intersection(state["radios"])
            assert "Use global theme settings" not in state["radios"]
            assert state["zen_buttons"]["Reader theme settings"]
            for page in [1, 4]:
                _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
                driver.command("reader_controls", action="swipe", zone="themes", direction="east")
                state = driver.command("reader_controls", action="paint")
                assert state["theme_page"] == page
            assert set(state["radios"]) == {f"Theme {i:02}" for i in range(6, 10)}
            driver.command("reader_controls", action="choose", id="Theme 09")
            state = driver.command("reader_controls", action="paint")
            assert state["radios"]["Theme 09"]
            assert state["theme"]["light_mode"]["name"] == "Theme 09"
            assert state["global_themes"]["light_mode"] == "custom_9"
            _wait_command(driver, "reader_controls", lambda result: not result.get("locked"))
            driver.command("reader_controls", action="swipe", zone="themes")
            state = driver.command("reader_controls", action="paint")
            assert state["theme_page"] == 1
            assert set(state["radios"]) == first
            assert not any(state["radios"].values())
            driver.screenshot(Path("/tmp/zen-reader-compact-theme-pages.png"))
        finally:
            stop(process)


@pytest.mark.parametrize("enabled", [False, True])
def test_reader_controls_icon_pack_overrides(enabled):
    import json

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zrc-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        names = {"font": "font", "contrast": "appbar.contrast", "page": "page", "document": "document",
                 "book_info": "info", "toc": "toc", "bookmarks": "bookmark_outline", "search": "quick_search",
                 "profiles": "profiles", "themes": "settings_brush", "font_size_more": "more_vertical"}
        pack = home / "icons" / "zen" / "reader"
        pack.mkdir(parents=True)
        (pack / "pack.json").write_text(json.dumps({"schema_version": 1, "id": "reader", "name": "Reader"}))
        svg = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="8" fill="#C04060"/></svg>'
        for name in [*names.values(), "chevron.left", "chevron.right"]:
            (pack / (name + ".svg")).write_text(svg)
        book = library / "controls.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        config = 'return {features={custom_icons_enabled=' + str(enabled).lower() + '},custom_icons={active_pack="reader"}}'
        process = launch(runtime, home, socket_path, library, zen_config_source=config)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            _enable_reader_tabs(driver, ["Profiles"], disable=["Book switcher"])
            state = driver.command("reader_controls", action="open")
            icons = dict(state["icons"])
            for _page in range(1, state["button_pages"]):
                state = driver.command("reader_controls", action="buttons_next")
                icons.update(state["icons"])
            state = driver.command("reader_controls", action="choose", id="font")
            icons.update(state["icons"])
            assert "reader_controls" not in state["tabs"]
            for control, name in names.items():
                if control in ("document", "contrast"):
                    continue
                if enabled:
                    assert Path(icons[control]).resolve() == (pack / (name + ".svg")).resolve()
                else:
                    assert "/icons/zen/reader/" not in icons[control]
            driver.screenshot(Path("/tmp/zen-reader-custom-icons.png" if enabled else "/tmp/zen-reader-default-icons.png"))
            pdf = library / "controls.pdf"
            _write_pdf(pdf)
            driver.command("reader_controls", action="switch_book", path=str(pdf.resolve()))
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(pdf.resolve()))
            driver.command("reader_controls", action="open")
            state = driver.command("reader_controls", action="choose", id="document")
            if enabled:
                assert Path(state["icons"]["document"]).resolve() == (pack / "document.svg").resolve()
                assert Path(state["icons"]["contrast"]).resolve() == (pack / "appbar.contrast.svg").resolve()
            else:
                assert "/icons/zen/reader/" not in state["icons"]["document"]
                assert "/icons/zen/reader/" not in state["icons"]["contrast"]
        finally:
            stop(process)
