import math
import os
import sys
import tempfile
import time
import zipfile
from pathlib import Path

import pytest
from PIL import Image, ImageChops

from zen_driver import ZenDriver, launch, stop, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1",
    reason="set ZEN_UI_RUN_EMULATOR=1 to run a real KOReader emulator",
)


def _write_reader_epub(path: Path) -> None:
    container = b"""<?xml version='1.0'?>
<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container' version='1.0'>
  <rootfiles><rootfile full-path='OEBPS/content.opf'
    media-type='application/oebps-package+xml'/></rootfiles>
</container>"""
    package = b"""<?xml version='1.0'?>
<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='id'>
  <metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>
    <dc:identifier id='id'>zen-reader-tools</dc:identifier>
    <dc:title>Reader Tools Fixture</dc:title><dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>
    <item id='chapter' href='chapter.xhtml' media-type='application/xhtml+xml'/>
  </manifest>
  <spine><itemref idref='chapter'/></spine>
</package>"""
    nav = b"""<html xmlns='http://www.w3.org/1999/xhtml'><body>
<nav epub:type='toc' xmlns:epub='http://www.idpf.org/2007/ops'>
<ol><li><a href='chapter.xhtml'>Test chapter</a></li></ol></nav></body></html>"""
    paragraph = "Reader tools deterministic selection text. " * 1600
    chapter = (
        "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Test chapter</title></head>"
        f"<body><h1>Test chapter</h1><p>{paragraph}</p></body></html>"
    ).encode()
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container)
        archive.writestr("OEBPS/content.opf", package)
        archive.writestr("OEBPS/nav.xhtml", nav)
        archive.writestr("OEBPS/chapter.xhtml", chapter)


def _wait_command(
    driver: ZenDriver, kind: str, predicate, timeout: float = 20, **params: object
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    last: dict[str, object] = {}
    while time.monotonic() < deadline:
        last = driver.command(kind, **params)
        if predicate(last):
            return last
        time.sleep(0.2)
    raise AssertionError(f"{kind} did not reach expected state: {last}")


def _frames_differ(first: Path, second: Path) -> bool:
    with Image.open(first) as first_image, Image.open(second) as second_image:
        difference = ImageChops.difference(first_image.convert("RGB"), second_image.convert("RGB"))
        return difference.getbbox() is not None


def _page_browser_more_rows(driver: ZenDriver) -> list[dict[str, object]]:
    assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
    return _wait_command(driver, "page_browser_state", lambda result:
                         result["page_browser"].get("more_menu", {}).get("bounds"))["page_browser"]["more_menu"]["rows"]


@pytest.mark.parametrize("saved_book_settings", [False, True])
def test_last_file_startup_restores_reader_typography(saved_book_settings: bool) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    expected = {
        "h_page_margins": [51, 57],
        "t_page_margin": 47,
        "b_page_margin": 49,
        "line_spacing": 145,
        "font_size": 29,
    }
    font_name, font_file = "Readerly R", "Readerly_R-Regular.ttf"
    if saved_book_settings:
        expected.update(h_page_margins=[71, 73], line_spacing=155, font_size=31)
        font_name, font_file = "Libron R", "Libron_R-Regular.ttf"
    with tempfile.TemporaryDirectory(prefix="zen-reader-startup-") as temporary:
        root = Path(temporary)
        margins = []
        for start_with in ("filemanager", "last"):
            home, library = root / start_with / "home", root / start_with / "library"
            home.mkdir(parents=True)
            library.mkdir()
            book = library / "startup.epub"
            _write_reader_epub(book)
            if saved_book_settings:
                sidecar = book.with_suffix(".sdr")
                sidecar.mkdir()
                (sidecar / "metadata.epub.lua").write_text(
                    "return { font_face = 'Libron R', copt_h_page_margins = {71, 73}, "
                    "copt_line_spacing = 155, copt_font_size = 31 }\n", encoding="utf-8",
                )
            (home / "settings.reader.lua").write_text(
                "return { home_dir = " + repr(str(library.resolve()))
                + ", lastfile = " + repr(str(book.resolve()))
                + ", start_with = " + repr(start_with)
                + ", cre_font = 'Readerly R', copt_h_page_margins = {51, 57}, "
                "copt_t_page_margin = 47, copt_b_page_margin = 49, "
                "copt_line_spacing = 145, copt_font_size = 29 }\n",
                encoding="utf-8",
            )
            config_dir = home / "settings" / "ZenOS"
            config_dir.mkdir(parents=True)
            (config_dir / "config.lua").write_text(
                "return { updater = { update_auto_check = false }, "
                "_meta = { quickstart_completed = true } }\n", encoding="utf-8",
            )
            socket_path = root / "driver.sock"
            process = launch(runtime, home, socket_path, library, initialize_settings=False)
            try:
                wait_for_socket(socket_path)
                driver = ZenDriver(socket_path)
                if start_with == "filemanager":
                    assert driver.open_book(book)["ok"]
                _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
                state = driver.command("native_settings_state", keys=list(expected))
                assert state["values"] == expected, (start_with, state)
                assert state["font"]["name"] == font_name
                assert state["font"]["source"].endswith("/" + font_file), (start_with, state)
                margins.append(state["margins"])
                assert driver.command("goto_reader_page", page=2)["ok"]
                driver.screenshot(root / (start_with + ".png"))
            finally:
                stop(process)
        assert margins[0] == margins[1]
        with Image.open(root / "filemanager.png") as first, Image.open(root / "last.png") as last:
            box = (0, first.height // 4, first.width, first.height * 3 // 4)
            assert ImageChops.difference(
                first.convert("RGB").crop(box), last.convert("RGB").crop(box)
            ).getbbox() is None


@pytest.mark.parametrize("dark_mode", [False, True])
def test_reader_themes_allow_page_turns_after_changing_theme(dark_mode: bool) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-reader-themes-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "reader-themes.epub"
        _write_reader_epub(book)
        (home / "settings.reader.lua").write_text(
            'return { home_dir = ' + repr(str(library.resolve()))
            + ', night_mode = ' + str(dark_mode).lower() + ' }\n', encoding="utf-8",
        )
        config_dir = home / "settings" / "ZenOS"
        config_dir.mkdir(parents=True)
        (config_dir / "config.lua").write_text(
            "return { updater = { update_auto_check = false }, "
            "features = { reader_themes = false }, "
            "reader_themes = { dark_mode = 'default', light_mode = 'default' } }\n",
            encoding="utf-8",
        )
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library, initialize_settings=False)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
            assert driver.command("open_settings_page")["ok"]
            mode = "Dark mode" if dark_mode else "Light mode"
            for label in ("Reader", "Appearance"):
                assert driver.command("settings_page_select", label=label)["ok"]
            assert driver.command("settings_page_select", label="Reader themes", control=True)["ok"]
            for label in ("Reader themes", mode + ": Default", "Light tan"):
                assert driver.command("settings_page_select", label=label)["ok"]
            assert driver.command("close_settings_page")["ok"]
            first_frame = root / "first.png"
            driver.screenshot(first_frame)

            def assert_palette(path, text, background):
                with Image.open(path) as frame:
                    frame = frame.convert("RGB")
                    colors = dict((color, count) for count, color in frame.getcolors(frame.width * frame.height))
                    assert colors.get(background, 0) > frame.width * frame.height // 2, sorted(
                        colors.items(), key=lambda entry: -entry[1])[:8]
                    assert colors.get(text, 0) > 0, sorted(colors.items(), key=lambda entry: -entry[1])[:8]
                    header = frame.crop((0, 0, frame.width, 40))
                    header_colors = dict((color, count) for count, color in header.getcolors(header.width * header.height))
                    # Small header glyphs may contain only antialiased pixels.
                    assert any(max(abs(actual - expected) for actual, expected in zip(color, text)) <= 8
                               for color in header_colors), sorted(header_colors.items(), key=lambda entry: -entry[1])[:8]

            assert_palette(first_frame, (0x47, 0x3b, 0x2d), (0xe8, 0xdc, 0xc5))
            driver.command("reader_controls", action="open")
            driver.command("reader_controls", action="choose", id="themes")
            driver.command("reader_controls", action="choose", id="Dark warm gray")
            state = driver.command("reader_controls")
            assert state["global_themes"]["dark_mode" if dark_mode else "light_mode"] == "dark_warm_gray"
            assert state["radios"]["Dark warm gray"]
            assert "Current book" not in state["radios"]
            assert "Use global theme settings" not in state["radios"]
            driver.command("reader_controls", action="close")
            driver.screenshot(first_frame)
            assert_palette(first_frame, (0xdc, 0xdc, 0xcc), (0x1f, 0x1f, 0x1f))
            other = library / "other.epub"
            _write_reader_epub(other)
            for target in (other, book):
                assert driver.command("reader_controls", action="switch_book", path=str(target.resolve()))["ok"]
                _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(target.resolve()))
                driver.screenshot(first_frame)
                assert_palette(first_frame, (0xdc, 0xdc, 0xcc), (0x1f, 0x1f, 0x1f))
            for page in (3, 2, 4, 3):
                assert driver.command("goto_reader_page", page=page)["ok"]
                _wait_command(driver, "reader_state", lambda result: result["reader"]["page"] == page)
            last_frame = root / "last.png"
            driver.screenshot(last_frame)
            with Image.open(first_frame) as first, Image.open(last_frame) as last:
                box = (0, first.height // 4, first.width, first.height * 3 // 4)
                assert ImageChops.difference(
                    first.convert("RGB").crop(box), last.convert("RGB").crop(box)
                ).getbbox() is not None
        finally:
            stop(process)


def test_reader_page_browser_modes_and_search_render() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-reader-tools-") as temporary:
        root = Path(temporary)
        ko_home, library = root / "home", root / "library"
        ko_home.mkdir()
        library.mkdir()
        book = library / "reader-tools.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, ko_home, socket_path, library,
                         zen_config_source="return {page_browser={font_full_page=false}}")
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            opened = _wait_command(
                driver, "open_book", lambda result: result.get("ok") is True,
                path=str(book),
            )
            assert opened["ok"] is True, opened
            reader = _wait_command(
                driver,
                "reader_state",
                lambda result: result.get("reader", {}).get("open") is True,
            )["reader"]
            assert Path(reader["file"]).resolve() == book.resolve()

            assert driver.command(
                "activate_reader_control", name="page_browser"
            )["activated"] is True
            default_carousel = _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "carousel",
            )["page_browser"]
            assert default_carousel["thumbnail_count"] == 3
            assert default_carousel["controls"] == ["single", "carousel", "grid"]
            assert default_carousel["header_icons"] == ["more_vertical.svg", "view_carousel_outline.svg", "font.svg", "bookmark_outline.svg",
                                                        "lookup_highlight.svg", "toc.svg", "close.svg"]
            assert default_carousel["focused"] == "header:1"
            assert default_carousel["header_height"] >= (
                default_carousel["header_tabs"]["y"] + default_carousel["header_tabs"]["h"]
            )
            assert default_carousel["preview_divider"]["y"] == default_carousel["screen_height"] - default_carousel["panel_height"]
            chapter = default_carousel["chapter_bounds"]
            previous, following = default_carousel["previous_bounds"], default_carousel["next_bounds"]
            grid_button, search = default_carousel["grid_bounds"], default_carousel["search_bounds"]
            assert chapter["y"] == grid_button["y"] == search["y"]
            assert previous["y"] == chapter["y"] + chapter["h"]
            assert grid_button["x"] + grid_button["w"] < chapter["x"]
            assert chapter["x"] + chapter["w"] < search["x"]
            slider = default_carousel["slider_bounds"]
            assert previous["x"] + previous["w"] < slider["x"]
            assert slider["x"] + slider["w"] < following["x"]
            assert previous["y"] == following["y"]
            assert abs(previous["y"] + previous["h"] / 2 - slider["y"] - slider["h"] / 2) <= 1
            assert 0 < slider["y"] - chapter["y"] - chapter["h"] < default_carousel["edge_padding"]
            panel_top = default_carousel["screen_height"] - default_carousel["panel_height"]
            assert 0 < chapter["y"] - panel_top < default_carousel["edge_padding"]
            preview = default_carousel["preview_bounds"][1]["bounds"]
            assert preview["y"] - default_carousel["header_height"] > default_carousel["edge_padding"] / 2
            assert preview["y"] + preview["h"] + default_carousel["edge_padding"] < chapter["y"]
            assert grid_button["x"] == previous["x"]
            assert search["x"] == following["x"]
            assert following["y"] + following["h"] == default_carousel["screen_height"] - (chapter["y"] - panel_top)
            assert driver.command("activate_reader_control", name="page_browser_tab_swipe")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["top_is_browser"] is True

            for control, tab in (("page_browser_controls", "aa"),
                                 ("page_browser_bookmarks", "bookmarks"),
                                 ("page_browser_toc", "toc")):
                assert driver.command("activate_reader_control", name=control)["activated"] is True
                state = driver.command("page_browser_state")["page_browser"]
                assert state["active_tab"] == tab
                assert state["browser_buttons_visible"] is False
                assert state["header_icons"] == default_carousel["header_icons"]
                if tab == "toc":
                    assert state["content_zen_scroll_bar"] is True
                    # Hold used to loop through FocusManager:onHold until stack overflow.
                    assert driver.command("annotation_viewer_action", action="hold", index=1)["ok"]
                    assert driver.command("page_browser_state")["page_browser"]["active_tab"] == "toc"
                    # Swipe used to reach the Menu twice, skipping every other page.
                    swiped = driver.command("annotation_viewer_action", action="swipe")
                    assert swiped["ok"], swiped
                if tab in ("toc", "bookmarks"):
                    assert state["content_bottom"] == state["screen_height"] - state["edge_padding"]
                if tab == "aa":
                    assert state["layout"] == "carousel"
                    assert state["preview_geometry"]["h"] < default_carousel["preview_geometry"]["h"]
                    _wait_command(driver, "page_browser_state", lambda result:
                                  result["page_browser"]["preview_ready"])
                    before = root / "preview-before.png"
                    driver.screenshot(before)
                    controls = driver.command("reader_controls")
                    size = controls["config"]["font_size"]
                    assert controls["active_tab"] == "aa"
                    assert controls["subsections"] == ["font", "page", "themes"]
                    assert controls["font_face"] in controls["font_family_label"]
                    assert set(controls["slider_bounds"]) == {"font_size", "font_base_weight"}
                    assert "font_kerning_1" not in controls["controls"]
                    assert len(controls["settings_dividers"]) == controls["settings_rows"] - 1 == 2
                    assert all(line["light_gray"] for line in controls["settings_dividers"])
                    pager, panel_top = controls["pager"], controls["menu_top"]
                    assert controls["menu_bottom"] == controls["screen_height"]
                    section_tabs = controls["section_tabs"]
                    assert pager["y"] + pager["h"] < section_tabs["y"]
                    assert section_tabs["y"] + section_tabs["h"] == controls["screen_height"] - state["edge_padding"]
                    assert state["preview_divider"]["y"] == controls["menu_top"]
                    for page in range(2, state["aa_pages"] + 1):
                        assert driver.command("activate_reader_control", name="page_browser_font_next")["activated"]
                        next_page = driver.command("reader_controls")
                        assert next_page["page"] == page
                        assert next_page["menu_top"] == panel_top
                        assert next_page["pager"] == pager
                        assert next_page["menu_bottom"] == controls["screen_height"]
                        assert len(next_page["settings_dividers"]) == next_page["settings_rows"] - 1
                        assert all(panel_top < line["y"] < pager["y"] and line["light_gray"]
                                   for line in next_page["settings_dividers"])
                        assert driver.command("page_browser_state")["page_browser"]["preview_id"] == state["preview_id"]
                    for _page in range(state["aa_pages"] - 1):
                        assert driver.command("activate_reader_control", name="page_browser_font_previous")["activated"]
                    family = driver.command("reader_controls", action="font_family")
                    assert family["font_menu"]["open"] and family["font_menu"]["scrollable"]
                    assert family["font_menu"]["anchor"] == family["bounds"]["font_face"]
                    family = _wait_command(driver, "reader_controls", lambda result:
                                           result.get("font_menu", {}).get("bounds"))
                    assert family["font_menu"]["bounds"]["x"] >= state["edge_padding"] / 2
                    assert family["font_menu"]["bounds"]["x"] + family["font_menu"]["bounds"]["w"] <= default_carousel["preview_geometry"]["w"] - state["edge_padding"] / 2
                    assert family["font_menu"]["bounds"]["h"] < controls["screen_height"] * 0.55
                    frame_dir = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser"
                    frame_dir.mkdir(parents=True, exist_ok=True)
                    driver.screenshot(frame_dir / "font-family.png")
                    driver.command("reader_controls", action="font_menu", close=True)
                    changed = driver.command("reader_controls", action="choose", id="font_size_increase")
                    assert changed["config"]["font_size"] == size + 0.5
                    _wait_command(driver, "page_browser_state", lambda result:
                                  result["page_browser"]["preview_ready"])
                    after = root / "preview-after.png"
                    driver.screenshot(after)
                    with Image.open(before) as first, Image.open(after) as second:
                        crop = (0, first.height // 8, first.width, first.height // 2)
                        assert ImageChops.difference(first.crop(crop), second.crop(crop)).getbbox()
                    assert driver.command("page_browser_state")["page_browser"]["active_tab"] == "aa"
                    for settings_page in (1, 2):
                        if settings_page == 2:
                            assert driver.command("activate_reader_control", name="page_browser_font_next")["activated"]
                        start = driver.command("page_browser_state")["page_browser"]["focus_page"]
                        for action, target in (("right", start + 1), ("left", start),
                                               ("swipe_next", start + 1), ("swipe_previous", start)):
                            assert driver.command("activate_reader_control", name=f"page_browser_preview_{action}")["activated"]
                            preview = driver.command("page_browser_state")["page_browser"]
                            assert preview["focus_page"] == target and preview["active_tab"] == "aa", (action, preview)
                            assert driver.command("reader_controls")["page"] == settings_page
                        bookmarked = preview["preview_bookmarked"]
                        assert driver.command("activate_reader_control", name="page_browser_preview_hold")["activated"]
                        pending = driver.command("page_browser_state")["page_browser"]
                        assert pending["page_actions_open"] and pending["preview_bookmarked"] is bookmarked
                        assert driver.command("activate_reader_control", name="page_browser_bookmark_page")["activated"]
                        assert driver.command("page_browser_state")["page_browser"]["preview_bookmarked"] is not bookmarked
                        assert driver.command("activate_reader_control", name="page_browser_preview_hold")["activated"]
                        assert driver.command("activate_reader_control", name="page_browser_bookmark_page")["activated"]
                        assert driver.command("page_browser_state")["page_browser"]["preview_bookmarked"] is bookmarked
                        assert driver.command("activate_reader_control", name="page_browser_preview_center")["activated"]
                        assert driver.command("page_browser_state").get("page_browser") is None
                        assert driver.command("reader_state")["reader"]["page"] == start
                        assert driver.command("activate_reader_control", name="page_browser")["activated"]
                        assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
                frame_dir = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser"
                frame_dir.mkdir(parents=True, exist_ok=True)
                driver.screenshot(frame_dir / f"{tab}.png")
            assert state["content_items"] > 0
            assert driver.command("page_browser_key", key="Down")["handled"] is True
            assert driver.command("page_browser_key", key="Return")["handled"] is True
            assert driver.command("page_browser_state").get("page_browser") is None
            assert driver.command("activate_reader_control", name="page_browser")["activated"] is True
            assert driver.command("activate_reader_control", name="page_browser_pages")["activated"] is True
            assert driver.command("page_browser_state")["page_browser"]["browser_buttons_visible"] is True
            assert driver.command("activate_reader_control", name="page_browser_layout_menu")["activated"] is True
            layout_menu = driver.command("page_browser_state")["page_browser"]["layout_menu"]
            assert layout_menu["count"] == 3
            assert layout_menu["bounds"]["x"] >= default_carousel["edge_padding"] / 2
            assert layout_menu["bounds"]["y"] + layout_menu["bounds"]["h"] <= layout_menu["anchor"]["y"]

            assert driver.command(
                "activate_reader_control", name="page_browser_grid"
            )["activated"] is True
            grid = _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "grid",
            )["page_browser"]
            assert grid["thumbnail_count"] == 9
            assert grid["focused"] == "header:1"
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            grid_fonts = driver.command("page_browser_state")["page_browser"]
            assert grid_fonts["layout"] == "single" and grid_fonts["thumbnail_count"] == 1
            assert grid_fonts["panel_height"] > default_carousel["panel_height"]
            assert driver.command("activate_reader_control", name="page_browser_preview_center")["activated"]
            assert driver.command("page_browser_state").get("page_browser") is None
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_pages")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["layout"] == "grid"

            assert driver.command("page_browser_key", key="Down")["handled"] is True
            focused_page = _wait_command(
                driver,
                "page_browser_state",
                lambda result: str(
                    result.get("page_browser", {}).get("focused", "")
                ).startswith("page:"),
            )["page_browser"]
            assert focused_page["focus_page"] == grid["focus_page"]
            assert driver.command("page_browser_key", key="Right")["handled"] is True
            next_focused_page = driver.command("page_browser_state")["page_browser"]
            assert next_focused_page["focused"].startswith("page:")
            assert next_focused_page["focus_page"] == grid["focus_page"]
            assert driver.command("page_browser_key", key="Return")["handled"] is True
            _wait_command(
                driver,
                "reader_overlay_state",
                lambda result: result.get("overlays", {}).get("page_browser") is False,
            )

            assert driver.command(
                "activate_reader_control", name="page_browser"
            )["activated"] is True
            _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("focused") == "header:1",
            )
            assert driver.command("page_browser_key", key="Back")["handled"] is True
            _wait_command(
                driver,
                "reader_overlay_state",
                lambda result: result.get("overlays", {}).get("page_browser") is False,
            )

            assert driver.command(
                "activate_reader_control", name="page_browser"
            )["activated"] is True
            _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "grid",
            )

            grid_frame = root / "page-browser-grid.png"
            driver.screenshot(grid_frame)

            assert driver.command(
                "activate_reader_control", name="page_browser_carousel"
            )["activated"] is True
            carousel = _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "carousel",
            )["page_browser"]
            assert carousel["thumbnail_count"] == 3
            carousel_frame = root / "page-browser-carousel.png"
            driver.screenshot(carousel_frame)
            assert _frames_differ(grid_frame, carousel_frame)

            assert driver.command("page_browser_key", key="Back")["handled"] is True
            _wait_command(
                driver,
                "reader_overlay_state",
                lambda result: result.get("overlays", {}).get("page_browser") is False,
            )
            assert driver.command(
                "activate_reader_control", name="page_browser"
            )["activated"] is True
            reopened_carousel = _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "carousel",
            )["page_browser"]
            assert reopened_carousel["thumbnail_count"] == 3

            assert driver.command(
                "activate_reader_control", name="page_browser_single"
            )["activated"] is True
            single = _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "single",
            )["page_browser"]
            assert single["thumbnail_count"] == 1
            for view in (grid, single):
                slider = view["slider_bounds"]
                previous, following = view["previous_bounds"], view["next_bounds"]
                assert previous["x"] + previous["w"] < slider["x"]
                assert slider["x"] + slider["w"] < following["x"]
            single_frame = root / "page-browser-single.png"
            driver.screenshot(single_frame)
            assert _frames_differ(grid_frame, single_frame)
            assert _frames_differ(carousel_frame, single_frame)

            assert driver.command(
                "activate_reader_control", name="page_browser_grid"
            )["activated"] is True
            _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "grid",
            )

            before_search = driver.command("page_browser_state")["page_browser"]
            assert driver.command(
                "activate_reader_control", name="page_browser_search"
            )["activated"] is True
            overlay = _wait_command(
                driver,
                "reader_overlay_state",
                lambda result: result.get("overlays", {}).get("page_browser") is True,
            )["overlays"]
            assert overlay["page_browser"] is True
            assert driver.command("page_browser_state")["page_browser"]["top_is_browser"] is False
            assert driver.command("hardware_overlay_state")["overlay"]["kind"] == "search"
            search_frame = root / "reader-search.png"
            driver.screenshot(search_frame)
            assert search_frame.stat().st_size > 0
            assert driver.command("hardware_overlay_key", key="Back")["handled"] is True
            resumed = driver.command("page_browser_state")["page_browser"]
            assert resumed["top_is_browser"] is True
            assert resumed["preview_id"] == before_search["preview_id"]
            assert resumed["layout"] == before_search["layout"]
            assert resumed["focus_page"] == before_search["focus_page"]
        finally:
            stop(process)


@pytest.mark.parametrize("show_labels", [False, True])
def test_reader_highlight_and_dictionary_menus_open(show_labels: bool) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-reader-lookup-") as temporary:
        root = Path(temporary)
        ko_home, library = root / "home", root / "library"
        ko_home.mkdir()
        library.mkdir()
        book = library / "reader-lookup.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, ko_home, socket_path, library, zen_config_source=(
            "return { dict_quick_lookup = { show_labels = " + str(show_labels).lower() + " } }"
        ))
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            opened = _wait_command(
                driver, "open_book", lambda result: result.get("ok") is True,
                path=str(book),
            )
            assert opened["ok"] is True, opened
            _wait_command(
                driver,
                "reader_state",
                lambda result: result.get("reader", {}).get("open") is True,
            )

            assert driver.command(
                "activate_reader_control", name="show_highlight_menu"
            )["activated"] is True
            highlight = _wait_command(
                driver,
                "reader_overlay_state",
                lambda result: result.get("overlays", {}).get("highlight_menu") is True,
            )["overlays"]
            assert "dictionary" in highlight["highlight_controls"]

            assert driver.command(
                "activate_reader_control", name="highlight_dictionary"
            )["activated"] is True
            dictionary = _wait_command(
                driver,
                "reader_overlay_state",
                lambda result: result.get("overlays", {}).get("dictionary_menu") is True,
            )["overlays"]
            assert dictionary["highlight_menu"] is False
            buttons = [button for row in dictionary["lookup_buttons"] for button in row]
            actions = [button for button in buttons if button["icon"]]
            assert actions
            assert all(bool(button["text"]) == show_labels for button in actions)
            assert all(button["content_width"] <= button["width"] for button in buttons)
            for icon_suffix in ("vocab_remove.svg", "vocab.svg"):
                assert driver.command("activate_reader_control", name="lookup_vocabulary")["activated"]
                changed = driver.command("reader_overlay_state")["overlays"]["lookup_buttons"]
                vocabulary = next(button for row in changed for button in row if button.get("id") == "vocabulary")
                assert vocabulary["icon"].endswith(icon_suffix)
                assert vocabulary["text"] == ("Vocabulary" if show_labels else "")
                assert vocabulary["content_width"] <= vocabulary["width"]
            dictionary_frame = root / "reader-dictionary.png"
            driver.screenshot(dictionary_frame)
            assert dictionary_frame.stat().st_size > 0
        finally:
            stop(process)


@pytest.mark.parametrize("interface_enabled,page_enabled", [(True, None), (True, False), (False, True)])
def test_page_browser_status_bar_is_fixed_across_tabs_and_respects_settings(interface_enabled, page_enabled) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-browser-status-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "status.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        config = "return {features={status_bar=" + str(interface_enabled).lower() + "}"
        if page_enabled is not None:
            config += ",page_browser={show_status_bar=" + str(page_enabled).lower() + "}"
        config += "}"
        process = launch(runtime, home, socket_path, library, zen_config_source=config)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            library_status = driver.command("file_chooser_items")["file_chooser"]["status_bar"]
            assert driver.open_book(book)["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            original = driver.command("page_browser_state")["page_browser"]
            visible = interface_enabled and page_enabled is not False
            assert bool(original.get("status_bar")) is visible
            assert original["status_refresh_bound"] is visible
            if visible:
                status = original["status_bar"]
                assert status["values"]
                assert status["bounds"]["x"] == 0
                assert status["bounds"]["w"] == original["screen_width"]
                assert status["bounds"]["y"] == library_status["custom_y"]
                assert status["bounds"]["h"] == library_status["custom_height"]
                assert status["bounds"]["y"] + status["bounds"]["h"] <= original["header_tabs"]["y"]
            for tab in ("controls", "bookmarks", "toc", "pages"):
                assert driver.command("activate_reader_control", name=f"page_browser_{tab}")["activated"]
                state = driver.command("page_browser_state")["page_browser"]
                assert state["header_tabs"] == original["header_tabs"]
                assert state["header_height"] == original["header_height"]
                assert bool(state.get("status_bar")) is visible
                if tab in ("controls", "pages"):
                    painted = _wait_command(driver, "page_browser_state", lambda result:
                                            result["page_browser"]["preview_ready"])["page_browser"]
                    tabs, line = painted["header_tabs"], painted["header_divider"]
                    preview_top = painted["full_page_top"] if painted["full_page"] \
                        else min(item["bounds"]["y"] for item in painted["preview_bounds"])
                    above = line["y"] - tabs["y"] - tabs["h"]
                    below = preview_top - line["y"] - line["h"]
                    assert above > 0 and abs(above - below) <= 1
                if visible:
                    assert state["status_bar"]["bounds"] == original["status_bar"]["bounds"]
                    frame_dir = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser"
                    frame_dir.mkdir(parents=True, exist_ok=True)
                    driver.screenshot(frame_dir / f"status-bar-{tab}.png")
                if tab == "controls":
                    controls = driver.command("reader_controls")
                    assert controls["settings_rows"] == 3
                    assert controls["menu_bottom"] == controls["screen_height"]
                    scale = min(state["screen_width"], state["screen_height"]) / 600
                    assert state["panel_height"] == min(math.ceil(226 * scale), state["screen_height"] * 0.45)
                    assert state["preview_geometry"]["h"] < original["preview_geometry"]["h"]
                elif tab == "pages":
                    assert state["preview_geometry"] == original["preview_geometry"]
                    panel_top = state["screen_height"] - state["panel_height"]
                    top_padding = state["chapter_bounds"]["y"] - panel_top
                    following = state["next_bounds"]
                    bottom_padding = state["screen_height"] - following["y"] - following["h"]
                    assert bottom_padding == top_padding
            assert driver.command("refresh_clock")["ok"]
            refreshed = driver.command("page_browser_state")["page_browser"]
            assert refreshed["header_tabs"] == original["header_tabs"]
            assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_reader_settings")["activated"]
            settings = driver.command("settings_page_state")["settings"]
            assert settings["labels"] == ["Top status bar", "Tabs"]
            assert settings["items"][0]["checked"] is (page_enabled is not False)
            assert settings["items"][0]["enabled"] is interface_enabled
            if interface_enabled:
                assert driver.command("settings_page_select", label="Top status bar")["ok"]
            assert driver.command("close_settings_page")["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            reopened = driver.command("page_browser_state")["page_browser"]
            assert bool(reopened.get("status_bar")) is (interface_enabled and not visible)
        finally:
            stop(process)


@pytest.mark.parametrize("pages", [1, 6])
def test_page_browser_pdf_uses_embedded_fixed_layout_controls(pages: int) -> None:
    from test_emulator_reader_controls import _write_pdf

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-page-browser-pdf-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "preview.pdf"
        _write_pdf(book, pages)
        if pages > 1:
            patches = home / "patches"
            patches.mkdir()
            # Match a monochrome Kobo with a 32-bit framebuffer and catch freed tiles before native blitting.
            (patches / "2-zen-pdf-thumbnail-cache.lua").write_text('''
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local bb = Screen.bb
Screen.bb = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BBRGB32)
Screen.bb:fill(Blitbuffer.COLOR_WHITE)
bb:free()
G_reader_settings:saveSetting("page_browser_preload_thumbnails", true)
local freed = setmetatable({}, { __mode = "k" })
local Tile = require("document/tilecacheitem")
local original_free = Tile.onFree
function Tile:onFree()
    freed[self.bb] = true
    return original_free(self)
end
local Image = require("ui/widget/imagewidget")
local original_paint = Image.paintTo
function Image:paintTo(...)
    assert(not freed[self.image], "painting an evicted PDF thumbnail")
    return original_paint(self, ...)
end
''', encoding="utf-8")
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library,
                         env_overrides={"EMULATE_BW_SCREEN": "1"} if pages > 1 else None)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            browser = _wait_command(driver, "page_browser_state", lambda result:
                                    result["page_browser"]["preview_ready"])["page_browser"]
            if pages > 1:
                time.sleep(8)  # Let background thumbnails fill the cache without touching a setting.
                assert process.poll() is None
            assert browser["active_tab"] == "aa" and not browser["browser_buttons_visible"]
            state = driver.command("reader_controls")
            assert state["active_tab"] == "aa" and not state.get("font_family_label")
            assert state["subsections"] == ["contrast", "page", "document"]
            assert state["color_options"] and state["slider_bounds"]
            assert len(state["settings_dividers"]) == state["settings_rows"] - 1
            assert all(line["light_gray"] for line in state["settings_dividers"])
            frame_dir = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser"
            frame_dir.mkdir(parents=True, exist_ok=True)
            driver.screenshot(frame_dir / "pdf-aa.png")
            assert driver.command("activate_reader_control", name="page_browser_section_document")["activated"]
            state = driver.command("reader_controls", action="choose", id="zoom_mode_genus_1")
            assert state["config"]["zoom_mode_genus"] == 4
            state = driver.command("reader_controls", action="choose", id="zoom_mode_type_1")
            assert state["config"]["zoom_mode_type"] == 2
            browser = _wait_command(driver, "page_browser_state", lambda result:
                                    result["page_browser"]["preview_ready"])["page_browser"]
            before = root / "fit-full.png"
            driver.screenshot(before)
            state = driver.command("reader_controls", action="choose", id="zoom_mode_type_2")
            assert state["config"]["zoom_mode_type"] == 1
            _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
            after = root / "fit-width.png"
            driver.screenshot(after)
            crop = (0, browser["header_height"] + browser["edge_padding"],
                    browser["screen_width"], browser["screen_height"] - browser["panel_height"] - 2)
            with Image.open(before) as original, Image.open(after) as changed:
                assert ImageChops.difference(original.crop(crop), changed.crop(crop)).getbbox() is not None
            assert driver.command("activate_reader_control", name="page_browser_preview_center")["activated"]
            assert driver.command("page_browser_state").get("page_browser") is None
        finally:
            stop(process)


@pytest.mark.parametrize("document_type,width", [
    ("epub", None), ("pdf", None), ("cbz", None), ("epub", 758), ("pdf", 758),
], ids=["epub", "pdf", "cbz", "epub-758", "pdf-758"])
def test_page_browser_settings_subsections_and_themes(document_type: str, width: int | None) -> None:
    from io import BytesIO
    from test_emulator_reader_controls import _write_pdf

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-settings-sections-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / f"settings.{document_type}"
        if document_type == "epub":
            _write_reader_epub(book)
        elif document_type == "pdf":
            _write_pdf(book)
        else:
            buffer = BytesIO()
            Image.new("RGB", (600, 800), "white").save(buffer, format="PNG")
            with zipfile.ZipFile(book, "w") as archive:
                archive.writestr("001.png", buffer.getvalue())
        socket_path = root / "driver.sock"
        window_scale = 2 if sys.platform == "darwin" and os.environ.get("SDL_VIDEODRIVER") != "dummy" else 1
        overrides = {"EMULATE_READER_W": str(width // window_scale),
                     "EMULATE_READER_H": str(1024 // window_scale)} if width else None
        check_more_menu = document_type == "epub" and width is None
        # Annotations tab has its own more-menu; start full page off to exercise toggling on
        config = "return {page_browser={tabs={annotations=true},font_full_page=false,contrast_full_page=false}}"
        process = launch(runtime, home, socket_path, library, env_overrides=overrides, zen_config_source=config)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            if check_more_menu:
                _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
                assert [row["text"] for row in _page_browser_more_rows(driver)] == ["Reader controls", "Settings"]
                more_frame = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser" / "header-reader-menu.png"
                more_frame.parent.mkdir(parents=True, exist_ok=True)
                driver.screenshot(more_frame)
                assert driver.command("activate_reader_control", name="page_browser_reader_controls")["activated"]
                assert driver.command("page_browser_state").get("page_browser") is None
                assert _wait_command(driver, "reader_controls", lambda result: result.get("menu_open"))["active_tab"] == "reader_controls"
                driver.command("reader_controls", action="close")
                assert driver.command("activate_reader_control", name="page_browser")["activated"]
            for tab in ("pages", "annotations", "toc"):
                assert driver.command("activate_reader_control", name=f"page_browser_{tab}")["activated"]
                assert [row["text"] for row in _page_browser_more_rows(driver)] == ["Reader controls", "Settings"]
                assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
            first = driver.command("reader_controls")
            if width:
                assert first["screen_width"] == width
            expected = ["Font", "Layout", "Themes"] if document_type == "epub" else ["Contrast", "Page", "Document"]
            assert first["subsection_labels"] == expected
            tabs, pager = first["section_tabs"], first.get("pager")
            if pager is None:
                # Single-page contrast has no pager; Document always paginates.
                assert driver.command("activate_reader_control", name="page_browser_section_document")["activated"]
                pager = driver.command("reader_controls")["pager"]
                assert driver.command("activate_reader_control",
                                      name=f"page_browser_section_{first['section']}")["activated"]
            scale = min(first["screen_width"], first["screen_height"]) / 600
            assert pager["h"] == math.ceil(32 * scale)
            assert 0 < tabs["y"] - pager["y"] - pager["h"] < pager["h"]
            original_preview = driver.command("page_browser_state")["page_browser"]
            frame_dir = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser"
            frame_dir.mkdir(parents=True, exist_ok=True)
            pages = {}
            theme_names = set()
            for section in first["subsections"]:
                assert driver.command("activate_reader_control", name=f"page_browser_section_{section}")["activated"]
                choices = _page_browser_more_rows(driver)
                expected_choices = ["Show full page", "Reader controls"] if section in ("font", "contrast") else ["Reader controls", "Settings"]
                assert [row["text"].removesuffix(" ✓") for row in choices] == expected_choices
                assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
                state = driver.command("reader_controls")
                assert state["section"] == section and state["page"] == 1
                for page in range(1, state["page_num"] + 1):
                    state = driver.command("reader_controls", action="paint")
                    assert state["section"] == section and state["page"] == page
                    assert state["section_tabs"] == tabs
                    assert state.get("pager") == (pager if state["page_num"] > 1 else None)
                    assert state["menu_top"] == first["menu_top"] and state["menu_bottom"] == first["menu_bottom"]
                    assert state["menu_bottom"] - state["menu_top"] == math.ceil(226 * scale)
                    assert driver.command("page_browser_state")["page_browser"]["preview_id"] == original_preview["preview_id"]
                    if document_type == "epub" and section == "font" and page <= 2:
                        suffix = f"-{width}" if width else ""
                        driver.screenshot(frame_dir / f"current-font-{page}{suffix}.png")
                    elif width and section == "contrast" and page <= 2:
                        driver.screenshot(frame_dir / f"current-contrast-{page}-{width}.png")
                    assert 1 <= state["settings_rows"] <= 3, (section, page, state)
                    dividers = state["settings_dividers"]
                    assert len(dividers) == state["settings_rows"] - 1
                    assert len({line["y"] for line in dividers}) == len(dividers)
                    assert all(state["menu_top"] < line["y"] < pager["y"] and line["light_gray"] for line in dividers)
                    assert all(line["x"] == 0 and line["width"] == state["screen_width"] for line in dividers)
                    # Padding only fills spare space; tightly packed pages may have none.
                    assert all(line["spacing"] >= 0 for line in dividers)
                    rows = state["settings_row_bounds"]
                    assert len(rows) == state["settings_rows"]
                    assert rows[0]["y"] > state["menu_top"]
                    assert rows[-1]["y"] + rows[-1]["h"] <= pager["y"]
                    for index, line in enumerate(dividers):
                        padding = line["spacing"] / 2
                        assert rows[0]["y"] - state["menu_top"] == line["height"] + padding
                        assert line["y"] - rows[index]["y"] - rows[index]["h"] == padding
                        assert rows[index + 1]["y"] - line["y"] - line["height"] == padding
                    if section in ("font", "contrast") and state["settings_rows"] == 3:
                        last_setting = rows[-1]["y"] + rows[-1]["h"]
                        assert 0 <= pager["y"] - last_setting <= math.ceil(4 * scale)
                    if state["page_num"] > 1:
                        previous, next_button = state["pager_buttons"]
                        for button in (previous, next_button):
                            assert button["w"] == button["h"] == math.ceil(32 * scale)
                            assert button["icon_width"] == button["icon_height"] == math.ceil(28 * scale)
                            assert button["y"] == pager["y"]
                        assert previous["x"] == math.ceil(12 * scale)
                        assert next_button["x"] + next_button["w"] == state["screen_width"] - previous["x"]
                    else:
                        assert not state["pager_buttons"]
                    cells = state["value_cells"]
                    assert set(cells) == set(state["slider_bounds"])
                    assert len({cell["x"] + cell["w"] for cell in cells.values()}) <= 1
                    for name, cell in cells.items():
                        plus = state["bounds"][name + "_increase"]
                        assert cell["x"] >= plus["x"] + plus["w"]
                        assert cell["title_x"] == math.ceil(12 * scale)
                        assert cell["text_x"] + cell["text_width"] == cell["x"] + cell["w"]
                        assert cell["title_x"] + cell["title_width"] <= state["bounds"][name + "_decrease"]["x"]
                        assert state["bounds"][name]["h"] <= math.ceil(42 * scale)
                    for slider in state["slider_states"].values():
                        if slider.get("presets"):
                            assert slider["visible_presets"] >= min(7, len(slider["presets"]))
                    if section == "themes":
                        assert not theme_names.intersection(state["radios"])
                        theme_names.update(state["radios"])
                        assert "Reader theme settings" not in state["controls"]
                        assert "reader_theme_more" not in state["controls"]
                    if page < state["page_num"]:
                        assert driver.command("activate_reader_control", name="page_browser_font_next")["activated"]
                pages[section] = state["page_num"]
                if state["page_num"] > 1:
                    assert driver.command("activate_reader_control", name="page_browser_font_next")["activated"]
                    assert driver.command("reader_controls")["page"] == 1
                    assert driver.command("activate_reader_control", name="page_browser_font_previous")["activated"]
                    assert driver.command("reader_controls")["page"] == pages[section]
            for section in first["subsections"]:
                assert driver.command("activate_reader_control", name=f"page_browser_section_{section}")["activated"]
                assert driver.command("reader_controls")["page"] == pages[section]
            assert driver.command("activate_reader_control", name="page_browser_section_page")["activated"]
            remembered_page = driver.command("reader_controls")["page"]
            for tab in ("pages", "annotations", "toc", "controls"):
                assert driver.command("activate_reader_control", name=f"page_browser_{tab}")["activated"]
            restored = driver.command("reader_controls")
            assert restored["section"] == "page" and restored["page"] == remembered_page
            assert driver.command("page_browser_key", key="Back")["handled"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["active_tab"] == "aa"
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            restored = driver.command("reader_controls")
            assert restored["section"] == "page" and restored["page"] == remembered_page
            # Reader themes do not affect fixed-layout documents.
            if document_type == "epub":
                assert driver.command("activate_reader_control", name="page_browser_section_themes")["activated"]
                for _page in range(pages["themes"] - 1):
                    assert driver.command("activate_reader_control", name="page_browser_font_previous")["activated"]
                themes = driver.command("reader_controls")
                assert themes["theme_count"] > 0
                assert "reader_theme_more" not in themes["controls"]
                driver.screenshot(frame_dir / (f"current-themes-{width}.png" if width else "current-themes.png"))
                assert driver.command("reader_controls")["section"] == "themes"
                chosen = driver.command("reader_controls", action="choose", id="Light sepia")
                assert chosen["global_themes"]["light_mode"] == "light_sepia"
                _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
            else:
                assert "themes" not in first["subsections"]
            assert driver.command("page_browser_state")["page_browser"]["top_is_browser"]
            driver.screenshot(frame_dir / f"sections-{document_type}.png")
            section = "font" if document_type == "epub" else "contrast"
            assert driver.command("activate_reader_control", name=f"page_browser_section_{section}")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_full_page")["activated"]
            other = "themes" if document_type == "epub" else "document"
            assert driver.command("activate_reader_control", name=f"page_browser_section_{other}")["activated"]
            full = driver.command("page_browser_state")["page_browser"]
            assert full["full_page"] and full["preview_divider"]["y"] == first["menu_top"]
            assert driver.command("reader_controls")["section"] == other
            assert [row["text"] for row in _page_browser_more_rows(driver)] == ["Reader controls", "Settings"]
            assert driver.command("activate_reader_control", name="page_browser_reader_controls")["activated"]
            assert driver.command("page_browser_state").get("page_browser") is None
            controls = _wait_command(driver, "reader_controls", lambda result: result.get("menu_open"))
            assert controls["active_tab"] == "reader_controls"
            driver.command("reader_controls", action="close")
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert [row["text"] for row in _page_browser_more_rows(driver)] == ["Reader controls", "Settings"]
            assert driver.command("activate_reader_control", name="page_browser_reader_settings")["activated"]
            assert driver.command("page_browser_state").get("page_browser") is None
            settings = _wait_command(driver, "settings_page_state", lambda result: result.get("ok"))["settings"]
            assert settings["labels"] == ["Top status bar", "Tabs"]
            assert driver.command("close_settings_page")["ok"]
        finally:
            stop(process)


@pytest.mark.parametrize("document_type", ["epub", "pdf"])
def test_page_browser_font_full_page_matches_reader_and_is_remembered(document_type: str) -> None:
    from test_emulator_reader_controls import _write_pdf

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-full-page-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / f"full-page.{document_type}"
        (_write_reader_epub if document_type == "epub" else _write_pdf)(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, home, socket_path, library,
                         zen_config_source="return {page_browser={font_full_page=false,contrast_full_page=false}}")
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            reading = root / "reading.png"
            driver.screenshot(reading)
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
            menu = driver.command("page_browser_state")["page_browser"]
            assert menu["more_bounds"]["x"] + menu["more_bounds"]["w"] <= menu["close_bounds"]["x"]
            assert menu["more_menu"]["text"] == "Show full page" and menu["more_menu"]["enabled"]
            assert menu["more_menu"]["bounds"]["x"] >= menu["edge_padding"] / 2
            assert menu["more_menu"]["bounds"]["x"] + menu["more_menu"]["bounds"]["w"] <= menu["screen_width"] - menu["edge_padding"] / 2
            assert driver.command("activate_reader_control", name="page_browser_full_page")["activated"]
            full = _wait_command(driver, "page_browser_state", lambda result:
                                 result["page_browser"]["full_page"] and result["page_browser"]["preview_ready"])["page_browser"]
            frame_dir = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser"
            frame_dir.mkdir(parents=True, exist_ok=True)
            preview = frame_dir / f"full-page-{document_type}.png"
            driver.screenshot(preview)
            with Image.open(reading) as actual, Image.open(preview) as shown:
                crop = (0, full["full_page_top"], actual.width, actual.height - full["full_page_bottom"])
                assert ImageChops.difference(actual.crop(crop), shown.crop(crop)).getbbox() is None
                assert full["full_page_bounds"]["w"] == actual.width
                assert full["full_page_bounds"]["h"] == actual.height
            if document_type == "epub":
                assert driver.command("activate_reader_control", name="page_browser_preview_swipe_next")["activated"]
                assert driver.command("page_browser_state")["page_browser"]["focus_page"] == 2
                assert driver.command("reader_state")["reader"]["page"] == 1
                assert driver.command("activate_reader_control", name="page_browser_preview_swipe_previous")["activated"]
                driver.command("reader_controls", action="choose", id="font_size_increase")
                changed = root / "changed.png"
                driver.screenshot(changed)
                assert _frames_differ(preview, changed)
            assert driver.command("activate_reader_control", name="page_browser_preview_center")["activated"]
            assert driver.command("page_browser_state").get("page_browser") is None
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["active_tab"] == "aa"
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["full_page"]
            stop(process)
            process = launch(runtime, home, socket_path, library, initialize_settings=False)
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["full_page"]
            assert driver.command("activate_reader_control", name="page_browser_top_swipe")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["more_menu"]["text"] == "Show full page ✓"
            assert driver.command("activate_reader_control", name="page_browser_full_page")["activated"]
            assert not driver.command("page_browser_state")["page_browser"]["full_page"]
            assert [row["text"] for row in _page_browser_more_rows(driver)] == ["Show full page", "Reader controls"]
            assert driver.command("activate_reader_control", name="page_browser_reader_controls")["activated"]
            assert driver.command("page_browser_state").get("page_browser") is None
            controls = _wait_command(driver, "reader_controls", lambda result: result.get("menu_open"))
            assert controls["active_tab"] == "reader_controls"
            assert controls["menu_bottom"] == controls["screen_height"]
        finally:
            stop(process)


@pytest.mark.parametrize("custom_icons", [False, True])
def test_page_browser_icon_pack_and_layout_menu(custom_icons: bool) -> None:
    import json

    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-browser-icons-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        pack = home / "icons" / "zen" / "browser"
        pack.mkdir(parents=True)
        (pack / "pack.json").write_text(json.dumps({"schema_version": 1, "id": "browser", "name": "Browser"}))
        header_names = ["more_vertical", "view_carousel_outline", "font", "bookmark_outline", "lookup_highlight", "toc",
                        "annotations", "info", "close"]
        names = header_names + ["grid", "grid_slide", "coverflow", "chevron.left", "chevron.right", "quick_search",
                                "quicksettings", "settings_cog", "plus", "filter", "sort", "pin", "pin_remove",
                                "bookmark", "bookmark_remove"]
        for name in names:
            (pack / (name + ".svg")).write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">'
                '<circle cx="12" cy="12" r="8" fill="#C04060"/></svg>'
            )
        book = library / "icons.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        config = ('return {features={custom_icons_enabled=' + str(custom_icons).lower()
                  + '},custom_icons={active_pack="browser"},page_browser={tabs={annotations=true,book_details=true}}}')
        process = launch(runtime, home, socket_path, library, zen_config_source=config)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.open_book(book)["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            state = driver.command("page_browser_state")["page_browser"]
            assert state["header_icons"] == [name + ".svg" for name in header_names]
            assert driver.command("activate_reader_control", name="page_browser_book_details")["activated"]
            state = driver.command("page_browser_state")["page_browser"]
            assert state["active_tab"] == "book_details" and state["top_is_browser"] is True
            details = state["book_info"]
            assert details["title_bar"] is False
            assert details["bounds"]["y"] == state["header_height"]
            assert state["content_bottom"] == state["screen_height"] - state["edge_padding"]
            frame_dir = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser"
            frame_dir.mkdir(parents=True, exist_ok=True)
            driver.screenshot(frame_dir / ("book-info-custom.png" if custom_icons else "book-info-default.png"))
            assert driver.command("activate_reader_control", name="page_browser_pages")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["active_tab"] == "browser"
            _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
            assert driver.command("activate_reader_control", name="page_browser_preview_hold")["activated"]
            actions = driver.command("page_browser_state")["page_browser"]["page_action_buttons"]
            assert actions[0][0]["icon"].endswith("/bookmark.svg")
            assert driver.command("activate_reader_control", name="page_browser_bookmark_page")["activated"]
            _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
            original = driver.command("reference_action", action="state")["references"]
            preview = driver.command("page_browser_state")["page_browser"]
            assert preview["preview_bookmarked"]
            bounds = next(item["image_bounds"] for item in preview["preview_bounds"]
                          if item.get("page") == preview["focus_page"])
            scale = min(preview["screen_width"], preview["screen_height"]) / 600
            extent = math.ceil(40 * scale)
            corner = (bounds["x"] + bounds["w"] - extent, bounds["y"],
                      bounds["x"] + bounds["w"], bounds["y"] + extent)
            preview_scale = max(bounds["w"] / preview["screen_width"], bounds["h"] / preview["screen_height"])
            bookmark_size = math.floor(preview["preview_bookmark_icon_width"] * preview_scale + 0.5)
            bookmark_corner = (bounds["x"] + bounds["w"] - bookmark_size, bounds["y"],
                               bounds["x"] + bounds["w"], bounds["y"] + bookmark_size)
            before = frame_dir / f"pin-preview-before-{custom_icons}.png"
            driver.screenshot(before)
            for pinned in (True, False):
                assert driver.command("activate_reader_control", name="page_browser_preview_hold")["activated"]
                actions = driver.command("page_browser_state")["page_browser"]
                assert actions["page_actions_open"]
                assert actions["page_action_buttons"][0][0]["icon"].endswith("/bookmark_remove.svg")
                button = actions["page_action_buttons"][0][1]
                assert button["icon"].endswith("/pin.svg" if pinned else "/pin_remove.svg")
                assert button["icon_width"] == math.ceil(32 * scale)
                assert button["height"] <= math.ceil(40 * scale) + 1
                assert driver.command("activate_reader_control", name="page_browser_pin_page")["activated"]
                _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
                refs = driver.command("reference_action", action="state")["references"]
                assert bool(refs["pins"]) is pinned and refs["page"] == original["page"]
                assert refs["annotations"] == original["annotations"]
                after = frame_dir / f"pin-preview-{pinned}-{custom_icons}.png"
                driver.screenshot(after)
                difference = ImageChops.difference(Image.open(before).convert("RGB").crop(corner),
                                                  Image.open(after).convert("RGB").crop(corner)).getbbox()
                assert bool(difference) is pinned
                assert ImageChops.difference(Image.open(before).convert("RGB").crop(bookmark_corner),
                                             Image.open(after).convert("RGB").crop(bookmark_corner)).getbbox() is None
            assert driver.command("activate_reader_control", name="page_browser_preview_hold")["activated"]
            driver.screenshot(frame_dir / f"bookmark-remove-{custom_icons}.png")
            assert driver.command("activate_reader_control", name="page_browser_bookmark_page")["activated"]
            preview = _wait_command(driver, "page_browser_state", lambda result: result["page_browser"]["preview_ready"])
            assert not preview["page_browser"]["preview_bookmarked"]
            paths = list(zip(header_names, state["header_paths"]))
            for control, name in {"grid": "grid", "search": "quick_search",
                                  "previous": "chevron.left", "next": "chevron.right"}.items():
                paths.append((name, state["footer_icons"][control]))
            more_rows = _page_browser_more_rows(driver)
            assert [row["text"] for row in more_rows] == ["Reader controls", "Settings"]
            paths.extend(zip(["quicksettings", "settings_cog"], [row["icon"] for row in more_rows]))
            assert driver.command("activate_reader_control", name="page_browser_more")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_section_themes")["activated"]
            assert "reader_theme_more" not in driver.command("reader_controls")["controls"]
            assert driver.command("activate_reader_control", name="page_browser_pages")["activated"]
            assert driver.command("activate_reader_control", name="page_browser_layout_menu")["activated"]
            menu = _wait_command(driver, "page_browser_state", lambda result:
                                 result["page_browser"].get("layout_menu", {}).get("bounds"))["page_browser"]["layout_menu"]
            assert menu["count"] == 3
            for row, name in zip(menu["rows"], ["grid_slide", "coverflow", "grid"]):
                assert row["align"] == "left" and row["padding_left"] == row["padding_right"] > 0
                paths.append((name, row["icon"]))
            assert [row["text"].removesuffix(" ✓") for row in menu["rows"]] == ["Single page", "Carousel", "Grid"]
            frame_dir = Path(__file__).resolve().parents[2] / ".artifacts" / "page-browser"
            frame_dir.mkdir(parents=True, exist_ok=True)
            driver.screenshot(frame_dir / ("layout-custom.png" if custom_icons else "layout-default.png"))
            assert driver.command("activate_reader_control", name="page_browser_single")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["layout"] == "single"
            assert driver.command("activate_reader_control", name="page_browser_annotations")["activated"]
            assert driver.command("annotation_viewer_action", action="more")["ok"]
            annotation_rows = _wait_command(driver, "page_browser_state", lambda result:
                                            result["page_browser"].get("more_menu", {}).get("bounds"))["page_browser"]["more_menu"]["rows"]
            assert [row["text"] for row in annotation_rows] == ["New note", "Filter", "Sort", "Settings"]
            paths.extend(zip(["plus", "filter", "sort", "settings_cog"], [row["icon"] for row in annotation_rows]))
            for name, path in paths:
                if custom_icons:
                    assert Path(path).resolve() == (pack / (name + ".svg")).resolve()
                else:
                    assert "/icons/zen/browser/" not in path
                    if name == "close":
                        assert Path(path).resolve() == (runtime / "resources/icons/mdlight/close.svg").resolve()
                    elif name == "quick_search":
                        assert Path(path).resolve() == (runtime / "plugins/zenos.koplugin/icons/quick_search.svg").resolve()
        finally:
            stop(process)
