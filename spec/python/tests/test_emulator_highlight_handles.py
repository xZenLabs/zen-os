import os
import tempfile
import time
from pathlib import Path

import pytest
from PIL import Image, ImageChops

from test_emulator_reader_tools import _wait_command, _write_reader_epub
from zen_driver import ZenDriver, launch, stop, wait_for_socket

pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires the KOReader emulator",
)


def _write_text_pdf(path: Path) -> None:
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>"]
    for page in range(3):
        stream = b"BT /F1 14 Tf 30 550 Td 24 TL\n"
        for line in range(18):
            stream += f"(Page {page + 1} line {line + 1} alpha beta gamma delta epsilon.) Tj T*\n".encode()
        stream += b"ET\n"
        objects.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] "
                        "/Resources << /Font << /F1 9 0 R >> >> /Contents "
                        f"{4 + page * 2} 0 R >>").encode())
        objects.append(f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"endstream")
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    data, offsets = b"%PDF-1.4\n", [0]
    for number, content in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{number} 0 obj\n".encode() + content + b"\nendobj\n"
    start = len(data)
    data += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010} 00000 n \n".encode() for offset in offsets[1:])
    data += f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()
    path.write_bytes(data)


@pytest.mark.parametrize("format", ["epub", "pdf"])
@pytest.mark.parametrize("saved", [False, True])
def test_highlight_completion_blocks_rapid_reader_taps(format: str, saved: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="zen-highlight-tap-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / ("tap." + format)
        (_write_reader_epub if format == "epub" else _write_text_pdf)(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("highlight_tools", action="seed", saved=saved)
            assert state["ok"], state
            page = state["page"]
            time.sleep(0.7)
            state = driver.command("highlight_tools", action="close" if saved else "save", reader_taps=2)
            assert state["ok"] and state["page"] == page, state
            assert state["count"] == 1
            time.sleep(0.7)
            state = driver.command("highlight_tools", reader_taps=1)
            assert state["ok"] and state["page"] > page, state
        finally:
            stop(process)


@pytest.mark.parametrize("format", ["epub", "pdf"])
@pytest.mark.parametrize("saved", [False, True])
def test_resize_highlight_and_preserve_annotation(format: str, saved: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="zen-handles-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / ("selection." + format)
        (_write_reader_epub if format == "epub" else _write_text_pdf)(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("highlight_tools", action="seed", saved=saved)
            assert state["ok"], state
            original = state["draft_text"]
            assert state["handles"], state
            if saved:
                assert state["menu_ids"] == ["zen_highlight_" + name for name in
                                              ("style", "color", "note", "delete", "more")] + ["zen_pin"]
                assert state["menu_icons"][-3].endswith("/trash.svg")
                assert state["menu_icons"][-2].endswith("/more_vertical.svg")
            state = driver.command("highlight_tools", action="drag", word=10, release=False)
            assert state["ok"] and state["dragging"], state
            assert state["draft_text"] != original, state
            if saved:
                assert state["stored_text"] == original
            else:
                assert state["count"] == 0
            state = driver.command("highlight_tools", action="release")
            assert state["ok"] and not state["dragging"], state
            expanded = state["draft_text"]
            assert expanded != original
            state = driver.command("highlight_tools", action="drag", word=7)
            assert state["ok"] and state["draft_text"] != expanded, state
            state = driver.command("highlight_tools", action="drag", side=0, word=1)
            assert state["ok"] and not state["dragging"], state
            artifact = Path(__file__).resolve().parents[2] / ".artifacts" / "highlight-handles"
            artifact.mkdir(parents=True, exist_ok=True)
            driver.screenshot(artifact / (format + ("-saved" if saved else "-new") + ".png"))
            if saved:
                assert state["note"] == "Preserved note"
                assert state["stored_text"] == state["draft_text"]
                if format == "pdf":
                    assert state["embedded_count"] == 1
            else:
                assert state["count"] == 0
                text = state["draft_text"]
                state = driver.command("highlight_tools", action="save")
                assert state["count"] == 1 and state["stored_text"] == text, state
            driver.command("highlight_tools", action="close")
            stop(process)
            process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library, initialize_settings=False)
            wait_for_socket(socket)
            assert driver.open_book(book)["ok"]
            persisted = driver.command("highlight_tools")
            assert persisted["count"] == 1 and persisted["stored_text"] == state["stored_text"], persisted
        finally:
            stop(process)


@pytest.mark.parametrize("format", ["epub", "pdf"])
@pytest.mark.parametrize("saved", [False, True])
def test_resize_highlight_with_corner_scrolling(format: str, saved: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="zen-handle-edge-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / ("edge." + format)
        (_write_reader_epub if format == "epub" else _write_text_pdf)(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("highlight_tools", action="seed", saved=saved)
            assert state["ok"], state
            original = state["draft_text"]
            original_position = state["position"]
            bottom_edge = {"x": state["screen_w"] // 2, "y": state["screen_h"] - 5}
            corner = {"x": state["screen_w"] - 5, "y": state["screen_h"] - 5}
            state = driver.command("highlight_tools", action="drag", target=bottom_edge, raw=True, release=False)
            assert state["ok"], state
            assert state["position"] == original_position
            state = driver.command("highlight_tools", action="drag", target=corner, raw=True, release=False)
            assert state["ok"] and state["dragging"], state
            assert state["position"] > original_position, state
            if format == "epub":
                assert state["view_mode"] == "scroll" and state["restore_page_mode"], state
            corner_position = state["position"]
            time.sleep(0.7)
            state = driver.command("highlight_tools")
            assert state["position"] == corner_position
            state = driver.command("highlight_tools", action="drag", target=corner, raw=True, release=False)
            assert state["position"] == corner_position
            state = driver.command("highlight_tools", action="drag", word=10, release=False)
            state = driver.command("highlight_tools", action="drag", target=corner, raw=True, release=False)
            assert state["position"] > corner_position
            state = driver.command("highlight_tools", action="drag", word=10, release=False)
            if saved:
                assert state["stored_text"] == original
            else:
                assert state["count"] == 0
            state = driver.command("highlight_tools", action="release")
            assert state["ok"] and state["draft_text"] != original, state
            if format == "epub":
                assert state["view_mode"] == ("page" if saved else "scroll"), state
            if not saved:
                state = driver.command("highlight_tools", action="save")
            assert not state["restore_page_mode"]
            assert state["view_mode"] == "page"
        finally:
            stop(process)


@pytest.mark.parametrize("saved", [False, True])
@pytest.mark.parametrize("theme", ["default", "light_sepia"])
def test_highlighting_preserves_reader_bars_and_margins(saved: bool, theme: str) -> None:
    with tempfile.TemporaryDirectory(prefix="zen-highlight-layout-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "layout.epub"
        _write_reader_epub(book)
        (home / "settings.reader.lua").write_text(
            "return { home_dir = " + repr(str(library.resolve()))
            + ", copt_h_page_margins = {51, 57}, copt_t_page_margin = 47, copt_b_page_margin = 49 }\n",
            encoding="utf-8",
        )
        config = home / "settings" / "ZenOS"
        config.mkdir(parents=True)
        (config / "config.lua").write_text(
            "return { updater = { update_auto_check = false }, "
            "features = { reader_themes = true }, reader_themes = { light_mode = '" + theme + "' }, "
            # Static header text: a clock tick between screenshots would break the band diff.
            "reader_top_status_bar = { left_order = {}, center_order = {'custom_text'}, right_order = {}, "
            "custom_text = 'Highlight layout' } }\n",
            encoding="utf-8",
        )
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library, initialize_settings=False)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            baseline = root / "reading.png"
            driver.screenshot(baseline)
            state = driver.command("highlight_tools", action="seed", saved=saved)
            margins = state["margins"]
            artifact = Path(__file__).resolve().parents[2] / ".artifacts" / "highlight-handles"
            artifact.mkdir(parents=True, exist_ok=True)
            suffix = theme + ("-saved.png" if saved else "-new.png")
            popup = artifact / ("layout-" + suffix)
            driver.screenshot(popup)
            with Image.open(baseline) as reading, Image.open(popup) as highlighting:
                band = (0, 0, reading.width, state["footer_height"])
                assert ImageChops.difference(reading.convert("RGB").crop(band),
                                            highlighting.convert("RGB").crop(band)).getbbox() is None
            corner = {"x": state["screen_w"] - 5, "y": state["screen_h"] - 5}
            state = driver.command("highlight_tools", action="drag", target=corner, raw=True, release=False)
            assert state["dragging"] and state["restore_page_mode"], state
            assert state["margins"] == margins
            scrolling = artifact / ("layout-scrolling-" + suffix)
            driver.screenshot(scrolling)
            with Image.open(baseline) as reading, Image.open(scrolling) as highlighting:
                bands = [(0, 0, reading.width, margins["top"]),
                         (0, reading.height - margins["bottom"], reading.width,
                          reading.height - state["footer_height"])]
                for band in bands:
                    assert ImageChops.difference(reading.convert("RGB").crop(band),
                                                highlighting.convert("RGB").crop(band)).getbbox() is None
            driver.command("highlight_tools", action="close")
            state = driver.command("highlight_tools")
            assert state["view_mode"] == "page" and state["margins"] == margins
        finally:
            stop(process)


@pytest.mark.parametrize("format", ["epub", "pdf"])
@pytest.mark.parametrize("landscape", [False, True])
def test_highlight_note_editor_spacing_controls_and_save(format: str, landscape: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="zen-highlight-note-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / ("note." + format)
        (_write_reader_epub if format == "epub" else _write_text_pdf)(book)
        socket = root / "driver.sock"
        runtime = Path(os.environ["KOREADER_DIR"])
        dimensions = {"EMULATE_READER_W": "800", "EMULATE_READER_H": "600"} if landscape else {}
        process = launch(runtime, home, socket, library, env_overrides=dimensions)
        original = "A long existing note.\n" * 80
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("highlight_tools", action="seed", saved=True,
                                   note_text=original, datetime="2026-10-18 12:01:00")
            assert state["ok"], state
            state = driver.command("highlight_tools", action="note")
            for toggle in range(3):
                state = _wait_command(driver, "highlight_tools", lambda result:
                                      result.get("note_editor", {}).get("bounds"))
                editor = state["note_editor"]
                assert editor["buttons"] == [["Save"]]
                assert not editor["scroll_buttons"]
                description = editor["description"].strip().replace("\u2066", "").replace("\u2069", "")
                assert description == "October 18 2026 · Page 1"
                assert Path(editor["close_icon"]).name == "close.svg"
                bounds = editor["bounds"]
                assert bounds["y"] >= 20
                assert editor["available_height"] - bounds["y"] - bounds["h"] >= 20
                assert abs(bounds["y"] * 2 + bounds["h"] - editor["available_height"]) <= 2
                if toggle < 2:
                    state = driver.command("highlight_tools", action="note_keyboard")
            artifact = Path(__file__).resolve().parents[2] / ".artifacts" / "highlight-handles"
            artifact.mkdir(parents=True, exist_ok=True)
            driver.screenshot(artifact / ("note-" + format + ("-landscape.png" if landscape else "-portrait.png")))
            assert driver.command("native_settings_input", text="Discard this change")["ok"]
            state = driver.command("highlight_tools", action="note_close")
            assert not state.get("note_editor") and state["note"] == original, state
            assert state["count"] == 1
            assert driver.command("highlight_tools", action="note")["ok"]
            updated = "Saved note\n\nPensées and 中文."
            assert driver.command("native_settings_input", text=updated, button="Save")["ok"]
            state = driver.command("highlight_tools")
            assert state["note"] == updated and state["count"] == 1, state
            stop(process)
            process = launch(runtime, home, socket, library, initialize_settings=False, env_overrides=dimensions)
            wait_for_socket(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("highlight_tools")
            assert state["note"] == updated and state["count"] == 1, state
        finally:
            stop(process)


def test_highlight_menu_arrange_settings_persist() -> None:
    with tempfile.TemporaryDirectory(prefix="zen-highlight-order-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "menu.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        runtime = Path(os.environ["KOREADER_DIR"])
        process = launch(runtime, home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            assert driver.command("open_settings_page")["ok"]
            for label in ("Reader", "Highlight / Lookup", "Highlight", "Show labels", "Menu items"):
                assert driver.command("settings_page_select", label=label)["ok"]
            arrange = driver.command("arrange_page_state")["arrange"]
            assert arrange["labels"] == ["Style", "Color", "Note", "Extend start", "Contract start",
                                         "Contract end", "Extend end", "Delete", "More"]
            assert arrange["checked"] == [True] * 3 + [False] * 4 + [True] * 2
            assert driver.command("arrange_page_select", index=1, toggle=True)["ok"]
            assert driver.command("arrange_page_select", index=4, toggle=True)["ok"]
            assert driver.command("arrange_page_drag", **{"from": 3, "to": 1})["ok"]
            assert driver.command("close_arrange_page")["ok"]
            state = driver.command("highlight_tools", action="seed", saved=True)
            expected = ["zen_highlight_" + name for name in ("note", "color", "start_prev", "delete", "more")] + ["zen_pin"]
            assert state["menu_ids"] == expected
            assert state["menu_buttons"][0][0]["text"] == "Note"
            driver.command("highlight_tools", action="close")
            stop(process)
            process = launch(runtime, home, socket, library, initialize_settings=False)
            wait_for_socket(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("highlight_tools", action="seed", saved=True)
            assert state["menu_ids"] == expected
            assert state["menu_buttons"][0][0]["text"] == "Note"
            state = driver.command("highlight_tools", action="more")
            assert len(state["menu_ids"]) == 5
            assert state["menu_ids"][-2:] == ["zen_highlight_settings", "zen_pin"]
            assert not any("extend" in Path(icon).name or "highlight" in Path(icon).name for icon in state["menu_icons"])
        finally:
            stop(process)


def test_new_selection_keeps_other_items_behind_more() -> None:
    with tempfile.TemporaryDirectory(prefix="zen-highlight-other-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "other.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library, zen_config_source=(
            "return { highlight_lookup = { allow_unknown_items = true }, updater = { update_auto_check = false } }\n"
        ))
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("highlight_tools", action="seed")
            assert state["ok"], state
            assert "zen_highlight_more" in state["menu_ids"] and "Copy" not in state["menu_ids"]
            selected = state["draft_text"]
            state = driver.command("highlight_tools", action="more")
            assert "Copy" in state["menu_ids"] and "lookup.dictionary" not in state["menu_ids"]
            assert state["handles"] and state["draft_text"] == selected
        finally:
            stop(process)


@pytest.mark.parametrize("use_pack", [False, True])
@pytest.mark.parametrize("show_labels", [False, True])
def test_highlight_menu_icons_and_settings_shortcut(use_pack: bool, show_labels: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="zen-highlight-icons-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        icons = home / "icons" / "zen" / "test-highlight" if use_pack else home / "icons"
        icons.mkdir(parents=True)
        if use_pack:
            (icons / "pack.json").write_text(
                '{"schema_version":1,"id":"test-highlight","name":"Test highlight"}', encoding="utf-8",
            )
        main_icons = ("font", "paint_palette", "edit", "trash", "more_vertical")
        more_icons = ("lookup.wikipedia", "lookup.dictionary", "lookup.translate", "lookup_ai",
                      "lookup.search", "appbar.settings")
        for name in main_icons + more_icons:
            (icons / (name + ".svg")).write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">'
                '<circle cx="12" cy="12" r="6"/></svg>', encoding="utf-8",
            )
        book = library / "icons.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        dimensions = {"EMULATE_READER_W": "320", "EMULATE_READER_H": "480"} if show_labels and use_pack else {}
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library, zen_config_source=(
            "return { features = { custom_icons_enabled = true }, custom_icons = { active_pack = '"
            + ("test-highlight" if use_pack else "") + "' }, highlight_lookup = { show_wikipedia = true, show_labels = "
            + str(show_labels).lower() + " }, "
            "updater = { update_auto_check = false } }\n"
        ), env_overrides=dimensions)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("highlight_tools", action="seed", saved=True, ai=True)
            assert state["ok"], state
            assert state["menu_ids"][-3:] == ["zen_highlight_delete", "zen_highlight_more", "zen_pin"]
            assert state["menu_icon_files"][:-1] == [str(icons / (name + ".svg")) for name in main_icons]
            assert state["menu_icon_files"][-1].endswith("/icons/pin.svg")
            buttons = [button for row in state["menu_buttons"] for button in row]
            assert [button["text"] for button in buttons[:5]] == (
                ["Style", "Color", "Note", "Delete", "More"] if show_labels else [""] * 5
            )
            assert all(button["content_width"] <= button["width"] for button in buttons)
            state = driver.command("highlight_tools", action="more")
            assert state["menu_ids"][-2:] == ["zen_highlight_settings", "zen_pin"]
            assert state["menu_icon_files"][:-1] == [str(icons / (name + ".svg")) for name in more_icons]
            assert state["menu_icon_files"][-1].endswith("/icons/pin.svg")
            buttons = [button for row in state["menu_buttons"] for button in row]
            assert [button["text"] for button in buttons[:6]] == (
                ["Wikipedia", "Dictionary", "Translate", "AI assistant", "Search", "Settings"] if show_labels else [""] * 6
            )
            assert all(button["content_width"] <= button["width"] for button in buttons)
            if show_labels:
                scale = min(state["screen_w"], state["screen_h"]) / 600
                assert all(button["icon_width"] < 32 * scale for button in buttons[:6])
                artifact = Path(__file__).resolve().parents[2] / ".artifacts" / "highlight-handles"
                artifact.mkdir(parents=True, exist_ok=True)
                driver.screenshot(artifact / ("menu-labels-narrow.png" if use_pack else "menu-labels.png"))
            state = driver.command("highlight_tools", action="settings")
            assert state["count"] == 1 and state["note"] == "Preserved note"
            settings = _wait_command(driver, "settings_page_state", lambda result:
                                     result.get("settings", {}).get("title") == "Highlight")["settings"]
            assert settings["labels"][:2] == ["Menu items", "Show labels"]
            assert settings["items"][0]["submenu"]
            assert driver.command("settings_page_select", label="Menu items")["ok"]
            assert driver.command("arrange_page_state")["arrange"]["labels"][:3] == ["Style", "Color", "Note"]
        finally:
            stop(process)
