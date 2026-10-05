import os
import signal
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import pytest

from fixtures import build_library
from zen_driver import (
    ZenDriver,
    launch,
    wait_for_socket,
)


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1",
    reason="set ZEN_UI_RUN_EMULATOR=1 to run a real KOReader emulator",
)


def _launch_flat_view(
    runtime: Path, ko_home: Path, socket_path: Path, library: Path
) -> subprocess.Popen[str]:
    settings_dir = ko_home / "settings" / "ZenOS"
    settings_dir.mkdir(parents=True, exist_ok=True)
    (ko_home / "settings.reader.lua").write_text(
        'return { ["home_dir"] = ' + repr(str(library.resolve())) + " }\n",
        encoding="utf-8",
    )
    (settings_dir / "config.lua").write_text(
        "return { updater = { update_auto_check = false }, "
        "browser_flat_view = { enabled = true } }\n",
        encoding="utf-8",
    )
    return launch(runtime, ko_home, socket_path, library, initialize_settings=False)


def test_flat_view_pulls_books_out_of_subfolders() -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    with tempfile.TemporaryDirectory(prefix="zen-ui-flat-view-") as temporary:
        root = Path(temporary)
        ko_home = root / "home"
        ko_home.mkdir()
        library = root / "library"
        fixture = build_library(library)
        nested = fixture["epub"].parent / "Nested"
        nested.mkdir()
        deep_book = nested / "Deep.epub"
        shutil.copyfile(fixture["epub"], deep_book)
        socket_path = root / "driver.sock"
        process = _launch_flat_view(runtime, ko_home, socket_path, library)
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            expected = str(deep_book.resolve())
            nested_dir = str(nested.resolve())
            series_dir = str(fixture["epub"].parent.resolve())
            deadline = time.monotonic() + 15
            paths: set[str] = set()
            while time.monotonic() < deadline:
                response = driver.command("file_chooser_items")
                state = response.get("file_chooser", {})
                if isinstance(state, dict):
                    items = state.get("items", [])
                    if isinstance(items, list):
                        paths = {
                            str(Path(path).resolve())
                            for entry in items
                            if isinstance(entry, dict)
                            for path in [entry.get("path")]
                            if isinstance(path, str)
                        }
                if expected in paths:
                    break
                time.sleep(0.1)

            assert expected in paths
            assert series_dir not in paths
            assert nested_dir not in paths
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
