import json
from pathlib import Path

import pytest

import zen_bench


@pytest.mark.parametrize("rects,expected", [
    ([], (0, 0, 0)),
    ([[0, 0, 10, 10]], (100, 100, 100)),
    ([[0, 0, 10, 10], [5, 5, 10, 10]], (175, 200, 100)),
    ([[0, 0, 10, 10], [0, 0, 10, 10]], (100, 200, 100)),
    ([[-5, -5, 10, 10]], (25, 25, 25)),  # clipped to the screen
    ([[95, 95, 20, 20], [0, 0, 0, 5]], (25, 25, 25)),
])
def test_rect_union(rects, expected) -> None:
    assert zen_bench.rect_union(rects, 100, 100) == expected


def test_stats_percentiles() -> None:
    result = zen_bench.stats([float(value) for value in range(10, 0, -1)])
    assert (result["median"], result["min"], result["max"]) == (5.5, 1, 10)
    assert (result["p10"], result["p90"]) == (1, 9)
    assert zen_bench.stats([]) is None


def _iteration(wall: float, frame: str = "a", status: str = "PASS") -> dict:
    return {"status": status, "wall_time_ms": wall, "framebuffer_hash": frame,
            "refresh_requests": [[0, 0, 50, 100, "ui", False]], "actual_refreshes": [[0, 0, 50, 50]]}


def test_analyze_scenario_metrics_and_frozen_frames() -> None:
    paging = {"kind": "paging", "requested_transitions": 2, "iterations": [_iteration(10, "a"), _iteration(12, "b")]}
    result = zen_bench.analyze_scenario(paging, 100, 100)
    assert result["status"] == "PASS"
    assert result["wall_time_ms"]["median"] == 11
    assert result["unique_dirty_pct"]["median"] == 50
    assert result["actual_unique_dirty_pct"]["median"] == 25

    frozen = {"kind": "paging", "requested_transitions": 2, "iterations": [_iteration(10, "a"), _iteration(12, "a")]}
    assert zen_bench.analyze_scenario(frozen, 100, 100)["status"] == "FAILED"

    short = {"kind": "paging", "requested_transitions": 3, "iterations": [_iteration(10, "a")]}
    assert zen_bench.analyze_scenario(short, 100, 100)["status"] == "FAILED"

    skipped = {"kind": "paging", "status": "UNSUPPORTED", "reason": "one page", "iterations": {}}
    assert zen_bench.analyze_scenario(skipped, 100, 100)["status"] == "UNSUPPORTED"


def test_write_targets_narrows_paging_root_only_when_needed(tmp_path: Path) -> None:
    library = tmp_path / "lib"
    for name in ("a", "b", "c"):
        (library / "Fiction" / f"{name}.epub").parent.mkdir(parents=True, exist_ok=True)
        (library / "Fiction" / f"{name}.epub").write_bytes(b"x" * (ord(name)))
    (library / "Other" / "d.epub").parent.mkdir(parents=True)
    (library / "Other" / "d.epub").write_bytes(b"x")
    targets = zen_bench.write_targets(library, tmp_path / "targets.json")
    assert targets["paging_root"] == str(library / "Fiction")
    assert targets["root_book_count"] == 0
    assert set(targets["folders"]) == {str(library / "Fiction"), str(library / "Other")}
    assert json.loads((tmp_path / "targets.json").read_text()) == targets


def test_corpus_is_deterministic_and_cached(tmp_path: Path) -> None:
    first = zen_bench.build_corpus("hierarchical_6", tmp_path / "one")
    second = zen_bench.build_corpus("hierarchical_6", tmp_path / "two")
    names = sorted(path.relative_to(first) for path in first.rglob("*.epub"))
    assert len(names) == 6
    assert names == sorted(path.relative_to(second) for path in second.rglob("*.epub"))
    assert all((first / name).read_bytes() == (second / name).read_bytes() for name in names)
    with pytest.raises(ValueError):
        zen_bench.build_corpus("nested_5", tmp_path)


def test_report_renders_with_baseline(tmp_path: Path) -> None:
    run = {
        "run_status": "PASS", "screen": {"w": 100, "h": 100}, "process": {"spawn_to_ui_ready_ms": 300.0},
        "iterations": {"warmup": 2, "measured": 10}, "paging_root": None,
        "memory": {"post_init_idle": {"forced_gc_live_heap_mib": 20.0, "rss_peak_mib": 200.0}},
        "scenarios": {"library_first_render": zen_bench.analyze_scenario(
            {"kind": "repeated", "iterations": [_iteration(20)]}, 100, 100)},
    }
    results = {"environment": {"zenos_commit": "abc"}, "corpora": {"flat_50": run}}
    baseline = tmp_path / "baseline.json"
    baseline.write_text(json.dumps(results))
    report = zen_bench.write_report(results, tmp_path / "out", baseline).read_text()
    assert "| library_first_render | 20.0 (20.0–20.0) +0.0% |" in report
    assert "20.0 / 200" in report


def test_regressions_respect_tolerances() -> None:
    def run(wall: float, heap: float) -> dict:
        scenario = {"wall_time_ms": {"median": wall}}
        return {"scenarios": {"close_book": scenario},
                "memory": {"post_stress_idle": {"forced_gc_live_heap_mib": heap}}}

    baseline = {"corpora": {"flat_50": run(40.0, 20.0)},
                "startup": {"restart": {"spawn_to_ui_ready_ms": {"median": 500.0}}}}
    steady = {"corpora": {"flat_50": run(48.0, 21.0)},
              "startup": {"restart": {"spawn_to_ui_ready_ms": {"median": 560.0}}}}
    assert zen_bench.regressions(steady, baseline) == []
    worse = {"corpora": {"flat_50": run(60.0, 23.0)},
             "startup": {"restart": {"spawn_to_ui_ready_ms": {"median": 700.0}}}}
    assert [problem.split(":")[0] for problem in zen_bench.regressions(worse, baseline)] == [
        "flat_50/close_book wall ms", "flat_50 post-stress heap MiB", "restart spawn_to_ui_ready_ms"]
