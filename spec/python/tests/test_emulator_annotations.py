import os
import tempfile
from pathlib import Path

import pytest
from PIL import Image

from test_emulator_reader_tools import _wait_command, _write_reader_epub
from zen_driver import ZenDriver, launch, stop, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires the KOReader emulator",
)


def _action(driver: ZenDriver, action: str, **params: object) -> dict[str, object]:
    result = driver.command("annotation_viewer_action", action=action, **params)
    assert result["ok"], result
    return result


def _state(driver: ZenDriver) -> dict[str, object]:
    return driver.command("page_browser_state")["page_browser"]


def _menu(driver: ZenDriver) -> None:
    _action(driver, "more")


def _filters(driver: ZenDriver) -> None:
    _menu(driver)
    _action(driver, "button", text="Filter")


def test_annotation_dispatcher_destinations() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-annotation-dispatch-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        first, second = library / "first.epub", library / "second.epub"
        _write_reader_epub(first)
        _write_reader_epub(second)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            _action(driver, "dispatch", name="zen_ui_show_annotation_viewer")
            empty = _wait_command(driver, "annotation_viewer_state", lambda state: state.get("ok") and not state["loading"])
            assert empty["scope"] == "all" and not empty["items"]
            _action(driver, "close")
            assert driver.open_book(second)["ok"]
            _action(driver, "seed")
            _action(driver, "open", file=str(first))
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(first))
            _action(driver, "seed")
            for tab in ("annotations", "bookmarks", "highlights"):
                _action(driver, "dispatch", name="zen_ui_show_" + tab)
                state = _state(driver)
                assert state["active_tab"] == tab
                assert state["content_items"] == (1 if tab == "bookmarks" else 2 if tab == "highlights" else 3)
                assert state["annotation_rows"][0][0]["text"] == "First · Page 1"
                assert state["annotation_rows"][0][1]["text"] == (
                    "October 18 2026 · Yellow" if tab == "highlights" else "October 18 2026")
                _action(driver, "close")
            _action(driver, "dispatch", name="zen_ui_show_annotation_viewer")
            current = driver.command("annotation_viewer_state")
            assert current["ok"] and current["scope"] == "current"
            assert Path(current["search_icon"]).name == "quick_search.svg"
            assert {item["file"] for item in current["items"]} == {str(first)}
            _action(driver, "close")
            assert driver.command("reference_action", action="pin", page=3)["ok"]
            _action(driver, "dispatch", name="zen_ui_show_pinned_pages")
            assert driver.command("reference_action", action="state")["references"]["drawer"]["page"] == 3
            assert driver.command("reference_action", action="close_book")["ok"]
            _action(driver, "dispatch", name="zen_ui_show_annotation_viewer")
            all_books = _wait_command(driver, "annotation_viewer_state", lambda state: state.get("ok") and not state["loading"])
            assert all_books["scope"] == "all"
            assert Path(all_books["search_icon"]).name == "quick_search.svg"
            assert len(all_books["items"]) == 7
            assert [item["kind"] for item in all_books["items"]].count("pin") == 1
            assert {Path(item["file"]).resolve() for item in all_books["items"]} == {first.resolve(), second.resolve()}
            frames = Path(__file__).resolve().parents[2] / ".artifacts" / "annotations"
            frames.mkdir(parents=True, exist_ok=True)
            driver.screenshot(frames / "standalone-all-books.png")
            _action(driver, "search")
            _action(driver, "input", text="quiet")
            _action(driver, "button", text="Search")
            assert len(driver.command("annotation_viewer_state")["items"]) == 2
            _action(driver, "details")
            _action(driver, "button", text="Go to")
            _wait_command(driver, "reader_state", lambda result: Path(result["reader"]["file"]).resolve() == first.resolve())
            assert not driver.command("annotation_viewer_state")["ok"]
        finally:
            stop(process)


def test_pinned_pages_in_viewer_and_tab() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    frames = Path(__file__).resolve().parents[2] / ".artifacts" / "annotations"
    frames.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zen-annotation-pins-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "first.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library,
                         zen_config_source="return {page_browser={tabs={pins=true}}}")
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _action(driver, "seed")
            assert driver.command("reference_action", action="pin", page=3)["ok"]
            _action(driver, "dispatch", name="zen_ui_show_annotation_viewer")
            state = driver.command("annotation_viewer_state")
            assert state["status_row"]
            assert [item["kind"] for item in state["items"]] == ["pin", "bookmark", "highlight", "highlight"]
            driver.screenshot(frames / "standalone-pins.png")
            _action(driver, "close")
            _action(driver, "dispatch", name="zen_ui_show_annotations")
            _action(driver, "tab", tab="pins")
            state = _state(driver)
            assert state["active_tab"] == "pins"
            assert [item["kind"] for item in state["annotation_items"]] == ["pin"]
            driver.screenshot(frames / "page-browser-pins.png")
            _action(driver, "details")
            assert _state(driver)["annotation_buttons"] == [["Go to"]]
            _action(driver, "details_more")
            assert [row["text"] for row in _state(driver)["annotation_dialog"]["rows"]] == ["Remove pin"]
            _action(driver, "button", text="Remove pin")
            assert driver.command("native_settings_confirm")["ok"]
            assert _state(driver)["content_items"] == 0
        finally:
            stop(process)


@pytest.mark.parametrize("document_type", ["epub", "pdf"])
def test_page_browser_tab_order(document_type: str) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-browser-tabs-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / ("tabs." + document_type)
        if document_type == "pdf":
            from test_emulator_reader_controls import _write_pdf
            _write_pdf(book)
        else:
            _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            assert driver.command("open_settings_page")["ok"]
            for label in ("Reader", "Page Browser", "Tabs"):
                assert driver.command("settings_page_select", label=label)["ok"]
            arrange = driver.command("arrange_page_state")["arrange"]
            controls = "Contrast" if document_type == "pdf" else "Font"
            assert arrange["labels"] == ["Page browser", controls, "Bookmarks", "Highlights", "Table of contents",
                                         "Annotations", "Pinned pages", "Book details", "Book switcher"]
            assert driver.command("arrange_page_select", index=4, toggle=True)["ok"]
            assert driver.command("arrange_page_select", index=6, toggle=True)["ok"]
            assert driver.command("arrange_page_drag", **{"from": 6, "to": 1})["ok"]
            assert driver.command("arrange_page_state")["arrange"]["labels"][0] == "Annotations"
            assert driver.command("arrange_page_select", index=2, toggle=True)["ok"]
            assert driver.command("close_arrange_page")["ok"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            state = _state(driver)
            assert state["top_is_browser"]
            assert state["active_tab"] == "annotations"
            control_icon = "appbar.contrast.svg" if document_type == "pdf" else "font.svg"
            assert state["header_icons"] == ["more_vertical.svg", "annotations.svg", control_icon,
                                              "bookmark_outline.svg", "toc.svg", "close.svg"]
            assert driver.command("activate_reader_control", name="page_browser_bookmarks")["activated"]
            assert _state(driver)["active_tab"] == "bookmarks"
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            assert _state(driver)["active_tab"] == "aa"
            assert driver.command("page_browser_key", key="Back")["handled"]
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert _state(driver)["active_tab"] == "aa"
            assert driver.command("activate_reader_control", name="page_browser_annotations")["activated"]
            stop(process)
            process = launch(runtime, home, socket, library, initialize_settings=False)
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            _wait_command(driver, "open_book", lambda result: result.get("ok"), path=str(book))
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            assert _state(driver)["header_icons"] == state["header_icons"]
            assert _state(driver)["active_tab"] == "annotations"
        finally:
            stop(process)


@pytest.mark.parametrize("document_type", ["epub", "pdf"])
def test_annotations_and_floating_book_note(document_type: str) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    frames = Path(__file__).resolve().parents[2] / ".artifacts" / "annotations"
    frames.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zen-annotations-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        first, second = library / ("first." + document_type), library / ("second." + document_type)
        if document_type == "pdf":
            from test_emulator_reader_controls import _write_pdf
            _write_pdf(first)
            _write_pdf(second)
        else:
            _write_reader_epub(first)
            _write_reader_epub(second)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library, zen_config_source=(
            'return {annotation_viewer={tabs={bookmarks=true,highlights=true,annotations=true},details={date=true}}}'
        ))
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            _wait_command(driver, "open_book", lambda result: result.get("ok"), path=str(second))
            _action(driver, "seed")
            _action(driver, "open", file=str(first))
            _wait_command(driver, "reader_state", lambda result: result.get("reader", {}).get("file") == str(first))
            _action(driver, "seed")
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            for tab in ("annotations", "highlights", "bookmarks"):
                _action(driver, "tab", tab=tab)
                state = _state(driver)
                assert "quick_search.svg" not in state["header_icons"]
                search = state["annotation_search"]
                assert Path(search["icon"]).name == "quick_search.svg"
                bounds, title = search["bounds"], search["title_bounds"]
                assert title["x"] + title["w"] <= bounds["x"]
                assert state["screen_width"] * 0.75 < bounds["x"]
                assert state["annotation_more_bounds"]["x"] >= bounds["x"] + bounds["w"]
                assert bounds["y"] > state["header_height"]
                assert state["close_bounds"]["y"] + state["close_bounds"]["h"] <= bounds["y"]
                assert title["y"] <= bounds["y"] + bounds["h"] / 2 <= title["y"] + title["h"]
                _action(driver, "search")
                _action(driver, "button", text="Cancel")
            _action(driver, "tab", tab="bookmarks")
            state = _state(driver)
            assert len(state["annotation_items"]) == 1
            if document_type == "epub":
                assert state["annotation_subtitle"] == "Reader Tools Fixture"
            else:
                assert "first" in state["annotation_subtitle"].lower()
            assert state["annotation_subtitle_size"] == 20
            assert state["annotation_subtitle_black"]
            assert state["annotation_subtitle_bold"]
            assert state["annotation_rows"][0] == [
                {"text": "First · Page 1", "size": 18, "black": True},
                {"text": "October 18 2026", "size": 18, "black": True},
            ]
            bookmark = state["annotation_bookmarks"][0]
            assert Path(bookmark["icon"]).name == "bookmark.svg"
            assert min(bookmark["lines"], bookmark["max_lines"]) == 1
            _action(driver, "details")
            state = _state(driver)
            assert "Page 1" in state["annotation_text"]
            assert "\nOctober 18 2026 · Page 1\n" in state["annotation_text"]
            assert state["annotation_buttons"] == [["Go to"]]
            driver.screenshot(frames / "bookmark-details.png")
            _action(driver, "details_more")
            state = _state(driver)
            assert [row["text"] for row in state["annotation_dialog"]["rows"]] == ["Add note", "Delete"]
            driver.screenshot(frames / "bookmark-details-menu.png")
            _action(driver, "close_dialog")
            _action(driver, "close_details")
            _action(driver, "hold")
            state = _state(driver)
            assert [row["text"] for row in state["annotation_dialog"]["rows"]] == ["Go to", "Add note", "Delete"]
            assert [Path(row["icon"]).name for row in state["annotation_dialog"]["rows"]] == [
                "settings_book_open_variant.svg", "settings_note_plus_outline.svg", "settings_delete_outline.svg"]
            row, anchor = state["annotation_row_bounds"][0], state["annotation_dialog"]["anchor"]
            assert anchor == {"x": row["x"], "y": row["y"] + row["h"] // 2, "w": row["w"], "h": 0}
            bounds = state["annotation_dialog"]["bounds"]
            assert bounds["y"] == anchor["y"]
            driver.screenshot(frames / "bookmark-hold-menu.png")
            _action(driver, "close_dialog")
            _action(driver, "tab", tab="annotations")
            state = _state(driver)
            assert state["annotation_items"][0]["kind"] == "bookmark"
            assert state["annotation_rows"][0][0]["text"] == "First · Page 1"
            assert state["annotation_rows"][0][1]["text"] == "October 18 2026"
            assert len(state["annotation_rows"][0]) == 2
            _action(driver, "tab", tab="highlights")
            state = _state(driver)
            assert len(state["annotation_items"]) == 2
            assert state["annotation_subtitle_size"] == 20
            assert state["annotation_subtitle_black"]
            assert state["annotation_subtitle_bold"]
            assert state["annotation_subtitle"] != "This book"
            assert state["annotation_rows"][0][:2] == [
                {"text": "First · Page 1", "size": 18, "black": True},
                {"text": "October 18 2026 · Yellow", "size": 18, "black": True},
            ]
            frame = frames / "annotation-borders.png"
            driver.screenshot(frame)
            with Image.open(frame).convert("RGB") as image:
                first_row, second_row = state["annotation_row_bounds"]
                x = int(first_row["x"] + first_row["w"] / 2)
                top = image.getpixel((x, int(first_row["y"])))
                assert top == image.getpixel((x, int(first_row["y"] + first_row["h"] - 1)))
                assert top != (255, 255, 255)
                assert image.getpixel((x, int(second_row["y"]))) == (255, 255, 255)
            assert state["header_icons"][0] == "more_vertical.svg"
            assert state["content_zen_scroll_bar"]
            assert driver.command("page_browser_key", key="Down")["handled"]
            assert _state(driver)["focused"].startswith("content:")
            assert driver.command("page_browser_key", key="Return")["handled"]
            _action(driver, "button", text="Cancel")
            assert driver.command("page_browser_key", key="Down")["handled"]
            assert driver.command("page_browser_key", key="Return")["handled"]
            assert "October 18 2026" in _state(driver)["annotation_text"]
            assert "2026-10-18 12:01:00" not in _state(driver)["annotation_text"]
            assert _state(driver)["annotation_buttons"] == [["Go to"]]
            _action(driver, "details_more")
            rows = _state(driver)["annotation_dialog"]["rows"]
            assert [row["text"] for row in rows] == ["Edit note", "Edit", "Delete"]
            assert [Path(row["icon"]).name for row in rows] == [
                "annotations.svg", "settings_square_edit_outline.svg", "settings_delete_outline.svg"]
            _action(driver, "button", text="Edit")
            assert [row["text"] for row in _state(driver)["annotation_dialog"]["rows"]] == ["Color", "Style"]
            driver.screenshot(frames / "highlight-edit-menu.png")
            _action(driver, "button", text="Color")
            _action(driver, "button", text="Blue")
            assert _state(driver)["annotation_items"][0]["color"] == "blue"
            _action(driver, "details")
            _action(driver, "details_more")
            _action(driver, "button", text="Edit")
            _action(driver, "button", text="Style")
            _action(driver, "button", text="Underline")
            assert _state(driver)["annotation_items"][0]["style"] == "underscore"
            driver.screenshot(frames / "highlights.png")

            _menu(driver)
            rows = _state(driver)["more_menu"]["rows"]
            assert [row["text"] for row in rows] == ["New note", "Filter", "Sort", "Settings"]
            assert [Path(row["icon"]).name for row in rows] == ["plus.svg", "filter.svg", "sort.svg", "settings_cog.svg"]
            driver.screenshot(frames / "annotation-menu.png")
            _action(driver, "button", text="Sort")
            state = _state(driver)
            assert state["annotation_dialog"]["anchor"] == state["annotation_more_bounds"]
            _action(driver, "button", text="Date")
            _menu(driver)
            _action(driver, "button", text="Sort")
            _action(driver, "button", text="Reverse order")
            assert _state(driver)["annotation_items"][0]["text"] == "A second passage"
            _menu(driver)
            _action(driver, "button", text="Sort")
            _action(driver, "button", text="Position")
            _menu(driver)
            _action(driver, "button", text="New note")
            floating = "A floating thought\n\nPensées about the whole book. 中文"
            _action(driver, "input", text=floating)
            state = _state(driver)
            editor = state["note_editor"]
            bounds = editor["bounds"]
            assert abs(bounds["x"] * 2 + bounds["w"] - state["screen_width"]) <= 2
            assert abs(bounds["y"] * 2 + bounds["h"] - editor["available_height"]) <= 2
            assert bounds["y"] >= 20
            assert editor["available_height"] - bounds["y"] - bounds["h"] >= 20
            assert not editor["scroll_buttons"] and not editor["nav_bar"]
            assert editor["buttons"] == [["Cancel", "Save"]]
            driver.screenshot(frames / "book-note-editor.png")
            _action(driver, "button", text="Save")
            note_file = first.with_suffix(".sdr") / "zen-note.txt"
            assert note_file.read_text() == floating
            _action(driver, "tab", tab="annotations")
            assert len(_state(driver)["annotation_items"]) == 4
            _action(driver, "search")
            _action(driver, "input", text="floating")
            _action(driver, "button", text="Search")
            assert [row["kind"] for row in _state(driver)["annotation_items"]] == ["note"]
            _action(driver, "details")
            assert not driver.command("annotation_viewer_action", action="button", text="Go to")["ok"]
            assert _state(driver)["annotation_buttons"] == [["Edit note"]]
            _action(driver, "close_details")
            _action(driver, "tab", tab="highlights")
            assert _state(driver)["content_items"] == 0
            _action(driver, "tab", tab="annotations")
            assert _state(driver)["content_items"] == 1
            _menu(driver)
            _action(driver, "button", text="New note")
            _action(driver, "input", text="discarded edit\n" * 200)
            assert _state(driver)["note_editor"]["bounds"] == bounds
            _action(driver, "button", text="Cancel")
            assert note_file.read_text() == floating
            _filters(driver)
            state = _state(driver)
            modal = state["annotation_dialog"]
            assert modal["anchor"] == state["annotation_more_bounds"]
            assert modal["bounds"]["y"] < state["screen_height"] / 4
            assert [row["text"] for row in modal["rows"]] == ["This book", "Type", "Books", "Chapters", "Tags", "Color", "Style", "Text", "Clear filters"]
            driver.screenshot(frames / "annotation-filter.png")
            _action(driver, "button", text="Clear filters")
            _filters(driver)
            _action(driver, "button", text="Text")
            _action(driver, "button", text="Highlighted text · Include")
            _action(driver, "input", text="quiet missing")
            _action(driver, "button", text="All words")
            _action(driver, "button", text="Apply")
            assert _state(driver)["content_items"] == 1
            _filters(driver)
            _action(driver, "button", text="Clear filters")
            _filters(driver)
            _action(driver, "button", text="This book")
            state = _wait_command(driver, "page_browser_state", lambda result:
                                  not result["page_browser"].get("annotation_loading"))["page_browser"]
            assert state["annotation_scope"] == "all"
            assert len(state["annotation_items"]) == 7
            driver.screenshot(frames / "all-annotations.png")
            _filters(driver)
            _action(driver, "button", text="Color")
            _action(driver, "button", text="Exclude")
            _action(driver, "button", text="Red")
            _action(driver, "button", text="Done")
            state = _state(driver)
            assert len(state["annotation_items"]) == 5
            assert all(row["color"] != "red" for row in state["annotation_items"])

            index = next(index for index, row in enumerate(state["annotation_items"], 1)
                         if Path(row["file"]).resolve() == second.resolve() and row["kind"] == "highlight")
            _action(driver, "details", index=index)
            _action(driver, "details_more")
            _action(driver, "button", text="Edit note")
            _wait_command(driver, "reader_state", lambda result: Path(result["reader"]["file"]).resolve() == second.resolve())
            _action(driver, "input", text="Edited using the native book editor")
            _action(driver, "button", text="Save")
            assert driver.command("activate_reader_control", name="page_browser")["activated"]
            _action(driver, "tab", tab="highlights")
            state = _state(driver)
            assert state["annotation_scope"] == "current"
            assert len(state["annotation_items"]) == 2
            assert any(row["note"] == "Edited using the native book editor" for row in state["annotation_items"])
            assert note_file.read_text() == floating
            _action(driver, "tab", tab="annotations")
            _filters(driver)
            _action(driver, "button", text="This book")
            state = _wait_command(driver, "page_browser_state", lambda result:
                                  not result["page_browser"].get("annotation_loading"))["page_browser"]
            index = next(index for index, row in enumerate(state["annotation_items"], 1) if row["kind"] == "note")
            _action(driver, "details", index=index)
            _action(driver, "details_more")
            _action(driver, "button", text="Delete")
            assert driver.command("native_settings_confirm")["ok"]
            assert not note_file.exists()
            assert _state(driver)["content_items"] == 6
            assert driver.command("set_language", language="es")["ok"]
            _action(driver, "tab", tab="bookmarks")
            state = _state(driver)
            assert any("Página 1" in block["text"] for row in state["annotation_rows"] for block in row)
            index = next(index for index, row in enumerate(state["annotation_items"], 1)
                         if Path(row["file"]).resolve() == second.resolve())
            _action(driver, "details", index=index)
            assert "Página 1" in _state(driver)["annotation_text"]
            _action(driver, "close_details")
        finally:
            stop(process)
