import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

from zen_driver import ZenDriver, launch, stop, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_LEGACY_UPGRADE") != "1",
    reason="run through ./spec/run legacy-upgrade with a staged compatibility package",
)


def _lua_string(value: object) -> str:
    return json.dumps(str(value))


def _expect_restart(process: subprocess.Popen[str], phase: str) -> None:
    try:
        code = process.wait(timeout=45)
    except subprocess.TimeoutExpired:
        stop(process)
        pytest.fail(f"{phase} did not restart KOReader")
    assert code == 85, f"{phase} exited with {code}, expected KOReader restart code 85"


def _seed_legacy_install(ko_home: Path, library: Path, legacy_plugin: Path) -> None:
    settings = ko_home / "settings" / "Zen UI"
    settings.mkdir(parents=True)
    old_font = legacy_plugin / "fonts" / "hyperreadable" / "Hyperreadable-Regular.ttf"
    old_icon = legacy_plugin / "icons" / "zen_ui.svg"

    settings.joinpath("config.lua").write_text(
        f"""return {{
  _meta = {{
    quickstart_shown_for_version = "3.0.0",
    quickstart_completed = true,
  }},
  migration_fixture = "config-preserved",
  updater = {{ update_auto_check = false, update_channel = "beta" }},
  library_font = {{ font_face = {_lua_string(old_font)} }},
  quick_settings = {{
    next_custom_id = 9,
    button_order = {{ "cb_9" }},
    show_buttons = {{ cb_9 = true }},
    custom_buttons = {{
      {{
        id = "cb_9",
        type = "action",
        label = "Migration fixture",
        icon = "zen_ui",
        action = {{ history = {{}} }},
      }},
    }},
  }},
}}
""",
        encoding="utf-8",
    )
    settings.joinpath("reader.lua").write_text(
        f"""return {{
  active_preset = "(Zen UI) Chapter Time + %",
  settings = {{
    reader_footer_custom_text = "Zen UI",
    footer = {{ text_font_face = {_lua_string(old_font)} }},
  }},
  presets = {{
    ["(Zen UI) Chapter Time + %"] = {{
      name = "(Zen UI) Chapter Time + %",
      reader_footer_custom_text = "Zen UI",
    }},
    custom = {{ name = "custom", reader_footer_custom_text = "Zen UI" }},
  }},
}}
""",
        encoding="utf-8",
    )
    settings.joinpath("home.lua").write_text(
        f"""return {{
  migration_fixture = "home-preserved",
  fixture_path = {_lua_string(old_icon)},
}}
""",
        encoding="utf-8",
    )
    settings.joinpath("unknown.txt").write_text("preserve unknown files\n", encoding="utf-8")
    ko_home.joinpath("settings.reader.lua").write_text(
        f"""return {{
  home_dir = {_lua_string(library)},
  start_with = "filemanager",
  plugins_disabled = {{ zen_ui = true }},
  footer = {{ text_font_face = {_lua_string(old_font)} }},
  reader_footer_custom_text = "Zen UI",
}}
""",
        encoding="utf-8",
    )


def test_disabled_legacy_plugin_enables_migrates_and_restarts_twice() -> None:
    runtime = Path(os.environ["KOREADER_DIR"]).resolve()
    legacy_plugin = runtime / "plugins" / "zen_ui.koplugin"
    canonical_plugin = runtime / "plugins" / "zenos.koplugin"
    assert legacy_plugin.is_dir()
    assert not canonical_plugin.exists()

    with tempfile.TemporaryDirectory(prefix="zenos-legacy-upgrade-") as temporary:
        root = Path(temporary)
        ko_home, library = root / "home", root / "library"
        ko_home.mkdir()
        library.mkdir()
        legacy_settings = ko_home / "settings" / "Zen UI"
        canonical_settings = ko_home / "settings" / "ZenOS"
        _seed_legacy_install(ko_home, library, legacy_plugin)
        socket_path = root / "driver.sock"

        first_boot = launch(
            runtime, ko_home, socket_path, library, initialize_settings=False
        )
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            discovered = driver.command("legacy_plugin_manager_state")
            assert discovered["ok"] is True
            assert discovered["name"] == "zen_ui"
            assert discovered["fullname"] == "ZenOS"
            assert Path(str(discovered["path"])).name == "zen_ui.koplugin"
            assert driver.plugin_loaded("zen_ui") is False

            enabled = driver.command("enable_legacy_plugin")
            assert enabled["ok"] is True
            assert enabled["name"] == "zen_ui"
            assert enabled["enable_path"] in {"dialog", "toggle"}
            if enabled["enable_path"] == "dialog":
                assert enabled["enable_label"] == "Enable plugin"
            assert enabled["legacy_disabled"] is False
            _expect_restart(first_boot, "plugin-manager enable")
        finally:
            stop(first_boot)

        assert legacy_plugin.is_dir()
        assert not canonical_plugin.exists()
        assert legacy_settings.is_dir()
        assert not canonical_settings.exists()

        socket_path.unlink(missing_ok=True)
        migration_boot = launch(
            runtime, ko_home, socket_path, library, initialize_settings=False
        )
        try:
            _expect_restart(migration_boot, "legacy-to-canonical migration")
        finally:
            stop(migration_boot)

        assert not legacy_plugin.exists()
        assert canonical_plugin.is_dir()
        assert canonical_settings.is_dir()
        assert legacy_settings.is_dir()
        assert not legacy_settings.is_symlink()
        assert canonical_settings.joinpath("unknown.txt").read_text(encoding="utf-8") == (
            "preserve unknown files\n"
        )
        assert legacy_settings.joinpath("unknown.txt").read_text(encoding="utf-8") == (
            "preserve unknown files\n"
        )
        legacy_config = legacy_settings.joinpath("config.lua").read_text(encoding="utf-8")
        canonical_config = canonical_settings.joinpath("config.lua").read_text(
            encoding="utf-8"
        )
        assert str(legacy_plugin / "fonts" / "hyperreadable") in legacy_config
        assert str(canonical_plugin / "fonts" / "hyperreadable") not in legacy_config
        assert str(canonical_plugin / "fonts" / "hyperreadable") in canonical_config
        migrated_reader = canonical_settings.joinpath("reader.lua").read_text(encoding="utf-8")
        assert "(ZenOS) Chapter Time + %" in migrated_reader
        assert "(Zen UI) Chapter Time + %" not in migrated_reader
        legacy_reader = legacy_settings.joinpath("reader.lua").read_text(encoding="utf-8")
        assert "(Zen UI) Chapter Time + %" in legacy_reader
        assert "(ZenOS) Chapter Time + %" not in legacy_reader

        socket_path.unlink(missing_ok=True)
        final_boot = launch(
            runtime, ko_home, socket_path, library, initialize_settings=False
        )
        try:
            wait_for_socket(socket_path)
            driver = ZenDriver(socket_path)
            assert driver.plugin_loaded("zenos") is True
            assert driver.plugin_loaded("zen_ui") is True

            state = driver.command("brand_migration_state")
            assert state["ok"] is True
            assert state["plugin_alias_same"] is True
            assert Path(str(state["plugin_root"])).name == "zenos.koplugin"
            assert Path(str(state["settings_root"])).resolve() == canonical_settings.resolve()
            assert state["marker"] is True
            assert state["fixture"] == "config-preserved"
            assert state["update_channel"] == "beta"
            assert state["library_font"] == (
                "fonts/hyperreadable/Hyperreadable-Regular.ttf"
            )
            assert state["custom_button_label"] == "Migration fixture"
            assert state["custom_button_icon"] == "zen_ui"
            assert state["reader_has_legacy_preset"] is False
            assert state["reader_has_canonical_preset"] is True
            assert state["reader_builtin_footer"] == "ZenOS"
            assert state["reader_custom_footer"] == "Zen UI"
            assert state["reader_footer_font"] == str(
                canonical_plugin / "fonts" / "hyperreadable" / "Hyperreadable-Regular.ttf"
            )
            assert state["home_fixture"] == "home-preserved"
            assert state["home_path"] == str(canonical_plugin / "icons" / "zen_ui.svg")
            assert state["global_footer_font"] == str(
                canonical_plugin / "fonts" / "hyperreadable" / "Hyperreadable-Regular.ttf"
            )
            assert state["global_reader_footer"] == "ZenOS"
            assert state["legacy_disabled_present"] is False
            assert state["canonical_disabled"] is False
            assert state["canonical_effectively_enabled"] is True

            assert driver.command("open_settings_page")["ok"] is True
            settings_state = driver.command("settings_page_state")
            assert settings_state["settings"]["title"] == "Settings"
            assert "Zen UI" not in settings_state["settings"]["title"]
        finally:
            stop(final_boot)
