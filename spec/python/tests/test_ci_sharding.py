import os
from pathlib import Path
import shutil
import subprocess
import sys


def test_ci_shards_cover_every_test_once_and_reject_invalid_settings(tmp_path: Path) -> None:
    shutil.copyfile(Path(__file__).with_name("conftest.py"), tmp_path / "conftest.py")
    (tmp_path / "test_sample.py").write_text(
        'import pytest\n@pytest.mark.parametrize("case", range(11))\n'
        'def test_sample(case):\n    pass\n', encoding="utf-8",
    )
    env = os.environ.copy()
    env.pop("ZEN_UI_PYTEST_SHARD", None)
    env.pop("PYTEST_ADDOPTS", None)

    def collect():
        return subprocess.run(
            [sys.executable, "-m", "pytest", "--collect-only", "-q"],
            cwd=tmp_path, env=env, capture_output=True, text=True,
        )

    full = collect()
    assert full.returncode == 0, full.stderr
    expected = {line for line in full.stdout.splitlines() if "::" in line}
    assert len(expected) == 11
    for count in (1, 4):
        seen = set()
        for index in range(1, count + 1):
            env["ZEN_UI_PYTEST_SHARD"] = f"{index}/{count}"
            result = collect()
            assert result.returncode == 0, result.stderr
            selected = {line for line in result.stdout.splitlines() if "::" in line}
            assert not seen & selected
            seen.update(selected)
        assert seen == expected

    for invalid in ("bad", "0/4", "5/4", "1/0"):
        env["ZEN_UI_PYTEST_SHARD"] = invalid
        result = collect()
        assert result.returncode == 4
        assert "ZEN_UI_PYTEST_SHARD must be INDEX/COUNT" in result.stderr
