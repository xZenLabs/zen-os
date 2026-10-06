from pathlib import Path
import subprocess
from unittest.mock import MagicMock

from PIL import Image
import pytest

from zen_driver import (
    ZenDriver,
    compare_frames,
    find_text,
    install_startup_alert_patch,
    launch,
    normalize_visible_text,
    stop,
    update_or_compare_golden,
)


@pytest.mark.parametrize("args,foreground", [
    ([], "0"),
    (["--fg"], "1"),
    (["--fg", "unknown"], "1"),
    (["unknown", "--fg"], "1"),
])
def test_runner_accepts_foreground_flag(args, foreground) -> None:
    runner = Path(__file__).parents[2] / "run"
    result = subprocess.run(["bash", "-x", str(runner), *args], capture_output=True, text=True)
    assert result.returncode == 2
    assert f"+ export SDL_WINDOW_ACTIVATE_WHEN_SHOWN={foreground}" in result.stderr


@pytest.mark.parametrize("foreground,background", [("0", "1"), ("1", "0")])
def test_launch_controls_emulator_focus(tmp_path: Path, monkeypatch, foreground, background) -> None:
    popen = MagicMock()
    monkeypatch.setattr("zen_driver.subprocess.Popen", popen)
    monkeypatch.setenv("ZEN_UI_TEST_FOREGROUND", foreground)
    monkeypatch.delenv("SDL_MAC_BACKGROUND_APP", raising=False)
    monkeypatch.delenv("SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN", raising=False)
    monkeypatch.delenv("SDL_WINDOW_ACTIVATE_WHEN_SHOWN", raising=False)
    monkeypatch.delenv("SDL_WINDOW_ACTIVATE_WHEN_RAISED", raising=False)

    assert launch(
        tmp_path / "runtime", tmp_path / "home", tmp_path / "driver.sock",
        env_overrides={"EMULATE_READER_W": "400"},
    ) is popen.return_value

    env = popen.call_args.kwargs["env"]
    assert env["SDL_MAC_BACKGROUND_APP"] == background
    assert env["SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN"] == background
    assert env["SDL_WINDOW_ACTIVATE_WHEN_SHOWN"] == foreground
    assert env["SDL_WINDOW_ACTIVATE_WHEN_RAISED"] == foreground
    assert env["EMULATE_READER_W"] == "400"


@pytest.mark.parametrize("times_out", [False, True])
def test_stop_reaps_emulator_after_graceful_exit_or_timeout(times_out: bool) -> None:
    process = MagicMock()
    if times_out:
        process.wait.side_effect = [subprocess.TimeoutExpired("reader.lua", 15), 0]

    stop(process)

    process.terminate.assert_called_once_with()
    if times_out:
        process.kill.assert_called_once_with()
        assert process.wait.call_count == 2
        assert process.wait.call_args.args == ()
        assert process.wait.call_args.kwargs == {}
    else:
        process.kill.assert_not_called()
        process.wait.assert_called_once_with(timeout=15)


def test_command_waits_for_socket_handoff_without_resending(monkeypatch) -> None:
    client = MagicMock()
    client.__enter__.return_value = client
    client.connect.side_effect = [FileNotFoundError(), ConnectionRefusedError(), None]
    client.makefile.return_value.readline.return_value = '{"ok": true}\n'
    monkeypatch.setattr("zen_driver.socket.socket", lambda *_args: client)
    monkeypatch.setattr("zen_driver.time.sleep", lambda _seconds: None)

    assert ZenDriver(Path("driver.sock")).command("reader_state") == {"ok": True}
    assert client.connect.call_count == 3
    client.sendall.assert_called_once_with(b'{"type": "reader_state", "params": {}}\n')


@pytest.mark.parametrize("error", [FileNotFoundError, ConnectionRefusedError, PermissionError])
def test_command_stops_on_connection_timeout_or_other_errors(monkeypatch, error) -> None:
    client = MagicMock()
    client.__enter__.return_value = client
    client.connect.side_effect = error
    monkeypatch.setattr("zen_driver.socket.socket", lambda *_args: client)
    monkeypatch.setattr("zen_driver.time.monotonic", iter([0, 10]).__next__)

    with pytest.raises(error):
        ZenDriver(Path("driver.sock")).command("reader_state")
    client.connect.assert_called_once()
    client.sendall.assert_not_called()


def test_compare_frames_is_exact_and_writes_a_diff(tmp_path: Path) -> None:
    expected = tmp_path / "expected.png"
    actual = tmp_path / "actual.png"
    diff = tmp_path / "diff.png"
    Image.new("RGBA", (4, 4), "white").save(expected)
    Image.new("RGBA", (4, 4), "white").save(actual)
    assert compare_frames(expected, actual, diff)

    Image.new("RGBA", (4, 4), "black").save(actual)
    assert not compare_frames(expected, actual, diff)
    assert diff.exists()


def test_update_or_compare_golden_updates_only_when_explicit(tmp_path: Path) -> None:
    actual = tmp_path / "actual.png"
    expected = tmp_path / "goldens" / "frame.png"
    diff = tmp_path / "diff.png"
    Image.new("RGB", (2, 2), "white").save(actual)
    update_or_compare_golden(actual, expected, diff, update=True)
    assert expected.read_bytes() == actual.read_bytes()
    update_or_compare_golden(actual, expected, diff, update=False)

    with pytest.raises(AssertionError, match="missing committed golden"):
        update_or_compare_golden(actual, tmp_path / "missing.png", diff, update=False)


def test_find_text_returns_semantic_widget_bounds() -> None:
    tree = {
        "children": [
            {"text": "Library", "x": 10, "y": 20, "width": 100, "height": 30},
        ]
    }
    assert find_text(tree, "Library").x == 10
    assert find_text(tree, "Missing") is None


def test_normalize_visible_text_removes_bidi_formatting_controls() -> None:
    assert normalize_visible_text("\u2068#2 – Semantic Series\u2069") == (
        "#2 – Semantic Series"
    )
    assert normalize_visible_text("\u202aZen Author\u202c") == "Zen Author"


def test_startup_alert_patch_is_installed_once_and_preserves_choices(tmp_path: Path) -> None:
    patch = install_startup_alert_patch(tmp_path)
    source = patch.read_text(encoding="utf-8")
    assert 'G_reader_settings:has("quickstart_shown_version")' in source
    assert 'G_reader_settings:has("color_rendering")' in source
    assert "Device:hasColorScreen()" in source

    patch.write_text("-- existing user choice\n", encoding="utf-8")
    assert install_startup_alert_patch(tmp_path).read_text(encoding="utf-8") == (
        "-- existing user choice\n"
    )
