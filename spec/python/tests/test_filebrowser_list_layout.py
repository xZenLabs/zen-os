import os
import signal
import sqlite3
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path

import pytest
from PIL import Image

from zen_driver import ZenDriver, launch, normalize_visible_text, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1",
    reason="set ZEN_UI_RUN_EMULATOR=1 to run a real KOReader emulator",
)


def _write_metadata_epub(path: Path) -> None:
    container = b"""<?xml version='1.0'?>
<container version='1.0' xmlns='urn:oasis:names:tc:opendocument:xmlns:container'>
  <rootfiles><rootfile full-path='OEBPS/content.opf'
    media-type='application/oebps-package+xml'/></rootfiles>
</container>"""
    package = b"""<?xml version='1.0' encoding='UTF-8'?>
<package version='2.0' unique-identifier='book-id'
  xmlns='http://www.idpf.org/2007/opf' xmlns:opf='http://www.idpf.org/2007/opf'
  xmlns:dc='http://purl.org/dc/elements/1.1/'>
  <metadata>
    <dc:identifier id='book-id'>zen-semantic-row</dc:identifier>
    <dc:title>Semantic Title</dc:title>
    <dc:creator opf:role='aut'>Zen Author</dc:creator>
    <dc:language>en</dc:language>
    <dc:subject>Focus</dc:subject>
    <dc:subject>Testing</dc:subject>
    <meta name='calibre:series' content='Semantic Series'/>
    <meta name='calibre:series_index' content='2'/>
  </metadata>
  <manifest>
    <item id='chapter' href='chapter.xhtml' media-type='application/xhtml+xml'/>
  </manifest>
  <spine><itemref idref='chapter'/></spine>
</package>"""
    chapter = b"""<html xmlns='http://www.w3.org/1999/xhtml'>
<head><title>Semantic fixture</title></head><body><p>Fixture text.</p></body></html>"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("mimetype", b"application/epub+zip")
        archive.writestr("META-INF/container.xml", container)
        archive.writestr("OEBPS/content.opf", package)
        archive.writestr("OEBPS/chapter.xhtml", chapter)


def _write_page_count_cbz(path: Path, temporary: Path) -> None:
    image_path = temporary / "page.png"
    Image.new("RGB", (60, 90), (48, 96, 144)).save(image_path)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.write(image_path, "001.png")
        archive.write(image_path, "002.png")


def _seed_bookinfo(
    ko_home: Path, book: Path, page_count_book: Path | None = None
) -> None:
    database = ko_home / "settings" / "bookinfo_cache.sqlite3"
    database.parent.mkdir(parents=True, exist_ok=True)
    canonical = book.resolve()
    stat = canonical.stat()
    with sqlite3.connect(database) as connection:
        connection.executescript("""
            PRAGMA user_version=20201210;
            CREATE TABLE bookinfo (
                bcid INTEGER PRIMARY KEY AUTOINCREMENT,
                directory TEXT NOT NULL, filename TEXT NOT NULL,
                filesize INTEGER, filemtime INTEGER, in_progress INTEGER,
                unsupported TEXT, cover_fetched TEXT, has_meta TEXT,
                has_cover TEXT, cover_sizetag TEXT, ignore_meta TEXT,
                ignore_cover TEXT, pages INTEGER, title TEXT, authors TEXT,
                series TEXT, series_index REAL, language TEXT, keywords TEXT,
                description TEXT, cover_w INTEGER, cover_h INTEGER,
                cover_bb_type INTEGER, cover_bb_stride INTEGER, cover_bb_data BLOB
            );
            CREATE UNIQUE INDEX dir_filename ON bookinfo(directory, filename);
            CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT);
        """)
        connection.execute(
            """INSERT INTO bookinfo (
                directory, filename, filesize, filemtime, in_progress,
                cover_fetched, has_meta, title, authors, series,
                series_index, language, keywords
            ) VALUES (?, ?, ?, ?, 0, 'Y', 'Y', ?, ?, ?, ?, 'en', ?)""",
            (
                str(canonical.parent) + "/",
                canonical.name,
                stat.st_size,
                int(stat.st_mtime),
                "Semantic Title",
                "Zen Author",
                "Semantic Series",
                2,
                "Focus, Testing",
            ),
        )
        if page_count_book:
            page_count_canonical = page_count_book.resolve()
            page_count_stat = page_count_canonical.stat()
            connection.execute(
                """INSERT INTO bookinfo (
                    directory, filename, filesize, filemtime, in_progress,
                    cover_fetched, has_meta, pages
                ) VALUES (?, ?, ?, ?, 0, 'Y', 'Y', 2)""",
                (
                    str(page_count_canonical.parent) + "/",
                    page_count_canonical.name,
                    page_count_stat.st_size,
                    int(page_count_stat.st_mtime),
                ),
            )
        connection.execute(
            "INSERT INTO config (key, value) VALUES (?, ?)",
            ("filemanager_display_mode", "list_image_meta"),
        )


def _texts(node: object) -> set[str]:
    found: set[str] = set()
    if isinstance(node, dict):
        value = node.get("text")
        if isinstance(value, str):
            found.add(value)
        for child in node.get("children", []):
            found.update(_texts(child))
    elif isinstance(node, list):
        for child in node:
            found.update(_texts(child))
    return found


def test_metadata_list_rows_render_all_semantic_values() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-list-layout-") as temporary:
        root = Path(temporary)
        ko_home = root / "home"
        ko_home.mkdir()
        library = root / "library"
        library.mkdir()
        semantic_book = library / "semantic.epub"
        _write_metadata_epub(semantic_book)
        page_count_book = library / "pages.cbz"
        _write_page_count_cbz(page_count_book, root)
        _seed_bookinfo(ko_home, semantic_book, page_count_book)
        socket_path = root / "driver.sock"
        process = launch(runtime, ko_home, socket_path, library)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            expected = {
                "Semantic Title",
                "Zen Author",
                "#2 – Semantic Series",
                "New",
                "2\N{NO-BREAK SPACE}pages",
                "EPUB",
                "CBZ",
            }
            deadline = time.monotonic() + 30
            visible: set[str] = set()
            tags_visible = False
            while time.monotonic() < deadline:
                response = driver.command("file_chooser_items")
                chooser = response.get("file_chooser", {})
                visible = {
                    normalize_visible_text(text)
                    for text in chooser.get("visible_texts", [])
                    if isinstance(text, str)
                }
                if not visible:
                    visible = {
                        normalize_visible_text(text)
                        for text in _texts(driver.visible_ui().get("ui", {}))
                    }
                tags_visible = any(
                    "Focus" in text and "Testing" in text for text in visible
                ) or {"Focus", "Testing"} <= visible
                if expected <= visible and tags_visible:
                    break
                time.sleep(0.25)
            assert expected <= visible, f"missing list-row values: {sorted(expected - visible)}"
            assert tags_visible, f"missing rendered tags in: {sorted(visible)}"
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def test_double_tap_opening_in_list_mode() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-list-double-tap-") as temporary:
        root = Path(temporary)
        ko_home = root / "home"
        ko_home.mkdir()
        library = root / "library"
        library.mkdir()
        book = library / "semantic.epub"
        _write_metadata_epub(book)
        _seed_bookinfo(ko_home, book)
        socket_path = root / "driver.sock"
        process = launch(
            runtime,
            ko_home,
            socket_path,
            library,
            zen_config_source="""return {
  updater = { update_auto_check = false },
  developer = { double_tap_to_open_books = true },
  features = { automatic_series_grouping = false },
}
""",
        )
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            deadline = time.monotonic() + 30
            visible_item = None
            while time.monotonic() < deadline and visible_item is None:
                chooser = driver.command("file_chooser_items").get("file_chooser", {})
                for item in chooser.get("visible_items", []):
                    if Path(item.get("path", "")).resolve() == book.resolve():
                        visible_item = item
                        break
                if visible_item is None:
                    time.sleep(0.1)
            assert visible_item is not None
            assert visible_item["double_tap_patched"] is True

            initial_windows = driver.visible_ui()["ui"]["windows"]

            assert driver.command("tap_file_chooser_item", path=str(book.resolve()))["ok"] is True
            assert driver.reader_state()["reader"]["open"] is False
            assert len(driver.visible_ui()["ui"]["windows"]) == len(initial_windows)

            time.sleep(0.35)
            assert driver.command("tap_file_chooser_item", path=str(book.resolve()))["ok"] is True
            assert driver.command("tap_file_chooser_item", path=str(book.resolve()))["ok"] is True
            deadline = time.monotonic() + 15
            reader = {"open": False}
            while time.monotonic() < deadline:
                reader = driver.reader_state()["reader"]
                if reader["open"]:
                    break
                time.sleep(0.1)
            assert reader["open"] is True
            assert Path(reader["file"]).resolve() == book.resolve()
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
