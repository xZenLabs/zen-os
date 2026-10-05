"""Deterministic KOReader framebuffer and semantic-selector test driver."""

from __future__ import annotations

import argparse
import shutil
import json
import os
import socket
import sqlite3
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageChops


STARTUP_ALERT_PATCH = Path(__file__).with_name("userpatches") / (
    "2-zen-ui-suppress-startup-alerts.lua"
)

_BIDI_CONTROLS = str.maketrans(
    "", "", "\u061c\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069"
)


@dataclass(frozen=True)
class Bounds:
    x: int
    y: int
    width: int
    height: int


def normalize_visible_text(value: str) -> str:
    """Remove invisible bidi formatting added by KOReader widgets."""
    return value.translate(_BIDI_CONTROLS)


def compare_frames(expected: Path, actual: Path, diff: Path) -> bool:
    """Return true only for exact stable-emulator framebuffer matches."""
    with Image.open(expected) as expected_image, Image.open(actual) as actual_image:
        if expected_image.size != actual_image.size:
            actual_image.save(diff)
            return False
        delta = ImageChops.difference(expected_image.convert("RGB"), actual_image.convert("RGB"))
        if delta.getbbox() is None:
            return True
        diff.parent.mkdir(parents=True, exist_ok=True)
        delta.save(diff)
        return False


def update_or_compare_golden(actual: Path, expected: Path, diff: Path, update: bool) -> None:
    if update:
        expected.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(actual, expected)
        return
    if not expected.exists():
        raise AssertionError(
            f"missing committed golden: {expected}; run ./spec/run update-goldens on Linux/Xvfb"
        )
    if expected.exists() and not compare_frames(expected, actual, diff):
        raise AssertionError(f"framebuffer differs from golden: {expected}")


class ZenDriver:
    def __init__(self, socket_path: Path):
        self.socket_path = socket_path

    def command(self, kind: str, **params: object) -> dict[str, object]:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(10)
            deadline = time.monotonic() + 10
            while True:
                try:
                    client.connect(str(self.socket_path))
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    # Browser/reader transitions briefly recreate the socket.
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.1)
            client.sendall((json.dumps({"type": kind, "params": params}) + "\n").encode())
            response = client.makefile("r", encoding="utf-8").readline()
        return json.loads(response)

    def visible_ui(self) -> dict[str, object]:
        return self.command("visible_ui")

    def plugin_loaded(self, name: str) -> bool:
        response = self.command("plugin_loaded", name=name)
        return response.get("ok") is True and response.get("loaded") is True

    def screenshot(self, output: Path) -> None:
        self.command("screenshot", output=str(output))

    def checkpoint(self, name: str) -> dict[str, object]:
        return self.command("checkpoint", name=name)

    def open_book(self, path: Path) -> dict[str, object]:
        return self.command("open_book", path=str(path.resolve()))

    def reader_state(self) -> dict[str, object]:
        return self.command("reader_state")

    def reader_menu_home(self) -> dict[str, object]:
        return self.command("reader_menu_home")

    def file_chooser_next_page(self) -> dict[str, object]:
        return self.command("file_chooser_next_page")


def find_text(node: dict[str, object], text: str) -> Bounds | None:
    """Find a visible widget by its stable displayed text and geometry."""
    if node.get("text") == text:
        return Bounds(
            int(node.get("x", 0)),
            int(node.get("y", 0)),
            int(node.get("width", 0)),
            int(node.get("height", 0)),
        )
    children = node.get("children", [])
    if isinstance(children, list):
        for child in children:
            if isinstance(child, dict):
                result = find_text(child, text)
                if result:
                    return result
    return None


def tap(bounds: Bounds) -> None:
    """Send a real pointer tap to the current emulator window."""
    import pyautogui

    pyautogui.click(bounds.x + bounds.width // 2, bounds.y + bounds.height // 2)


def install_startup_alert_patch(ko_home: Path) -> Path:
    """Install the late KOReader patch without replacing an existing patch."""
    patch_path = ko_home / "patches" / STARTUP_ALERT_PATCH.name
    patch_path.parent.mkdir(parents=True, exist_ok=True)
    if not patch_path.exists():
        shutil.copyfile(STARTUP_ALERT_PATCH, patch_path)
    return patch_path


def launch(
    koreader_dir: Path,
    ko_home: Path,
    socket_path: Path,
    library_dir: Path | None = None,
    zen_config_source: str | None = None,
    env_overrides: dict[str, str] | None = None,
    language: str | None = None,
    initialize_settings: bool = True,
) -> subprocess.Popen[str]:
    if socket_path.is_socket():
        socket_path.unlink()
    elif socket_path.exists():
        raise FileExistsError(f"KOReader test socket path is occupied: {socket_path}")
    settings_parent = ko_home / "settings"
    settings_parent.mkdir(parents=True, exist_ok=True)
    install_startup_alert_patch(ko_home)
    bookinfo_cache = settings_parent / "bookinfo_cache.sqlite3"
    if not bookinfo_cache.exists():
        with sqlite3.connect(bookinfo_cache) as connection:
            connection.execute("PRAGMA user_version=20201210")
    if initialize_settings:
        settings_dir = settings_parent / "ZenOS"
        settings_dir.mkdir(parents=True, exist_ok=True)
        home_dir = str(library_dir.resolve()) if library_dir else ""
        language_setting = ', ["language"] = ' + repr(language) if language else ""
        (ko_home / "settings.reader.lua").write_text(
            'return { ["home_dir"] = ' + repr(home_dir) + language_setting + ' }\n',
            encoding="utf-8",
        )
        (settings_dir / "config.lua").write_text(
            zen_config_source
            or 'return { updater = { update_auto_check = false } }\n',
            encoding="utf-8",
        )
    env = os.environ.copy()
    foreground = env.get("ZEN_UI_TEST_FOREGROUND") == "1"
    env.update({
        "KO_HOME": str(ko_home),
        "ZEN_UI_TEST_SOCKET": str(socket_path),
        "ZEN_UI_TESTING": "1",
        "SDL_MAC_BACKGROUND_APP": "0" if foreground else "1",
        "SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN": "0" if foreground else "1",  # SDL2
        "SDL_WINDOW_ACTIVATE_WHEN_SHOWN": "1" if foreground else "0",  # SDL3
        "SDL_WINDOW_ACTIVATE_WHEN_RAISED": "1" if foreground else "0",
    })
    if env_overrides:
        env.update(env_overrides)
    return subprocess.Popen([str(koreader_dir / "reader.lua")], cwd=koreader_dir, env=env, text=True)


def wait_for_socket(path: Path, timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.1)
    raise TimeoutError(f"KOReader test socket did not appear: {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compare", nargs=3, metavar=("EXPECTED", "ACTUAL", "DIFF"))
    args = parser.parse_args()
    if args.compare:
        return 0 if compare_frames(*(Path(value) for value in args.compare)) else 1
    parser.error("choose an action")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
