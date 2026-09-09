#!/usr/bin/env python3
"""Run matched ZenOS revisions through the external kindle_benchmark harness."""
import argparse
import hashlib
import json
import shutil
import sqlite3
import statistics
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("benchmark", "runtime", "before", "after", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--metadata-cache", type=Path,
        help="Fully extracted CoverBrowser DB for these EPUBs; measures indexed warm/restart runs")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(args.benchmark.resolve() / "scripts"))
    import run_benchmarks as bench

    bench.KOREADER_DIR = args.runtime.resolve()
    bench.ENV_BASE = output / "homes"
    bench.RUNS_ROOT = output / "results"
    layout = bench.make_layout("library-ab", "phase1")
    environment = bench.ensure_layout(layout)
    environment["zenos_ab"] = {
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "runtime_version": (bench.KOREADER_DIR / "git-rev").read_text().strip(),
        "metadata_cache_sha256": hashlib.sha256(args.metadata_cache.read_bytes()).hexdigest()
            if args.metadata_cache else None,
    }
    bench.atomic_json_write(layout.environment, environment)
    revisions = {}
    for variant in ("before", "after"):
        plugins = output / "plugins" / variant
        shutil.copytree(getattr(args, variant), plugins / "zenos", ignore=shutil.ignore_patterns(
            ".git", ".agents", ".codex", ".luarocks", ".venv", ".env*", "spec", "dist", "__pycache__"))
        (plugins / "benchmark").symlink_to(args.benchmark.resolve() / "plugins_source/benchmark")
        digest = hashlib.sha256()
        for path in sorted((plugins / "zenos").rglob("*.lua")):
            digest.update(str(path.relative_to(plugins / "zenos")).encode())
            digest.update(b"\0" + path.read_bytes() + b"\0")
        revisions[variant] = digest.hexdigest()
    (output / "revisions.json").write_text(json.dumps(revisions, indent=2) + "\n")

    rows = []
    for shape in ("flat", "hierarchical"):
        source = args.benchmark.resolve() / f"libraries/{shape}/books_2000"
        books = sorted(source.rglob("*.epub"))
        assert len(books) == 2000, f"Expected 2000 synthetic EPUBs in {source}"
        for repetition in range(1, args.runs + 1):
            variants = ("before", "after") if repetition % 2 else ("after", "before")
            for variant in variants:
                bench.PLUGINS_SRC = output / "plugins" / variant
                sample = f"{shape}_{repetition}_{variant}"
                library = output / "libraries" / sample
                # Copy only the corpus; each sample creates its own sidecars and caches.
                for book in books:
                    target = library / book.relative_to(source)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(book, target)
                for directory in sorted((p for p in library.rglob("*") if p.is_dir()), reverse=True):
                    shutil.copystat(source / directory.relative_to(library), directory)
                shutil.copystat(source, library)
                home = bench.ENV_BASE / sample
                config = home / "settings/ZenOS/config.lua"
                config.parent.mkdir(parents=True)
                (home / "settings.reader.lua").write_text(
                    "return { home_dir = " + json.dumps(str(library), ensure_ascii=False) + " }\n")
                config.write_text('return { _meta = { quickstart_shown_for_version = '
                    '"pre-quickstart", quickstart_completed = true }, '
                    'updater = { update_auto_check = false } }\n')
                if args.metadata_cache:
                    database = home / "settings/bookinfo_cache.sqlite3"
                    shutil.copy2(args.metadata_cache, database)
                    with sqlite3.connect(database) as connection:
                        connection.execute("DELETE FROM config")
                        for book in books:
                            directory = library / book.relative_to(source).parent
                            changed = connection.execute("UPDATE bookinfo SET directory=? WHERE filename=?",
                                (str(directory) + "/", book.name)).rowcount
                            assert changed == 1, f"Metadata missing or ambiguous for {book.name}"
                modes = ("warm", "steady_state_cold") if args.metadata_cache else (
                    "first_run_cold", "warm", "steady_state_cold")
                for mode in modes:
                    run_id = f"{sample}_{mode}"
                    job = bench.Job(
                        run_id=run_id, block="D_zenos", phase="phase1", config="D_zenos",
                        plugins=("zenos",), library_dir=str(library), ko_home=str(home),
                        mode=mode, profile="synthetic" if mode == "warm" else "startup",
                        dataset_mode=shape, book_count=2000, warmup=2, measure=10,
                        fresh_home=False, timeout_s=180,
                    )
                    result = bench.run_job(job, layout, environment, resume=False)
                    print(json.dumps(result), flush=True)
                    if result["status"] != "PASS":
                        raise RuntimeError(f"Benchmark failed; see {layout.logs / (run_id + '.log')}")
                    raw = layout.raw / f"{run_id}.json"
                    data = json.loads(raw.read_text())
                    metrics = {"spawn_to_ui_ms": data["external_process_timing"]["spawn_to_ui_ready_ms"],
                        "spawn_to_library_ms": data["external_process_timing"]["spawn_to_library_ready_ms"]}
                    for name, scenario in data["scenarios"].items():
                        if scenario["status"] == "PASS" and scenario.get("wall_time_ms"):
                            metrics[name + "_ms"] = scenario["wall_time_ms"]["median"]
                    for name, checkpoint in data["memory_checkpoints"].items():
                        for field in ("forced_gc_live_heap_kb", "natural_lua_heap_kb"):
                            metrics[name + "_" + field] = checkpoint[field]
                    renderings = []
                    for iteration in data["scenarios"]["library_first_render"]["iterations"]:
                        evidence = iteration["semantic_evidence"]
                        renderings.append(dict(items=evidence["items_loaded"],
                            visible=evidence["visible_signature"].replace(str(library) + "/", "")))
                    rows.append(dict(variant=variant, shape=shape, repetition=repetition, mode=mode,
                        indexed=bool(args.metadata_cache), renderings=renderings,
                        metrics=metrics, statuses={k: v["status"] for k, v in data["scenarios"].items()},
                        raw=str(raw.relative_to(output)), sha256=hashlib.sha256(raw.read_bytes()).hexdigest()))
                    (output / "samples.json").write_text(json.dumps(rows, indent=2) + "\n")

    comparisons = []
    for shape in ("flat", "hierarchical"):
        for mode in ("first_run_cold", "warm", "steady_state_cold"):
            group = [r for r in rows if r["shape"] == shape and r["mode"] == mode]
            if not group:
                continue
            matched = all(
                next(r for r in group if r["repetition"] == n and r["variant"] == "before")["renderings"]
                == next(r for r in group if r["repetition"] == n and r["variant"] == "after")["renderings"]
                for n in range(1, args.runs + 1))
            for metric in sorted(set.intersection(*(set(r["metrics"]) for r in group))):
                values = {variant: [r["metrics"][metric] for r in group if r["variant"] == variant]
                    for variant in ("before", "after")}
                before, after = (statistics.median(values[v]) for v in ("before", "after"))
                comparisons.append(dict(shape=shape, mode=mode, metric=metric, before=before,
                    identical_library_renderings=matched,
                    after=after, reduction_pct=100 * (before - after) / before if before else None,
                    samples=values))
    (output / "comparison.json").write_text(json.dumps(comparisons, indent=2) + "\n")
    print(output / "comparison.json")


if __name__ == "__main__":
    main()
