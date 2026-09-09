import os
import signal
import subprocess
import tempfile
from pathlib import Path

import pytest

from zen_driver import ZenDriver, launch, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1",
    reason="set ZEN_UI_RUN_EMULATOR=1 to run a real KOReader emulator",
)


def _capture(driver: ZenDriver, name: str) -> Path:
    output = Path(__file__).parents[2] / ".artifacts" / "metadata-editor" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    driver.screenshot(output)
    assert output.stat().st_size > 0
    return output


def test_metadata_editor_visual_fixtures() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-metadata-visual-") as temporary:
        root = Path(temporary)
        ko_home, library = root / "home", root / "library"
        ko_home.mkdir()
        library.mkdir()
        socket_path = root / "driver.sock"
        process = launch(runtime, ko_home, socket_path, library)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.command(
                "configure_showcase", timestamp=1704067200, wifi=True
            )["ok"] is True

            portrait = driver.command(
                "show_metadata_editor_fixture", orientation="portrait"
            )
            assert portrait["ok"] is True, portrait
            portrait_state = portrait["metadata"]
            assert portrait_state["dirty"] is True
            assert portrait_state["title_action"].endswith("Save")
            assert portrait_state["title_action"] != "Save"
            assert portrait_state["title_action_zen"] is True
            assert portrait_state["title_action_font_size"] == 22
            assert portrait_state["title"] == "The Strength of the Few"
            assert portrait_state["edition_summary"] == "Paperback, 2024 · Orbit"
            assert portrait_state["open_with_text"] == "Open with…"
            assert portrait_state["restore_text"] == "Restore"
            assert portrait_state["hardcover_filled"] is True
            assert portrait_state["has_pending_cover"] is True
            assert portrait_state["width"] < portrait_state["height"]
            assert portrait_state["page_count"] == 1
            assert portrait_state["fields"] == [
                "Book details",
                "Description",
            ]
            _capture(driver, "metadata-editor-portrait.png")

            landscape = driver.command(
                "show_metadata_editor_fixture", orientation="landscape"
            )
            assert landscape["ok"] is True, landscape
            landscape_state = landscape["metadata"]
            assert landscape_state["dirty"] is True
            assert landscape_state["title_action"].endswith("Save")
            assert landscape_state["width"] > landscape_state["height"]
            assert landscape_state["page_count"] == 1
            _capture(driver, "metadata-editor-landscape.png")

            cover = driver.command("show_metadata_cover_fixture")
            assert cover["ok"] is True, cover
            _capture(driver, "metadata-cover-picker.png")

            picker = driver.command("show_metadata_picker_fixture")
            assert picker["ok"] is True, picker
            assert picker["width"] < picker["height"]
            assert picker["picker"]["title"] == "Choose an edition"
            assert picker["picker"]["labels"][1] == "Hardcover, 2025"
            assert "Orbit" in picker["picker"]["secondary_labels"][1]
            _capture(driver, "metadata-hardcover-picker.png")
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
