import os
import signal
import sqlite3
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path

import pytest

from zen_driver import ZenDriver, launch, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1",
    reason="set ZEN_UI_RUN_EMULATOR=1 to run a real KOReader emulator",
)


def _write_readable_epub(path: Path) -> None:
    container = b"""<?xml version='1.0'?>
<container version='1.0' xmlns='urn:oasis:names:tc:opendocument:xmlns:container'>
  <rootfiles><rootfile full-path='OEBPS/content.opf'
    media-type='application/oebps-package+xml'/></rootfiles>
</container>"""
    package = b"""<?xml version='1.0' encoding='UTF-8'?>
<package version='2.0' unique-identifier='book-id'
  xmlns='http://www.idpf.org/2007/opf'
  xmlns:dc='http://purl.org/dc/elements/1.1/'>
  <metadata>
    <dc:identifier id='book-id'>zen-reader-navigation</dc:identifier>
    <dc:title>Reader Navigation</dc:title>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id='chapter' href='chapter.xhtml' media-type='application/xhtml+xml'/>
  </manifest>
  <spine><itemref idref='chapter'/></spine>
</package>"""
    chapter = b"""<html xmlns='http://www.w3.org/1999/xhtml'><head>
<title>Reader Navigation</title></head><body>
<h1>Reader Navigation</h1><p>This book verifies the real reader transition.</p>
</body></html>"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("mimetype", b"application/epub+zip")
        archive.writestr("META-INF/container.xml", container)
        archive.writestr("OEBPS/content.opf", package)
        archive.writestr("OEBPS/chapter.xhtml", chapter)


def _seed_mosaic_mode(ko_home: Path) -> None:
    database = ko_home / "settings" / "bookinfo_cache.sqlite3"
    database.parent.mkdir(parents=True, exist_ok=True)
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
            INSERT INTO config (key, value)
                VALUES ('filemanager_display_mode', 'mosaic_image');
        """)


def _seed_author_metadata(ko_home: Path, book: Path, author: str) -> None:
    canonical = book.resolve()
    stat = canonical.stat()
    database = ko_home / "settings" / "bookinfo_cache.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.execute(
            """INSERT INTO bookinfo (
                directory, filename, filesize, filemtime, in_progress,
                cover_fetched, has_meta, title, authors
            ) VALUES (?, ?, ?, ?, 0, 'Y', 'Y', ?, ?)""",
            (
                str(canonical.parent) + "/",
                canonical.name,
                stat.st_size,
                int(stat.st_mtime),
                "Author Book",
                author,
            ),
        )


def _launch(
    runtime: Path,
    ko_home: Path,
    socket_path: Path,
    library: Path,
    default_tab: str,
    pending_reader_defaults: bool = False,
    restore_library_view: bool = True,
) -> subprocess.Popen[str]:
    settings_dir = ko_home / "settings" / "ZenOS"
    settings_dir.mkdir(parents=True, exist_ok=True)
    (ko_home / "settings.reader.lua").write_text(
        'return { ["home_dir"] = ' + repr(str(library.resolve())) + " }\n",
        encoding="utf-8",
    )
    pending_meta = (
        "_meta = { reader_defaults_apply_on_next_open = true }, "
        if pending_reader_defaults else ""
    )
    (settings_dir / "config.lua").write_text(
        "return { updater = { update_auto_check = false }, "
        + pending_meta
        + "features = { restore_library_view = "
        + str(restore_library_view).lower() + " }, "
        "navbar = { default_tab = " + repr(default_tab) + ", "
        "show_tabs = { home = true, authors = true, series = true }, "
        "tab_order = { 'home', 'authors', 'series', 'books' } } }\n",
        encoding="utf-8",
    )
    return launch(runtime, ko_home, socket_path, library, initialize_settings=False)


def _wait_for_reader(driver: ZenDriver, expected_file: Path) -> dict[str, object]:
    deadline = time.monotonic() + 30
    last: dict[str, object] = {}
    while time.monotonic() < deadline:
        try:
            response = driver.reader_state()
        except (ConnectionError, FileNotFoundError, OSError):
            time.sleep(0.1)
            continue
        state = response.get("reader", {})
        if isinstance(state, dict):
            last = state
            if state.get("open") is True and Path(str(state.get("file", ""))).resolve() == expected_file.resolve():
                return state
        time.sleep(0.1)
    raise AssertionError(f"book did not open in ReaderUI: {last}")


def _wait_for_reader_closed(driver: ZenDriver) -> None:
    deadline = time.monotonic() + 30
    last: dict[str, object] = {}
    while time.monotonic() < deadline:
        try:
            response = driver.reader_state()
        except (ConnectionError, FileNotFoundError, OSError):
            time.sleep(0.1)
            continue
        state = response.get("reader", {})
        if isinstance(state, dict):
            last = state
            if state.get("open") is False:
                return
        time.sleep(0.1)
    raise AssertionError(f"ReaderUI did not close: {last}")


def _wait_for_file_manager(driver: ZenDriver) -> dict[str, object]:
    deadline = time.monotonic() + 30
    last: dict[str, object] = {}
    while time.monotonic() < deadline:
        try:
            response = driver.command("file_chooser_items")
        except (ConnectionError, FileNotFoundError, OSError):
            time.sleep(0.1)
            continue
        state = response.get("file_chooser", {})
        if isinstance(state, dict):
            last = state
            if response.get("ok") is True:
                return state
        time.sleep(0.1)
    raise AssertionError(f"file manager did not return: {last}")


def _wait_for_folder_cover(driver: ZenDriver, folder: Path) -> dict[str, object]:
    deadline = time.monotonic() + 30
    expected = str(folder.resolve())
    last: dict[str, object] = {}
    while time.monotonic() < deadline:
        response = driver.command("file_chooser_items")
        state = response.get("file_chooser", {})
        if isinstance(state, dict):
            last = state
            for widget in state.get("folder_widgets", []):
                if widget.get("path") == expected and widget.get("processed") is True:
                    return widget
        time.sleep(0.1)
    raise AssertionError(f"folder cover did not render: {last}")


def _wait_for_navbar_view(
    driver: ZenDriver, expected_name: str | None, expected_label: str
) -> dict[str, object]:
    deadline = time.monotonic() + 30
    last: dict[str, object] = {}
    while time.monotonic() < deadline:
        response = driver.command("navbar_state")
        state = response.get("navbar", {})
        if isinstance(state, dict):
            last = state
            stack_names = state.get("stack_names", [])
            if state.get("active_tab_label") == expected_label \
                    and (expected_name is None or expected_name in stack_names):
                return state
        time.sleep(0.1)
    raise AssertionError(f"navbar view did not return: {last}")


@pytest.mark.parametrize("home_in_controls", [False, True])
@pytest.mark.parametrize(
    ("default_tab", "expected_label"),
    [
        ("home", "Home"),
        ("series", "Series"),
        ("books", "Library"),
    ],
)
def test_book_opens_in_reader_and_home_returns_to_library(
    default_tab: str, expected_label: str, home_in_controls: bool
) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-reader-navigation-") as temporary:
        root = Path(temporary)
        ko_home = root / "home"
        ko_home.mkdir()
        library = root / "library"
        library.mkdir()
        book = library / "Reader Navigation.epub"
        _write_readable_epub(book)
        folder = library / "Folder"
        folder.mkdir()
        _write_readable_epub(folder / "Nested.epub")
        _seed_mosaic_mode(ko_home)
        socket_path = root / "driver.sock"
        process = _launch(runtime, ko_home, socket_path, library, default_tab)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            before = _wait_for_file_manager(driver)
            if home_in_controls:
                assert driver.command("open_settings_page")["ok"] is True
                for label in ("Interface", "Controls", "Show Home in Controls"):
                    assert driver.command("settings_page_select", label=label)["ok"] is True
                assert driver.command("close_settings_page")["ok"] is True
            layout = driver.command("menu_tab_layout", tab_id="quicksettings")
            assert layout["ok"] is True
            assert ("zen_library_home" in layout["tabs"]) is (not home_in_controls)
            assert ("library_home" in layout["button_ids"]) is home_in_controls
            activated = driver.command("activate_navbar_tab", id=default_tab)
            assert activated.get("ok") is True, activated
            expected_name = None if default_tab == "books" else default_tab
            _wait_for_navbar_view(driver, expected_name, expected_label)
            assert before.get("path") == str(library.resolve())
            assert before.get("page") == 1
            if default_tab == "books":
                _wait_for_folder_cover(driver, folder)

            opened = driver.open_book(book)
            assert opened.get("ok") is True, opened
            reader = _wait_for_reader(driver, book)
            assert reader.get("page") == 1
            assert reader.get("active_tab_label") == expected_label

            returned = driver.command("activate_custom_control", id="library_home") \
                if home_in_controls else driver.reader_menu_home()
            assert returned.get("ok") is True, returned
            after = _wait_for_file_manager(driver)
            _wait_for_navbar_view(driver, expected_name, expected_label)
            reader_after = driver.reader_state().get("reader", {})
            assert reader_after.get("open") is False, reader_after
            assert after.get("path") == before.get("path")
            assert after.get("page") == before.get("page")
            if default_tab == "books":
                _wait_for_folder_cover(driver, folder)
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


@pytest.mark.parametrize(
    ("restore_library_view", "outside_home", "expected_tab"),
    [
        (True, False, "books"),
        (False, False, "home"),
        (True, True, "home"),
    ],
)
def test_reader_menu_home_respects_restore_location(
    restore_library_view: bool, outside_home: bool, expected_tab: str
) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-reader-restore-") as temporary:
        root = Path(temporary)
        ko_home = root / "home"
        ko_home.mkdir()
        library = root / "library"
        library.mkdir()
        book_dir = root / "outside" if outside_home else library
        book_dir.mkdir(exist_ok=True)
        book = book_dir / "Reader Navigation.epub"
        _write_readable_epub(book)
        _seed_mosaic_mode(ko_home)
        socket_path = root / "driver.sock"
        process = _launch(runtime, ko_home, socket_path, library, "home",
                          restore_library_view=restore_library_view)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            _wait_for_file_manager(driver)
            assert driver.command("activate_navbar_tab", id="books").get("ok") is True
            _wait_for_navbar_view(driver, None, "Library")

            assert driver.open_book(book).get("ok") is True
            _wait_for_reader(driver, book)
            assert driver.reader_menu_home().get("ok") is True
            _wait_for_reader_closed(driver)

            view = _wait_for_navbar_view(
                driver, "home" if expected_tab == "home" else None,
                "Home" if expected_tab == "home" else "Library",
            )
            assert (view.get("top_name") == "home") is (expected_tab == "home")
            assert driver.command("home_state")["home"]["on_top"] is (expected_tab == "home")
            assert _wait_for_file_manager(driver).get("path") == str(library.resolve())
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def test_reader_menu_library_restores_nested_physical_folder() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-reader-folder-restore-") as temporary:
        root = Path(temporary)
        ko_home = root / "home"
        ko_home.mkdir()
        library = root / "library"
        library.mkdir()
        folder = library / "Fiction"
        folder.mkdir()
        book = folder / "Nested.epub"
        _write_readable_epub(book)
        _seed_mosaic_mode(ko_home)
        socket_path = root / "driver.sock"
        process = _launch(runtime, ko_home, socket_path, library, "books")
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            _wait_for_file_manager(driver)

            assert driver.open_book(book).get("ok") is True
            _wait_for_reader(driver, book)

            assert driver.reader_menu_home().get("ok") is True
            _wait_for_reader_closed(driver)
            restored = _wait_for_file_manager(driver)
            assert restored.get("path") == str(folder.resolve())
            assert restored.get("page") == 1
            assert restored.get("focused_path") == str(book.resolve())
            restored_book = next(
                item for item in restored.get("visible_items", [])
                if item.get("path") == str(book.resolve())
            )
            assert restored_book.get("underline_visible") is False, restored
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def test_reader_menu_library_restores_author_detail() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-reader-author-restore-") as temporary:
        root = Path(temporary)
        ko_home = root / "home"
        ko_home.mkdir()
        library = root / "library"
        library.mkdir()
        folder = library / "Author Books"
        folder.mkdir()
        book = folder / "By Author.epub"
        _write_readable_epub(book)
        _seed_mosaic_mode(ko_home)
        _seed_author_metadata(ko_home, book, "Test Author")
        socket_path = root / "driver.sock"
        process = _launch(runtime, ko_home, socket_path, library, "books")
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            _wait_for_file_manager(driver)

            activated = driver.command("activate_navbar_tab", id="authors")
            assert activated.get("ok") is True, activated
            _wait_for_navbar_view(driver, "authors", "Authors")

            assert driver.command("navbar_key", key="Down", count=64).get("ok") is True
            focused = driver.command("navbar_key", key="Up")
            assert focused.get("target") == "standalone", focused
            assert focused.get("content_focused") is True, focused
            assert driver.command("navbar_key", key="Press").get("ok") is True
            detail = _wait_for_navbar_view(driver, "authors_detail", "Authors")
            assert detail.get("top_name") == "authors_detail"
            assert detail.get("top_tab_id") == "authors"

            assert driver.command("navbar_key", key="Down", count=64).get("ok") is True
            focused = driver.command("navbar_key", key="Up")
            assert focused.get("target") == "standalone", focused
            assert focused.get("content_focused") is True, focused
            assert driver.command("navbar_key", key="Press").get("ok") is True
            reader = _wait_for_reader(driver, book)
            assert reader.get("saved_tab") == "authors"
            assert reader.get("saved_page") == 1

            assert driver.reader_menu_home().get("ok") is True
            _wait_for_reader_closed(driver)
            restored = _wait_for_navbar_view(driver, "authors_detail", "Authors")
            assert restored.get("top_name") == "authors_detail"
            assert restored.get("top_tab_id") == "authors"
            assert restored.get("stack_names") == ["authors", "authors_detail"]
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def test_customized_footer_items_survive_epub_reopen() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-epub-footer-") as temporary:
        root = Path(temporary)
        ko_home = root / "home"
        ko_home.mkdir()
        library = root / "library"
        library.mkdir()
        book = library / "Footer Persistence.epub"
        _write_readable_epub(book)
        _seed_mosaic_mode(ko_home)
        socket_path = root / "driver.sock"
        process = _launch(
            runtime, ko_home, socket_path, library, "books",
            pending_reader_defaults=True,
        )
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            _wait_for_file_manager(driver)

            assert driver.open_book(book).get("ok") is True
            first_open = _wait_for_reader(driver, book)
            assert first_open.get("reader_defaults_pending") is False, first_open
            customized = driver.command("customize_reader_footer")
            assert customized.get("ok") is True, customized

            assert driver.reader_menu_home().get("ok") is True
            _wait_for_file_manager(driver)
            assert driver.open_book(book).get("ok") is True
            reopened = _wait_for_reader(driver, book)
            assert reopened.get("footer_time") is True, reopened
            assert reopened.get("footer_chapter_time") is False, reopened
            assert reopened.get("footer_book_title") is True, reopened
            assert reopened.get("footer_order_first") == "book_title", reopened
            assert reopened.get("footer_order_second") == "time", reopened
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
