import os
import signal
import tempfile
import time
import zipfile
from pathlib import Path

import pytest
from PIL import Image, ImageChops

from zen_driver import ZenDriver, launch, wait_for_socket


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
            "features = { reader_themes = true }, "
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
            for label in ("Reader", "Reader themes", mode + ": Default", "Light tan"):
                assert driver.command("settings_page_select", label=label)["ok"]
            assert driver.command("close_settings_page")["ok"]
            first_frame = root / "first.png"
            driver.screenshot(first_frame)
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
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def test_reader_page_browser_modes_and_aa_menu_render() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-reader-tools-") as temporary:
        root = Path(temporary)
        ko_home, library = root / "home", root / "library"
        ko_home.mkdir()
        library.mkdir()
        book = library / "reader-tools.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, ko_home, socket_path, library)
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
            assert {"single", "carousel", "grid", "aa"}.issubset(
                default_carousel["controls"]
            )
            assert default_carousel["focused"] == "header:1"

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

            assert driver.command(
                "activate_reader_control", name="page_browser_toc"
            )["activated"] is True
            toc = _wait_command(
                driver,
                "hardware_overlay_state",
                lambda result: result.get("overlay", {}).get("kind") == "toc",
            )["overlay"]
            assert toc["focused"] == "back"
            assert driver.command("hardware_overlay_key", key="Down")["handled"] is True
            assert _wait_command(
                driver,
                "hardware_overlay_state",
                lambda result: result.get("overlay", {}).get("focused") == "entry",
            )["overlay"]["kind"] == "toc"
            assert driver.command("hardware_overlay_key", key="Back")["handled"] is True
            _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "grid",
            )

            assert driver.command(
                "activate_reader_control", name="page_browser_book_info"
            )["activated"] is True
            book_info = _wait_command(
                driver,
                "hardware_overlay_state",
                lambda result: result.get("overlay", {}).get("kind") == "book_info",
            )["overlay"]
            assert book_info["focused"] == "back"
            assert driver.command("hardware_overlay_key", key="Down")["handled"] is True
            assert _wait_command(
                driver,
                "hardware_overlay_state",
                lambda result: result.get("overlay", {}).get("focused") == "description",
            )["overlay"]["kind"] == "book_info"
            assert driver.command("hardware_overlay_key", key="Back")["handled"] is True

            _wait_command(
                driver,
                "page_browser_state",
                lambda result: result.get("page_browser", {}).get("layout") == "grid",
            )
            assert driver.command(
                "activate_reader_control", name="page_browser_bookmarks"
            )["activated"] is True
            bookmarks = _wait_command(
                driver,
                "hardware_overlay_state",
                lambda result: result.get("overlay", {}).get("kind") == "bookmarks",
            )["overlay"]
            assert bookmarks["focused"] == "back"
            assert driver.command("hardware_overlay_key", key="Back")["handled"] is True

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

            assert driver.command(
                "activate_reader_control", name="page_browser_aa"
            )["activated"] is True
            overlay = _wait_command(
                driver,
                "reader_overlay_state",
                lambda result: result.get("overlays", {}).get("aa_menu") is True
                and result.get("overlays", {}).get("page_browser") is False,
            )["overlays"]
            assert overlay["page_browser"] is False
            aa_frame = root / "reader-aa-menu.png"
            driver.screenshot(aa_frame)
            assert aa_frame.stat().st_size > 0
        finally:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=15)


def test_reader_highlight_and_dictionary_menus_open() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-reader-lookup-") as temporary:
        root = Path(temporary)
        ko_home, library = root / "home", root / "library"
        ko_home.mkdir()
        library.mkdir()
        book = library / "reader-lookup.epub"
        _write_reader_epub(book)
        socket_path = root / "driver.sock"
        process = launch(runtime, ko_home, socket_path, library)
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
            dictionary_frame = root / "reader-dictionary.png"
            driver.screenshot(dictionary_frame)
            assert dictionary_frame.stat().st_size > 0
        finally:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=15)
