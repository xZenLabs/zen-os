import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

import pytest
from PIL import Image

from fixtures import stage_epub_library
from zen_driver import ZenDriver, launch, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1",
    reason="set ZEN_UI_RUN_EMULATOR=1 to run a real KOReader emulator",
)


def _wait(driver, kind, predicate, **params):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        result = driver.command(kind, **params)
        if predicate(result):
            return result
        time.sleep(0.1)
    raise AssertionError(f"{kind}: {result}")


def _select(driver, label):
    result = driver.command("settings_page_select", label=label)
    assert result["ok"], result


@pytest.mark.parametrize("format", ["epub", "pdf"])
def test_native_settings_context_layout_selectors_and_defaults(format):
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-native-settings-") as temporary:
        root = Path(temporary)
        library, home = root / "library", root / "home"
        library.mkdir()
        home.mkdir()
        books = stage_epub_library(library)
        book = next(iter(books.values()))
        if format == "pdf":
            book = library / "settings.pdf"
            Image.new("RGB", (600, 800), "white").save(book, "PDF", resolution=72)
        socket = root / "driver.sock"
        process = launch(runtime, home, socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.command("open_settings_page")["ok"]
            _wait(driver, "settings_page_state", lambda result: result.get("ok") is True)
            labels = driver.command("settings_page_state")["settings"]["labels"]
            assert labels[-2] == "KOReader"
            settings = driver.command("settings_page_state")["settings"]
            while settings["page"] < settings["page_count"]:
                assert driver.command("settings_page_footer_tap", zone="right")["ok"]
                settings = driver.command("settings_page_state")["settings"]
            logo = settings["items"][-2]
            assert logo["icon_file"].endswith("/icons/koreader.png")
            bounds = logo["icon_bounds"]
            slot_center = settings["row_alignment"]["text_x"] - settings["standard_style"]["icon_width"] / 2 - settings["icon_gap"]
            assert bounds["x"] + bounds["w"] / 2 == pytest.approx(slot_center, abs=1)
            row = logo["row_bounds"]
            assert bounds["y"] + bounds["h"] / 2 == pytest.approx(row["y"] + row["h"] / 2, abs=1)
            artifact = Path(__file__).parents[2] / ".artifacts" / "goldens" / f"koreader-logo-{format}.png"
            artifact.parent.mkdir(parents=True, exist_ok=True)
            driver.screenshot(artifact)
            _select(driver, "KOReader")
            labels = driver.command("settings_page_state")["settings"]["labels"]
            assert labels == ["File browser", "Settings", "Tools", "Search", "Main menu", "Quit KOReader"]
            assert driver.command("close_settings_page")["ok"]
            assert driver.command("open_book", path=str(book))["ok"]
            _wait(driver, "reader_state", lambda result: result.get("reader", {}).get("open") is True)
            assert driver.command("open_settings_page")["ok"]
            _wait(driver, "settings_page_state", lambda result: result.get("ok") is True)
            # Opening a book must discard the previous browser route.
            _select(driver, "KOReader")
            labels = driver.command("settings_page_state")["settings"]["labels"]
            assert labels == ["Navigation", "Typesetting", "Settings", "Tools", "Search", "Main menu", "Quit KOReader"]
            _select(driver, "Typesetting")
            _select(driver, "Document settings")
            _select(driver, "Layout")
            _wait(driver, "settings_page_state", lambda result: result.get("settings", {}).get("title") == "Layout")
            field, label = ("font_size", "Font Size") if format == "epub" else ("contrast", "Contrast")
            state = driver.command("native_settings_state", keys=[field])
            before = state["values"][field]
            assert state["prefix"] == ("copt" if format == "epub" else "kopt")
            _select(driver, label)
            _select(driver, "More")
            _wait(driver, "settings_page_state", lambda result: "Apply" in result.get("settings", {}).get("labels", []))
            labels = driver.command("settings_page_state")["settings"]["labels"]
            assert {"Decrease", "Increase", "Apply", "Set as default"}.issubset(labels)
            _select(driver, "Increase")
            assert driver.command("native_settings_state", keys=[field])["values"][field] == before
            _select(driver, "Apply")
            state = _wait(driver, "native_settings_state", lambda result: result["values"][field] != before, keys=[field])
            after = state["values"][field]
            assert after == pytest.approx(before + (0.5 if format == "epub" else 0.1))
            assert driver.command("settings_page_select", index=1)["ok"]
            for invalid in ["-1", "9999"]:
                result = driver.command("native_settings_input", text=invalid, button="OK")
                assert result["ok"] and result["open"], result
            target = 12.5 if format == "epub" else 1.3
            result = driver.command("native_settings_input", text=str(target), button="OK")
            assert result["ok"] and not result["open"], result
            assert driver.command("native_settings_state", keys=[field])["values"][field] == after
            _select(driver, "Apply")
            _wait(driver, "native_settings_state", lambda result: result["values"][field] == target, keys=[field])
            after = target
            _select(driver, "Set as default")
            assert driver.command("native_settings_confirm")["ok"]
            assert driver.command("native_settings_state", keys=[field])["defaults"][field] == after
            _select(driver, "Increase")
            labels = driver.command("settings_page_state")["settings"]["labels"]
            _select(driver, next(label for label in labels if label.startswith("Default value:")))
            _select(driver, "Apply")
            assert driver.command("native_settings_state", keys=[field])["values"][field] == after
            _select(driver, "Increase")
            _select(driver, "Close")
            assert driver.command("native_settings_state", keys=[field])["values"][field] == after
            choices = driver.command("settings_page_state")["settings"]["items"]
            preset = next(item["label"] for item in choices if item.get("radio") and not item.get("checked"))
            _select(driver, preset)
            _wait(driver, "native_settings_state", lambda result: result["values"][field] != after, keys=[field])
            assert driver.command("settings_page_back")["ok"]
            if format == "epub":
                _select(driver, "L/R Margins")
                _select(driver, "More")
                _wait(driver, "settings_page_state", lambda result: result.get("settings", {}).get("title") == "Left/Right Margins")
                initial = driver.command("native_settings_state", keys=["h_page_margins"])["values"]["h_page_margins"]
                _select(driver, "Increase")
                _select(driver, "Apply")
                changed = driver.command("native_settings_state", keys=["h_page_margins"])["values"]["h_page_margins"]
                assert changed == [initial[0] + 1, initial[1]]
                _select(driver, "Set as default")
                assert driver.command("native_settings_confirm")["ok"]
                assert driver.command("native_settings_state", keys=["h_page_margins"])["defaults"]["h_page_margins"] == changed
                _select(driver, "Increase")
                labels = driver.command("settings_page_state")["settings"]["labels"]
                _select(driver, next(label for label in labels if label.startswith("Default values:")))
                _select(driver, "Apply")
                assert driver.command("native_settings_state", keys=["h_page_margins"])["values"]["h_page_margins"] == changed
                _select(driver, "Increase")
                _select(driver, "Close")
                assert driver.command("native_settings_state", keys=["h_page_margins"])["values"]["h_page_margins"] == changed
                assert driver.command("settings_page_back")["ok"]
                _select(driver, "Word Expansion")
                _select(driver, "More")
                _wait(driver, "settings_page_state", lambda result: "CJK scaling" in result.get("settings", {}).get("labels", []))
                _select(driver, "CJK scaling")
                _wait(driver, "settings_page_state", lambda result: result.get("settings", {}).get("title") == "CJK width scaling")
                _select(driver, "Increase")
                _select(driver, "Apply")
                assert driver.command("native_settings_state", keys=["cjk_width_scaling"])["values"]["cjk_width_scaling"] == 101
            assert driver.command("close_settings_page")["ok"]
            driver.screenshot(root / "reader-after-settings.png")
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
            process.wait()
