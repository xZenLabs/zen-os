"""Emulator benchmarks; run with ./spec/run bench. Writes spec/.artifacts/benchmark/REPORT.md."""

import json
import os
import tempfile
from pathlib import Path

import pytest

import zen_bench

pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_BENCHMARK") != "1" or not os.environ.get("KOREADER_DIR"),
    reason="set ZEN_UI_RUN_BENCHMARK=1 (./spec/run bench) to run emulator benchmarks",
)

CORPORA = [name for name in os.environ.get(
    "ZEN_UI_BENCH_CORPORA", "flat_50,flat_2000,hierarchical_50,hierarchical_2000").split(",") if name]
STARTUP_CORPUS = os.environ.get("ZEN_UI_BENCH_STARTUP_CORPUS", CORPORA[-1])
RESTARTS = int(os.environ.get("ZEN_UI_BENCH_RESTARTS", "3"))
VARIANTS = [name for name in os.environ.get("ZEN_UI_BENCH_VARIANTS", "zenos,stock").split(",") if name]


def _bucket(results: dict, variant: str) -> dict:
    return results if variant == "zenos" else results.setdefault(variant, {"corpora": {}})


@pytest.fixture(scope="module")
def session():
    runtime = Path(os.environ["KOREADER_DIR"])
    results = {"environment": zen_bench.environment(runtime), "corpora": {}}
    yield runtime, results
    baseline = os.environ.get("ZEN_UI_BENCH_BASELINE")
    report = zen_bench.write_report(results, baseline_path=Path(baseline) if baseline else None)
    print(f"\nBenchmark report: {report}")


def _run(runtime: Path, home: Path, library: Path, profile: str, label: str) -> dict:
    targets = home / "targets.json"
    if not targets.exists():
        zen_bench.write_targets(library, targets)
    raw = zen_bench.ARTIFACTS / "raw" / f"{label}.json"
    raw.parent.mkdir(parents=True, exist_ok=True)
    data = zen_bench.run_process(runtime, home, library, targets, profile,
                                 raw, zen_bench.ARTIFACTS / "logs" / f"{label}.log")
    return zen_bench.analyze_run(data)


@pytest.mark.parametrize("variant", VARIANTS)
@pytest.mark.parametrize("corpus", CORPORA)
def test_warm_scenarios(session, corpus: str, variant: str) -> None:
    runtime, results = session
    library = zen_bench.build_corpus(corpus)
    with tempfile.TemporaryDirectory(prefix="zen-bench-home-") as home:
        zen_bench.prepare_home(Path(home), library, variant)
        run = _run(runtime, Path(home), library, "warm", f"{variant}_warm_{corpus}")
    assert run["variant"] == variant
    _bucket(results, variant)["corpora"][corpus] = run
    problems = zen_bench.failures({"corpora": {corpus: run}})
    assert not problems, "\n".join(problems)
    assert run["process"]["spawn_to_ui_ready_ms"] is not None


@pytest.mark.skipif(RESTARTS < 1, reason="ZEN_UI_BENCH_RESTARTS=0")
@pytest.mark.parametrize("variant", VARIANTS)
def test_restart(session, variant: str) -> None:
    """First run builds caches; restarts reuse the home (upstream steady_state_cold)."""
    runtime, results = session
    library = zen_bench.build_corpus(STARTUP_CORPUS)
    with tempfile.TemporaryDirectory(prefix="zen-bench-home-") as home:
        zen_bench.prepare_home(Path(home), library, variant)
        first = _run(runtime, Path(home), library, "startup", f"{variant}_startup_first_run")
        restarts = [_run(runtime, Path(home), library, "startup", f"{variant}_startup_restart_{index}")
                    for index in range(1, RESTARTS + 1)]
    _bucket(results, variant)["startup"] = {"corpus": STARTUP_CORPUS, **zen_bench.summarize_startup(first, restarts)}
    for run in (first, *restarts):
        assert run["run_status"] == "PASS", run.get("failure_reason")
        assert run["process"]["spawn_to_library_ready_ms"] is not None


@pytest.mark.skipif(not os.environ.get("ZEN_UI_BENCH_BASELINE"), reason="set ZEN_UI_BENCH_BASELINE to guard regressions")
def test_no_regressions(session) -> None:
    """Runs last: compares this session's ZenOS medians with the baseline results.json."""
    _runtime, results = session
    baseline = json.loads(Path(os.environ["ZEN_UI_BENCH_BASELINE"]).read_text())
    problems = zen_bench.regressions(results, baseline)
    assert not problems, "\n".join(problems)
