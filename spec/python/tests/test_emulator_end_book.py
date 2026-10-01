import os
import signal
import sqlite3
import tempfile
from pathlib import Path

import pytest

from fixtures import build_library
from test_emulator_home import _seed_bookinfo
from test_emulator_reader_tools import _wait_command
from zen_driver import ZenDriver, launch, wait_for_socket

pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires KOReader emulator",
)


@pytest.mark.parametrize("width,height", [(1200, 1600), (800, 600)])
def test_end_book_renders_and_preserves_changed_default_after_restart(width, height):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-end-book-") as temporary:
        root = Path(temporary)
        home, library, socket = root / "home", root / "books", root / "driver.sock"
        home.mkdir()
        library.mkdir()
        books = build_library(library)
        book = books["epub"]
        _seed_bookinfo(home, book)
        with sqlite3.connect(home / "settings" / "bookinfo_cache.sqlite3") as connection:
            connection.execute("UPDATE bookinfo SET title='Alpha', series='Series A'")
            for index, name in enumerate(("no_cover", "finale"), 2):
                path = books[name].resolve()
                connection.execute(
                    """INSERT INTO bookinfo(directory,filename,filesize,filemtime,in_progress,
                    cover_fetched,has_meta,title,authors,series,series_index)
                    VALUES(?,?,?,?,0,'Y','Y',?,'Zen Author','Series A',?)""",
                    (str(path.parent) + "/", path.name, path.stat().st_size,
                     int(path.stat().st_mtime), name.title(), index),
                )
        for first_run in (True, False):
            process = launch(runtime, home, socket, library, initialize_settings=first_run,
                             env_overrides={"EMULATE_READER_W": str(width), "EMULATE_READER_H": str(height)})
            try:
                wait_for_socket(socket)
                driver = ZenDriver(socket)
                state = driver.command("end_book")
                assert state["initialized"] is True
                assert state["action"] == ("zen_end_book" if first_run else "nothing")
                if not first_run:
                    continue
                _wait_command(driver, "open_book", lambda result: result.get("ok"), path=str(book))
                _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
                state = driver.command("end_book", show=True)
                assert state["active"] is True, state
                assert state["rows"] == ["stats_triplet", "featured", "quotes", "strip"]
                assert state["quote"]["text"] == "No highlights in this book."
                assert state["recommendations"]["next_series"] == [str(books["no_cover"].resolve())]
                assert set(state["recommendations"]["author"]) == {
                    str(books["no_cover"].resolve()), str(books["finale"].resolve()),
                }
                driver.command("end_book", close=True)
                state = driver.command("end_book", show=True, finish=True, annotations=True)
                assert state["quote"]["page_label"]
                assert state["quote"]["text"].endswith("A note from this book.")
                assert driver.command("end_book", next_quote=True)["quote"]["text"] == "Second highlight."
                driver.command("end_book", next_quote=True)
                for source in ("author", "other_series", "next_series"):
                    assert driver.command("end_book", source=source)["source"] == source
                driver.command("end_book", widget="quotes", enabled=False)
                driver.command("end_book", widget="quotes", enabled=True)
                artifact = Path(__file__).parents[2] / ".artifacts" / f"end-book-{width}x{height}.png"
                artifact.parent.mkdir(parents=True, exist_ok=True)
                driver.screenshot(artifact)
                driver.command("end_book", open_quote=True)
                assert driver.command("end_book")["active"] is False
                driver.command("end_book", show=True)
                driver.command("end_book", close=True, action="nothing")
                assert driver.command("end_book", show=True)["active"] is False
            finally:
                process.send_signal(signal.SIGTERM)
                process.wait(timeout=10)
