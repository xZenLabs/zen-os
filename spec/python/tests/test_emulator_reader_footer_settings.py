import os
import tempfile
from pathlib import Path

import pytest

from test_emulator_reader_tools import _write_reader_epub
from zen_driver import ZenDriver, launch, stop, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires the KOReader emulator",
)


def test_bottom_bar_settings_apply_on_next_reader_open() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-footer-settings-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "footer.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert not driver.command("reader_state")["reader"]["open"]
            assert driver.command("open_settings_page")["ok"]
            assert driver.command("settings_page_select", label="Reader")["ok"]
            items = driver.command("settings_page_state")["settings"]["items"]
            annotation = next(item for item in items if item["label"] == "Annotation viewer")
            assert annotation["icon_file"].endswith("/icons/bookmark.svg")
            for label in ("Appearance", "Bottom status bar", "Status bar items"):
                result = driver.command("settings_page_select", label=label)
                assert result["ok"], result
            items = driver.command("settings_page_state")["settings"]["items"]
            assert items[0]["label"] == "Pinned pages" and items[0]["checked"]
            assert driver.command("settings_page_select", label="Pinned pages")["ok"]
            clock = next(item for item in items if item["label"].startswith("Current time"))
            title = next(item for item in items if item["label"] == "Book title")
            assert driver.command("settings_page_select", label=clock["label"])["ok"]
            assert driver.command("settings_page_select", label=title["label"])["ok"]
            assert driver.command("close_settings_page")["ok"]
            assert driver.open_book(book)["ok"]
            state = driver.command("reader_state")["reader"]
            assert state["open"]
            assert state["footer_time"] == (not clock["checked"])
            assert state["footer_book_title"] == (not title["checked"])
            references = driver.command("reference_action", action="paint")["references"]
            assert references["footer_pinned_pages"] is False
        finally:
            stop(process)


def test_status_bars_reserve_only_their_height_plus_user_margins() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-bar-margins-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "margins.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            for top, bottom in ((0, 0), (13, 27), (30, 30)):
                result = driver.command("reader_controls", action="setting",
                                        name="t_page_margin", value=[top, bottom])
                assert result["ok"], result
                assert driver.command("reader_controls", action="paint")["ok"]
                state = driver.reader_state()["reader"]
                assert state["page_margins"]["top"] == state["header_height"] + state["user_top_margin"]
                assert state["page_margins"]["bottom"] == state["footer_height"] + state["user_bottom_margin"]
        finally:
            stop(process)


@pytest.mark.parametrize("preset", ["(ZenOS) Chapter Time + %", "My preset", None])
def test_existing_margins_migrate_only_for_zen_presets(preset: str | None) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-margin-upgrade-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        books = [library / "first.epub", library / "second.epub"]
        for book in books:
            _write_reader_epub(book)
            sidecar = book.with_suffix(".sdr")
            sidecar.mkdir()
            (sidecar / "metadata.epub.lua").write_text(
                "return {copt_t_page_margin=30,copt_b_page_margin=30,"
                "copt_h_page_margins={41,51},copt_font_size=25}\n",
            )
        (home / "settings.reader.lua").write_text(
            "return {home_dir=" + repr(str(library.resolve()))
            + ",copt_t_page_margin=30,copt_b_page_margin=30}\n",
        )
        settings = home / "settings" / "ZenOS"
        settings.mkdir(parents=True)
        (settings / "config.lua").write_text(
            "return {updater={update_auto_check=false},"
            "_meta={quickstart_completed=true,footer_backup_created=true}}\n",
        )
        (settings / "reader.lua").write_text(
            "return {settings={},presets={},active_preset=" + (repr(preset) if preset else "nil") + "}\n",
        )
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library, initialize_settings=False)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            expected_margin = 15 if preset == "(ZenOS) Chapter Time + %" else 30
            keys = ["t_page_margin", "b_page_margin", "h_page_margins", "font_size"]
            for book in books:
                assert driver.open_book(book)["ok"]
                active = driver.reader_state()["reader"].get("active_preset")
                assert active == preset
                state = driver.command("native_settings_state", keys=keys)
                values = state["values"]
                assert values == {"t_page_margin": expected_margin, "b_page_margin": expected_margin,
                                  "h_page_margins": [41, 51], "font_size": 25}, (
                    values, state["defaults"], active,
                )
                defaults = driver.command("reader_controls")
                assert defaults["default_top"] == expected_margin
                assert defaults["default_bottom"] == expected_margin
                assert driver.command("reader_controls", action="setting",
                                      name="t_page_margin", value=[22, 24])["ok"]
                assert driver.command("reference_action", action="close_book")["ok"]
                assert driver.open_book(book)["ok"]
                values = driver.command("native_settings_state", keys=keys)["values"]
                assert values["t_page_margin"] == 22
                assert values["b_page_margin"] == 24
                assert driver.command("reference_action", action="close_book")["ok"]
        finally:
            stop(process)


@pytest.mark.parametrize("settings", [
    {"progress_bar_position": "alongside"},
    {"progress_bar_position": "below"},
    {"all_at_once": False},
    {"progress_style_thin": True},
])
def test_progress_bar_only_footer_tap_toggles_both_ways(settings) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-footer-tap-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "tap.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            state = driver.command("reference_action", action="footer_progress_only", settings=settings)["references"]
            assert state["has_no_mode"] and state["footer_visible"]
            for visible in (False, True, False, True):
                state = driver.command("reference_action", action="footer_tap")["references"]
                assert state["footer_visible"] is visible, state
                assert state["zen_enabled"], state
        finally:
            stop(process)


def test_preset_footer_tap_hides_then_restores_item_repeatedly() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-footer-cycle-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "cycle.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            assert driver.command("reference_action", action="pin", page=1)["ok"]
            driver.command("reference_action", action="footer_state", preset=5,
                           settings={"lock_tap": False, "all_at_once": False})
            names = [driver.command("reference_action", action="footer_tap")["references"]["mode_name"]
                     for _i in range(8)]
            # Hide on tap toggles off and restores the shown item; it never cycles items.
            assert names == ["off", "chapter_time_to_read"] * 4, names
        finally:
            stop(process)


@pytest.mark.parametrize("settings", [
    {"progress_bar_position": "alongside"},
    {"progress_bar_position": "alongside", "all_at_once": True, "dynamic_filler": True, "dynamic_filler2": True},
])
def test_progress_bar_only_footer_spans_reader_margins(settings) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-footer-span-") as temporary:
        root = Path(temporary)
        home, library = root / "home", root / "library"
        home.mkdir()
        library.mkdir()
        book = library / "span.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        config = "return {updater={update_auto_check=false},features={reader_status_bar_margins=true}}"
        process = launch(runtime, home, socket, library, zen_config_source=config)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            driver.command("reference_action", action="footer_progress_only", settings=settings)
            # Geometry is recorded at paint; read it after the settings repaint.
            state = driver.command("reference_action", action="footer_state")["references"]
            left, right = state["margins"]
            assert state["bar"] == {"x": left, "w": state["screen_w"] - left - right}, state
            assert driver.command("reference_action", action="pin", page=1)["ok"]
            driver.command("reference_action", action="footer_progress_only", settings=settings)
            state = driver.command("reference_action", action="footer_state")["references"]
            assert state["bar"]["x"] == left, state
            # Bar ends a short gap (8dp, plus space rounding when inline) before the pin box.
            gap = state["pin"]["x"] - state["bar"]["x"] - state["bar"]["w"]
            assert 0 < gap < 24, state
        finally:
            stop(process)
