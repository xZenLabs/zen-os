import os
from pathlib import Path

import pytest
from PIL import Image

from fixtures import build_library
from website_screenshots import CaptureWorkflow, ResolvedBook, load_catalog


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_CAPTURE_INTEGRATION") != "1",
    reason="set ZEN_UI_CAPTURE_INTEGRATION=1 with a staged runtime",
)


def test_representative_home_library_stats_reader_and_page_browser_capture(
    tmp_path: Path,
) -> None:
    runtime = Path(os.environ["KOREADER_DIR"])
    fixture = build_library(tmp_path / "fixture")
    source = fixture["epub"]
    titles = [
        "Never Split the Difference", "Flow", "Atomic Habits", "Project Hail Mary",
        "The Clean Coder", "Do Less", "The Creative Habit", "The Martian",
        "System Design", "Deep Work", "The Let Them Theory", "Wild",
    ]
    books = []
    for index, title in enumerate(titles):
        path = tmp_path / "sources" / f"{title}.epub"
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(source.read_bytes())
        role = "featured" if index == 0 else "reader" if title == "Do Less" else "library"
        books.append(ResolvedBook(index + 1, title, "Showcase Author", None, path, role, "EPUB"))
    ids = {
        "zen_home", "library_covers_full", "library_list_full", "metadata_editor",
        "stats", "reader", "page_browser_grid", "page_browser_carousel",
    }
    scenarios = [scenario for scenario in load_catalog() if scenario.id in ids]
    run_dir = tmp_path / "artifacts"
    report = CaptureWorkflow(runtime, scenarios, books, run_dir, None).run()
    assert all(result["status"] == "passed" for result in report["results"]), report
    assert report["settings_baseline_files_unchanged"] is True
    for result in report["results"]:
        if result["session"] == "reader":
            assert result["reader_page"] == 10
            assert result["reader_preset"] == "(ZenOS) Chapter Time + %"
    assert {path.name for path in run_dir.glob("*.png")} == {
        f"{screen_id}.png" for screen_id in ids
    }
    assert not (run_dir / "raw").exists()
    for path in run_dir.glob("*.png"):
        with Image.open(path) as image:
            assert image.size == (1272, 1696)
