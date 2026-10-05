import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import zipfile
from pathlib import Path

import pytest

from fixtures import build_library, _write_zip
from test_emulator_home import _seed_bookinfo, _seed_history_books
from test_emulator_reader_tools import _wait_command
from zen_driver import ZenDriver, launch, wait_for_socket

pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires KOReader emulator",
)


def _assert_fits(layout):
    assert not layout["has_scroll"], layout
    assert layout["featured_finished_icon"], layout["visible_texts"]
    assert "Finished" in layout["visible_texts"]
    assert re.fullmatch(r"\d+\s+pages\n\d+% read", layout["featured_progress_text"])
    assert layout["featured_progress_lines"] == 2
    assert not layout["featured_progress_truncated"]
    assert layout["body_size"]["w"] <= layout["body_bounds"]["w"], layout
    assert layout["body_size"]["h"] <= layout["body_bounds"]["h"], layout
    assert layout["strip_size"]["h"] <= layout["strip_preferred_height"], layout
    assert all(label["text_h"] <= label["cell_h"] for label in layout["strip_labels"]), layout["strip_labels"]
    featured_bottom = layout["featured_bounds"]["y"] + layout["featured_bounds"]["h"]
    assert all(bounds["y"] + bounds["h"] <= featured_bottom
               for bounds in layout["navigation_bounds"]), json.dumps({
                   key: layout[key] for key in ("featured_bounds", "navigation_bounds")
               })
    if layout.get("navigation_row_bounds"):
        assert abs(layout["featured_status_padding"]["above"] - layout["featured_status_padding"]["below"]) <= 1
        assert layout["navigation_follows_divider"]
        navigation = layout["navigation_row_bounds"]
        assert navigation["x"] == layout["navigation_first_cell"]["x"]
        assert navigation["x"] + navigation["w"] == layout["navigation_last_cell"]["x"] + layout["navigation_last_cell"]["w"]
        assert navigation["x"] == layout["featured_title_bounds"]["x"]
        assert navigation["w"] == layout["featured_title_bounds"]["w"]
        cover = layout["featured_cover"]
        assert navigation["x"] >= cover["x"] + cover["w"]
        assert navigation["y"] + navigation["h"] <= cover["y"] + cover["h"]


@pytest.mark.parametrize("width,height", [(600, 800), (800, 600)])
def test_end_book_renders_and_preserves_changed_default_after_restart(width, height):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-end-book-") as temporary:
        root = Path(temporary)
        home, library, socket = root / "home", root / "books", root / "driver.sock"
        home.mkdir()
        library.mkdir()
        books = build_library(library)
        def set_status(path, status, percent=0):
            sidecar = path.with_suffix(".sdr")
            sidecar.mkdir(exist_ok=True)
            progress = "" if status == "new" else f", percent_finished = {percent}"
            sidecar.joinpath("metadata.epub.lua").write_text(
                f'return {{ summary = {{ status = "{status}" }}{progress} }}\n',
                encoding="utf-8",
            )

        other_groups = {}
        for series in ("Other Series", "Another Series", "Third Series"):
            files = []
            for index in (1, 2):
                path = library / f"{series} {index}.epub"
                shutil.copyfile(books["no_cover"], path)
                files.append(path.resolve())
            other_groups[series] = files
            set_status(files[0], "complete", 1)
        other_series = other_groups["Other Series"]
        older_reading = library / "Continue Older.epub"
        shutil.copyfile(books["no_cover"], older_reading)
        older_reading = older_reading.resolve()
        set_status(older_reading, "reading", 0.4)
        set_status(books["no_cover"], "reading", 0.3)
        set_status(books["finale"], "new")
        book = books["epub"]
        with zipfile.ZipFile(book) as archive_book:
            members = {name: archive_book.read(name) for name in archive_book.namelist()}
        members["OEBPS/content.xhtml"] = (
            "<html xmlns='http://www.w3.org/1999/xhtml'><body>"
            + "<p>Some gardens remind us who we once were. Continue the story in this quiet garden.</p>" * 200
            + "</body></html>"
        ).encode()
        _write_zip(book, members)
        _seed_history_books(home, [book, books["no_cover"], other_series[0], books["finale"], older_reading])
        _seed_bookinfo(home, book)
        archive = root / "archive"
        archive.mkdir()
        (home / "settings" / "move_to_archive_settings.lua").write_text(
            f'return {{ archive_dir_path = {json.dumps(str(archive))} }}\n', encoding="utf-8",
        )
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
            for series, files in other_groups.items():
                for index, path in enumerate(files, 1):
                    connection.execute(
                        """INSERT INTO bookinfo(directory,filename,filesize,filemtime,in_progress,
                        cover_fetched,has_meta,title,authors,series,series_index)
                        VALUES(?,?,?,?,0,'Y','Y',?,'Other Author',?,?)""",
                        (str(path.parent) + "/", path.name, path.stat().st_size,
                         int(path.stat().st_mtime), f"Other Book {index}", series, index),
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
                reading = driver.command("end_book")["book_status"]
                assert reading != "complete"
                preview = driver.command("end_book", preview=True, auto_mark=False)
                assert preview["book_status"] == reading
                driver.command("end_book", close=True)
                state = driver.command("end_book", show=True)
                state = _wait_command(driver, "end_book", lambda result: result.get("status_header"))
                assert state["active"] is True, state
                assert state["book_status"] == "complete"
                assert state["rows"] == ["stats_triplet", "featured", "strip"]
                assert state["strip_two_rows"] is False
                assert state["quote"]["text"] == "No highlights in this book."
                assert state["quote"]["text"] not in state["visible_texts"]
                empty_quote_heights = state["row_heights"]
                assert state["recommendations"]["next_series"] == [str(books["no_cover"].resolve())]
                assert set(state["recommendations"]["author"]) == {
                    str(books["no_cover"].resolve()), str(books["finale"].resolve()),
                }
                texts = set(state["visible_texts"])
                assert {"Library", "Series", "To Be Read", "Home", "Next in series", "More by Zen Author"} <= texts
                assert not {"Back", "Widgets", "Book status"} & texts
                assert not state["has_default_button"]
                assert state["status_header"]["y"] == 0
                assert state["status_header_texts"]
                assert max(state["navigation_icon_sizes"]) <= state["menu_icon_size"] * 1.25
                assert min(state["navigation_label_sizes"]) > 8
                assert state["featured_status_bar"] is False
                assert state["featured_description"] is False
                assert state["featured_finished_icon"] is True
                assert state["featured_title_size"] > max(state["navigation_label_sizes"])
                assert state["strip_arrows"] is False
                assert state["edit_mode"] is True
                held = driver.command("end_book", hold_strip_cover=True)
                assert held["hold_handled"], held
                for label in ("Details", "Add to collection", "Read status", "Refresh", "Widget settings"):
                    assert any(label in button for button in held["book_menu_buttons"]), held
                assert not any("Edit" in button for button in held["book_menu_buttons"]), held
                assert driver.command("reader_state")["reader"]["open"]
                driver.command("end_book", book_menu_action="Widget settings")
                strip_settings = _wait_command(driver, "arrange_page_state", lambda result:
                                              result.get("arrange", {}).get("title") == "Book strip")["arrange"]
                assert "Controls" in strip_settings["labels"]
                assert not any(label.startswith("Default source") for label in strip_settings["labels"])
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("end_book")["active"]
                for widget, title, label in (
                    ("stats_triplet", "Reading statistics", "1"),
                    ("featured", "Featured book", "Text styles"),
                    ("strip", "Book strip", "Controls"),
                ):
                    assert driver.command("end_book", hold_widget=widget)["hold_handled"]
                    widget_settings = driver.command("arrange_page_state")["arrange"]
                    assert widget_settings["title"] == title
                    assert label in widget_settings["labels"]
                    if widget == "featured":
                        assert "Top status bar" not in widget_settings["labels"]
                        index = widget_settings["labels"].index(label) + 1
                        assert driver.command("arrange_page_select", index=index)["ok"]
                        styles = driver.command("arrange_page_state")["arrange"]
                        assert not any(label.startswith("Description:") for label in styles["labels"])
                        assert any(label.startswith("Title:") for label in styles["labels"])
                        assert any(label.startswith("Book status:") for label in styles["labels"])
                        labels_index = next(index for index, label in enumerate(styles["labels"], 1)
                                            if label.startswith("Button labels:"))
                        assert driver.command("arrange_page_select", index=labels_index, toggle=True)["ok"]
                        assert driver.command("arrange_page_back")["ok"]
                        assert driver.command("arrange_page_back")["ok"]
                        assert not driver.command("end_book")["navigation_label_sizes"]
                        driver.command("end_book", hold_widget="featured")
                        assert driver.command("arrange_page_select", index=widget_settings["labels"].index("Text styles") + 1)["ok"]
                        assert driver.command("arrange_page_select", index=labels_index, toggle=True)["ok"]
                        assert driver.command("arrange_page_back")["ok"]
                    assert driver.command("arrange_page_back")["ok"]
                    assert driver.command("end_book")["active"]
                assert driver.command("end_book")["featured_status_bar"] is False
                driver.command("end_book", hold_widget="featured")
                featured_settings = driver.command("arrange_page_state")["arrange"]
                index = featured_settings["labels"].index("Buttons") + 1
                assert index in featured_settings["submenu_indices"]
                assert driver.command("arrange_page_select", index=index)["ok"]
                buttons = driver.command("arrange_page_state")["arrange"]
                assert buttons["title"] == "Buttons"
                assert buttons["labels"] == ["Library", "Series", "To Be Read", "Home", "Archive", "Open next file", "Restart Book"]
                for label in ("Series", "Archive", "Open next file"):
                    assert driver.command("arrange_page_select", index=buttons["labels"].index(label) + 1, toggle=True)["ok"]
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("arrange_page_state")["arrange"]["title"] == "Featured book"
                assert driver.command("arrange_page_back")["ok"]
                layout = _wait_command(driver, "end_book", lambda result: len(result.get("navigation_icons", [])) == 5)
                assert layout["navigation_enabled"] == [True, True, True, True, False]
                driver.command("end_book", tap=5)
                assert driver.command("end_book")["active"]
                driver.command("end_book", collate="strcoll")
                layout = driver.command("end_book")
                assert layout["navigation_enabled"] == [True] * 5
                assert max(layout["navigation_icon_sizes"]) <= layout["menu_icon_size"] * 1.25
                _assert_fits(layout)
                driver.command("end_book", tap=4)
                assert driver.command("native_settings_confirm", accept=False)["ok"]
                assert driver.command("end_book")["active"]
                assert book.exists()
                driver.command("end_book", navigation_actions=["home"])
                single_button = driver.command("end_book")
                _assert_fits(single_button)
                assert single_button["featured_finished_icon"] is True
                driver.command("end_book", navigation_actions=[])
                empty = driver.command("end_book")
                assert not empty["navigation_icons"]
                _assert_fits(empty)
                driver.command("end_book", navigation_actions=["library", "series", "to_be_read", "home"])
                driver.command("end_book", edit_mode=False)
                for widget in ("stats_triplet", "featured", "strip"):
                    assert not driver.command("end_book", hold_widget=widget)["hold_handled"]
                assert driver.command("end_book", tap_cover=True)["cover_viewer"] is True
                assert driver.command("end_book", dismiss_cover=True)["active"] is True
                assert len(state["navigation_icons"]) == 4
                for activation, gesture, opened in (
                    ("swipe_tap", "tap", True), ("swipe_tap", "swipe", True),
                    ("swipe", "tap", False), ("tap", "swipe", False),
                ):
                    assert driver.command("end_book", menu_activation=activation,
                                          menu_gesture=gesture)["menu_open"] is opened
                driver.command("end_book", menu_activation="swipe_tap")
                assert driver.command("open_settings_page")["ok"]
                assert driver.command("settings_page_select", label="Reader")["ok"]
                assert driver.command("settings_page_state")["settings"]["labels"][-1] == "End of book"
                assert driver.command("settings_page_select", label="End of book")["ok"]
                assert "Edit mode" in driver.command("settings_page_state")["settings"]["labels"]
                assert driver.command("settings_page_select", label="Edit mode")["ok"]
                assert driver.command("settings_page_select", label="Widgets")["ok"]
                assert driver.command("zen_settings_stack_state")["settings_open"] is True
                assert driver.command("arrange_page_select", index=2)["ok"]
                featured_settings = driver.command("arrange_page_state")["arrange"]
                assert {"Text styles", "Progress"} <= set(featured_settings["labels"])
                assert "Top status bar" not in featured_settings["labels"]
                assert "Use Home settings" not in featured_settings["labels"]
                assert any(label.startswith("Icon size:") for label in featured_settings["labels"])
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("arrange_page_select", index=4)["ok"]
                strip_settings = driver.command("arrange_page_state")["arrange"]
                assert {"Controls", "Two rows"} <= set(strip_settings["labels"])
                assert "Default source" not in strip_settings["labels"]
                assert driver.command("arrange_page_select", index=strip_settings["labels"].index("Controls") + 1)["ok"]
                controls = driver.command("arrange_page_state")["arrange"]
                assert "Tabs" in controls["labels"]
                assert any(label.startswith("Font:") for label in controls["labels"])
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("arrange_page_select", index=3, toggle=True)["ok"]
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("settings_page_state")["settings"]["title"] == "End of book"
                assert driver.command("settings_page_back")["ok"]
                assert driver.command("settings_page_state")["settings"]["title"] == "Reader"
                assert driver.command("close_settings_page")["ok"]
                _wait_command(driver, "end_book", lambda result:
                              result.get("active") and "No highlights in this book." not in result.get("visible_texts", []))
                assert driver.command("end_book")["edit_mode"] is True
                driver.command("end_book", widget="quotes", enabled=True)
                driver.command("end_book", close=True)
                state = driver.command("end_book", show=True, finish=True, annotations=True)
                assert "quotes" in state["rows"]
                assert sum(empty_quote_heights.values()) > sum(
                    state["row_heights"][row] for row in empty_quote_heights)
                assert driver.command("end_book", hold_widget="quotes")["hold_handled"]
                assert driver.command("arrange_page_state")["arrange"]["title"] == "Highlights and notes"
                assert driver.command("arrange_page_back")["ok"]
                assert state["quote"]["page_label"]
                assert state["quote"]["text"].endswith("A note from this book.")
                assert driver.command("end_book", next_quote=True)["quote"]["text"] == "Second highlight."
                driver.command("end_book", next_quote=True)
                for source in ("author", "next_series"):
                    driver.command("end_book", select_source=source)
                    strip_state = driver.command("end_book")
                    assert strip_state["source"] == source
                    assert strip_state["strip_centered"] is False
                    covers = strip_state["strip_covers"]
                    assert len({(cover["w"], cover["h"]) for cover in covers}) == 1, covers
                    if source == "author":
                        author_covers = covers
                    else:
                        assert (covers[0]["w"], covers[0]["h"]) == (author_covers[0]["w"], author_covers[0]["h"])
                        assert covers[0]["x"] == author_covers[0]["x"]
                state = driver.command("end_book", select_source="other_series")
                assert state["source"] == "other_series"
                state = driver.command("end_book")
                assert {item["label"] for item in state["strip_items"]} == set(other_groups)
                assert all(item["group"] for item in state["strip_items"])
                for centered in (True, False):
                    driver.command("end_book", hold_widget="strip")
                    strip_settings = driver.command("arrange_page_state")["arrange"]
                    index = strip_settings["labels"].index("Center books") + 1
                    assert driver.command("arrange_page_select", index=index, toggle=True)["ok"]
                    assert driver.command("arrange_page_back")["ok"]
                    state = _wait_command(driver, "end_book", lambda result: result.get("strip_centered") == centered)
                    assert state["source"] == "other_series"
                    assert len(state["strip_covers"]) == len(other_groups)
                    assert (state["strip_covers"][0]["x"] > author_covers[0]["x"]) if centered else (
                        state["strip_covers"][0]["x"] == author_covers[0]["x"])
                series_covers = state["strip_covers"]
                assert series_covers[0]["x"] == author_covers[0]["x"]
                assert len({(cover["w"], cover["h"]) for cover in series_covers}) == 1
                gaps = [right["x"] - left["x"] - left["w"]
                        for left, right in zip(series_covers, series_covers[1:])]
                assert max(gaps) - min(gaps) <= 1, series_covers
                driver.command("end_book", drill_series=True)
                state = driver.command("end_book")
                assert state["strip_drill"] in other_groups
                assert {item["path"] for item in state["strip_items"]} == set(map(str, other_groups[state["strip_drill"]]))
                assert all(item["group"] is False for item in state["strip_items"])
                driver.command("end_book", select_source="other_series")
                assert driver.command("end_book")["strip_items"][0]["group"] is True
                driver.command("end_book", add_source="continue")
                driver.command("end_book", select_source="continue")
                state = driver.command("end_book")
                assert state["source"] == "continue"
                assert [item["path"] for item in state["strip_items"]] == [str(books["no_cover"].resolve()), str(older_reading)]
                state = driver.command("end_book", source="missing")
                assert state["source"] == "next_series"
                assert not any(text.startswith("Finished reading") or text.startswith("Finished on")
                               for text in state["visible_texts"])
                assert "Finished" in state["visible_texts"]
                driver.command("end_book", widget="quotes", enabled=False)
                driver.command("end_book", widget="quotes", enabled=True)
                artifact = Path(__file__).parents[2] / ".artifacts" / f"end-book-{width}x{height}.png"
                artifact.parent.mkdir(parents=True, exist_ok=True)
                driver.screenshot(artifact)
                layout = driver.command("end_book")
                _assert_fits(layout)
                assert layout["featured_cover"]["h"] > layout["strip_covers"][0]["h"]
                driver.command("end_book", navigation_icon_size=24)
                smaller_icons = driver.command("end_book")["navigation_icon_sizes"]
                assert max(smaller_icons) < layout["menu_icon_size"]
                assert min(layout["navigation_icon_sizes"]) > max(smaller_icons)
                driver.command("end_book", navigation_icon_size=64)
                larger_icons = driver.command("end_book")
                assert larger_icons["featured_title_size"] == layout["featured_title_size"]
                assert larger_icons["featured_progress_size"] == layout["featured_progress_size"]
                assert min(larger_icons["navigation_icon_sizes"]) > max(smaller_icons)
                _assert_fits(larger_icons)
                driver.command("end_book", navigation_icon_size=0)
                driver.command("end_book", large_widgets=True)
                driver.screenshot(artifact.with_name(f"end-book-{width}x{height}-dense.png"))
                _assert_fits(driver.command("end_book"))
                driver.command("end_book", large_widgets=False)
                header = driver.command("end_book")["status_header"]
                driver.command("end_book", refresh_header=True)
                assert driver.command("end_book")["status_header"] == header
                driver.command("end_book", open_quote=True)
                assert driver.command("end_book")["active"] is False
                driver.command("end_book", show=True, finish=True)
                last_page = driver.command("reader_state")["reader"]["page"]
                assert last_page > 1
                driver.command("end_book", tap="back")
                assert driver.command("reader_state")["reader"]["page"] == last_page
                assert driver.command("end_book")["active"] is False
                driver.command("end_book", show=True)
                driver.command("end_book", navigation_actions=["restart"], collate="access")
                assert driver.command("end_book")["navigation_enabled"] == [True]
                driver.command("end_book", tap=1)
                _wait_command(driver, "end_book", lambda result: not result.get("active"))
                assert driver.command("reader_state")["reader"]["page"] == 1
                driver.command("end_book", show=True)
                driver.command("end_book", navigation_actions=["library", "series", "to_be_read", "home"], collate="strcoll")
                end_covers = driver.command("end_book")["strip_covers"]
                driver.command("end_book", tap=4)
                _wait_command(driver, "reader_state", lambda result: not result.get("reader", {}).get("open"))
                home_strip = _wait_command(driver, "home_state", lambda result:
                                          result["home"].get("strip_covers"))["home"]
                home_covers = home_strip["strip_covers"]
                # The shared strip scales to each screen's available row height.
                assert abs(end_covers[0]["w"] / end_covers[0]["h"]
                           - home_covers[0]["w"] / home_covers[0]["h"]) < 0.01
                assert end_covers[0]["x"] == home_covers[0]["x"]
                home_gaps = [right["x"] - left["x"] - left["w"]
                             for left, right in zip(home_covers, home_covers[1:])]
                assert max(home_gaps) - min(home_gaps) <= 1
                assert driver.command("open_settings_page")["ok"]
                if "Reader" in driver.command("settings_page_state")["settings"]["labels"]:
                    assert driver.command("settings_page_select", label="Reader")["ok"]
                assert driver.command("settings_page_select", label="End of book")["ok"]
                assert driver.command("settings_page_select", label="Preview")["ok"]
                preview = driver.command("end_book")
                assert preview["active"] and preview["preview"]
                assert Path(preview["file"]).resolve() == book.resolve()
                assert not driver.command("reader_state")["reader"].get("open")
                assert driver.command("end_book", hold_widget="featured")["hold_handled"]
                assert driver.command("arrange_page_state")["arrange"]["title"] == "Featured book"
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("end_book")["preview"]
                cover_state = driver.command("end_book", tap_cover=True)
                assert cover_state["cover_viewer"] and not cover_state["opening_banner"]
                assert driver.command("end_book", dismiss_cover=True)["active"]
                driver.command("end_book", select_source="author")
                strip_preview = driver.command("end_book", tap_strip_cover=True)
                assert not strip_preview["opening_banner"]
                assert not driver.command("reader_state")["reader"].get("open")
                if strip_preview["cover_viewer"]:
                    driver.command("end_book", dismiss_cover=True)
                preview = driver.command("end_book", navigation_actions=["library", "home", "archive", "next_file", "restart"])
                assert preview["navigation_enabled"] == [True, True, False, False, False]
                for index in (3, 4, 5):
                    driver.command("end_book", tap=index)
                    assert driver.command("end_book")["active"]
                    assert not driver.command("reader_state")["reader"].get("open")
                driver.command("end_book", tap="back")
                _wait_command(driver, "open_book", lambda result: result.get("ok"), path=str(book))
                _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("open"))
                driver.command("end_book", show=True)
                driver.command("end_book", tap=4)
                next_book = _wait_command(driver, "reader_state", lambda result:
                                          result.get("reader", {}).get("open") and result["reader"]["file"] != str(book))
                assert Path(next_book["reader"]["file"]).resolve() == books["no_cover"].resolve()
                assert not driver.command("end_book")["active"]
                driver.command("end_book", show=True)
                archived_book = Path(next_book["reader"]["file"])
                driver.command("end_book", tap=3)
                assert driver.command("native_settings_confirm")["ok"]
                _wait_command(driver, "reader_state", lambda result: not result.get("reader", {}).get("open"))
                assert (archive / archived_book.name).exists()
                assert not archived_book.exists()
                driver.command("end_book", action="nothing")
                assert driver.command("end_book", show=True)["active"] is False
            finally:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
