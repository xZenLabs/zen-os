"""ZenOS emulator benchmarks: corpus, orchestration, analysis and report.

Scenarios and metrics follow https://github.com/d1-m4ss/kindle_benchmark (SCENARIOS.md);
the in-process harness is zen_ui_test_driver.koplugin/zen_bench.lua.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import queue
import random
import statistics
import subprocess
import sys
import threading
import time
import zipfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from zen_driver import launch, stop

SPEC_DIR = Path(__file__).parents[1]
CORPUS_CACHE = SPEC_DIR / ".cache" / "bench-corpus"
ARTIFACTS = SPEC_DIR / ".artifacts" / "benchmark"
CORPUS_VERSION = 1
SEED = 42
FIXTURE_TIME = 1_704_067_200
PAGING_MIN_ROOT_BOOKS = 403  # 30 transitions at the coarsest 14-per-page layout
MARKERS = ("BENCHMARK_UI_READY", "BENCHMARK_LIBRARY_READY", "BENCHMARK_COMPLETE", "BENCHMARK_FAILED")

AUTHORS = ["Ada Lovelace", "Alan Turing", "Grace Hopper", "Claude Shannon", "Donald Knuth",
           "Barbara Liskov", "Edsger Dijkstra", "Leslie Lamport", "Ursula Vance", "Isaac Moreau",
           "Octavia Reyes", "Frank Holt", "Ted Okafor", "Iain Brandt", "Vernor Quist", "Dan Ferro"]
GENRES = ["Fiction/SciFi", "Fiction/Classics", "Fiction/Mystery", "Fiction/Fantasy",
          "Nonfiction/Science", "Nonfiction/Mathematics", "Nonfiction/Philosophy", "Nonfiction/History"]
SERIES = ["Foundation Cycle", "Desert Chronicles", "Sprawl Trilogy", "Culture Saga",
          "Hollow Cantos", "Revelation Arc", "Remembrance", "The Expanse Road"]
ADJECTIVES = ["Ancient", "Silent", "Infinite", "Neural", "Digital", "Forgotten", "Synthetic",
              "Parallel", "Abstract", "Luminous", "Dark", "Deep"]
NOUNS = ["Star", "Galaxy", "Protocol", "Algorithm", "Empire", "Void", "Matrix", "Cipher",
         "Horizon", "Vector", "Engine", "Network", "Memory", "Shadow", "Circuit"]

SCENARIOS = (
    "start_to_home", "home_to_library", "library_first_render",
    "library_sequential_paging", "library_cached_paging",
    "library_folder_enter", "library_folder_back", "change_sort_mode",
    "open_book_minimal", "open_book", "reader_page_turn", "close_book",
    "open_quick_settings", "close_quick_settings", "repeated_nav",
)
METRICS = (
    "wall_time_ms", "first_content_paint_ms", "action_cpu_ms", "lua_heap_delta_kb",
    "natural_lua_heap_kb", "rss_peak_kib", "set_dirty_calls", "refresh_count",
    "full_refreshes", "partial_refreshes", "unique_dirty_pct",
    "cumulative_dirty_screen_equivalents", "largest_single_dirty_pct",
    "actual_refresh_count", "actual_unique_dirty_pct",
)


# Corpus ----------------------------------------------------------------------

def _cover(title: str, author: str) -> bytes:
    from PIL import Image, ImageDraw

    digest = int(hashlib.md5(f"{title}:{author}".encode()).hexdigest(), 16)
    image = Image.new("L", (600, 800), 200 + digest % 45)
    draw = ImageDraw.Draw(image)
    draw.rectangle([20, 20, 580, 780], outline=30, width=4)
    draw.rectangle([40, 50, 560, 90], fill=40)
    shape = [150, 160, 450, 460]
    (draw.ellipse if digest % 2 else draw.rectangle)(shape, outline=50, width=3)
    draw.text((60, 600), title, fill=20)
    draw.text((60, 640), author, fill=60)
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=80)
    return buffer.getvalue()


def _epub(path: Path, title: str, author: str, series: str | None, index: int | None) -> None:
    series_meta = (f'<meta name="calibre:series" content="{series}"/>'
                   f'<meta name="calibre:series_index" content="{index}"/>') if series else ""
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="2.0">
 <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
  <dc:title>{title}</dc:title><dc:creator opf:role="aut">{author}</dc:creator>
  <dc:identifier id="id">zen-bench-{hashlib.sha1(title.encode()).hexdigest()}</dc:identifier>
  <dc:language>en</dc:language><meta name="cover" content="cover-image"/>{series_meta}
 </metadata>
 <manifest>
  <item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>
  <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
  <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
 </manifest>
 <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>"""
    paragraph = ("<p>Dirty rectangles merged, partial refreshes pulsed and the page turned with "
                 "relentless consistency while the benchmark recorded every frame it painted.</p>")

    def chapter(heading: str, paragraphs: int) -> bytes:
        return (f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{heading}</title></head>'
                f"<body><h2>{heading}</h2>{paragraph * paragraphs}</body></html>").encode()

    members = {
        "META-INF/container.xml": b'<?xml version="1.0"?><container version="1.0" '
            b'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
            b'<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
            b"</rootfiles></container>",
        "OEBPS/content.opf": opf.encode(),
        "OEBPS/cover.jpg": _cover(title, author),
        "OEBPS/c1.xhtml": chapter(title, 3),
        # Long enough for the pinned reader_page_turn scenario (11+ pages).
        "OEBPS/c2.xhtml": chapter("The Architecture of Speed", 160),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype", (2024, 1, 1, 0, 0, 0)), "application/epub+zip")
        for name, body in members.items():
            info = zipfile.ZipInfo(name, (2024, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, body)
    os.utime(path, (FIXTURE_TIME, FIXTURE_TIME))


def build_corpus(corpus: str, cache: Path = CORPUS_CACHE) -> Path:
    """Return a cached deterministic `flat_N` or `hierarchical_N` library."""
    shape, count = corpus.rsplit("_", 1)
    if shape not in ("flat", "hierarchical"):
        raise ValueError(f"unknown corpus shape: {corpus}")
    root = cache / f"v{CORPUS_VERSION}" / corpus
    stamp = root / ".complete"
    if stamp.exists():
        return root
    rng = random.Random(SEED + int(count))
    series_index = dict.fromkeys(SERIES, 1)
    for number in range(1, int(count) + 1):
        author, title = rng.choice(AUTHORS), f"{rng.choice(ADJECTIVES)} {rng.choice(NOUNS)} {number:04d}"
        series = rng.choice(SERIES) if rng.random() < 0.4 else None
        index = series_index[series] if series else None
        if series:
            series_index[series] += 1
        folder = "" if shape == "flat" else (f"Series/{series}" if series else rng.choice(GENRES))
        _epub(root / folder / f"{author} - {title}.epub", title, author, series, index)
    stamp.touch()
    return root


def write_targets(library: Path, output: Path, limit: int = 10) -> dict:
    """Deterministic books/folders/paging root/reader book, as the upstream harness picks them."""
    def rank(path: Path) -> bytes:
        return hashlib.sha256(f"{SEED}:{path.relative_to(library)}".encode()).digest()

    books = sorted(library.rglob("*.epub"))
    folders = sorted(path for path in library.rglob("*") if path.is_dir()
                     and not any(part.startswith(".") for part in path.relative_to(library).parts))
    leaves: dict[Path, int] = {}
    for book in books:
        leaves[book.parent] = leaves.get(book.parent, 0) + 1
    targets: dict[str, object] = {
        "seed": SEED,
        "books": [str(path) for path in sorted(books, key=rank)[:limit]],
        "folders": [str(path) for path in sorted(folders, key=rank)[:limit]],
        "root_book_count": leaves.get(library, 0),
        "library_book_count": len(books),
    }
    candidates = {path: n for path, n in leaves.items() if path != library}
    if targets["root_book_count"] < PAGING_MIN_ROOT_BOOKS and candidates:
        leaf = max(candidates, key=lambda path: (candidates[path], rank(path)))
        targets.update(paging_root=str(leaf), paging_root_book_count=candidates[leaf])
    if books:
        sized = sorted((path.stat().st_size, path) for path in books)
        median = sized[len(sized) // 2][0]
        targets["reader_book"] = str(min(sized, key=lambda item: (abs(item[0] - median), rank(item[1])))[1])
    output.write_text(json.dumps(targets), encoding="utf-8")
    return targets


# Orchestration -----------------------------------------------------------------

def _screen_env() -> dict[str, str]:
    # Cocoa renders a 2x Retina target from a half-size window.
    retina = sys.platform == "darwin" and os.environ.get("SDL_VIDEODRIVER") != "dummy"
    width, height = ("618", "824") if retina else ("1236", "1648")
    return {"EMULATE_READER_W": width, "EMULATE_READER_H": height,
            "EMULATE_READER_DPI": "300", "EMULATE_BW_SCREEN": "1"}


def prepare_home(ko_home: Path, library: Path, variant: str = "zenos") -> None:
    settings = ko_home / "settings" / "ZenOS"
    settings.mkdir(parents=True, exist_ok=True)
    path = json.dumps(str(library.resolve()))
    # Sidecars live in KO_HOME so the cached corpus is never mutated.
    disabled = ', ["plugins_disabled"] = { zenos = true, zen_ui = true }' if variant == "stock" else ""
    (ko_home / "settings.reader.lua").write_text(
        f'return {{ ["home_dir"] = {path}, ["lastdir"] = {path}, '
        f'["document_metadata_folder"] = "dir"{disabled} }}\n', encoding="utf-8")
    (settings / "config.lua").write_text(
        "return { updater = { update_auto_check = false } }\n", encoding="utf-8")


def run_process(runtime: Path, ko_home: Path, library: Path, targets: Path, profile: str,
                output: Path, log: Path, timeout: float = 300) -> dict:
    """Launch one emulator process and return its raw result with spawn-relative markers."""
    env = {
        **_screen_env(),
        "ZEN_UI_BENCH": "1",
        "ZEN_UI_BENCH_PROFILE": profile,
        "ZEN_UI_BENCH_LIBRARY": str(library.resolve()),
        "ZEN_UI_BENCH_TARGETS": str(targets),
        "ZEN_UI_BENCH_OUTPUT": str(output),
    }
    output.unlink(missing_ok=True)
    if os.environ.get("ZEN_UI_BENCH_JITP"):
        patch = ko_home / "patches" / "1-zen-bench-profiler.lua"
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_bytes((runtime / "plugins" / "zen_ui_test_driver.koplugin" / "zen_bench_profiler.lua").read_bytes())
    started = time.monotonic_ns()
    process = launch(runtime, ko_home, ko_home / "bench.sock", env_overrides=env,
                     initialize_settings=False, capture_output=True)
    lines: queue.Queue[str | None] = queue.Queue()

    def pump() -> None:
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    threading.Thread(target=pump, daemon=True).start()
    markers: dict[str, float] = {}
    deadline = time.monotonic() + timeout
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as sink:
        while time.monotonic() < deadline:
            try:
                line = lines.get(timeout=0.25)
            except queue.Empty:
                continue
            if line is None:
                break
            sink.write(line)
            name = line.strip()[1:-1]
            if name in MARKERS:
                markers[name.lower()] = (time.monotonic_ns() - started) / 1e6
        else:
            stop(process)
            raise TimeoutError(f"benchmark process exceeded {timeout}s; log: {log}")
    returncode = process.wait(timeout=30)
    if not output.exists():
        raise RuntimeError(f"benchmark wrote no result (exit {returncode}); log: {log}")
    data = json.loads(output.read_text(encoding="utf-8"))
    data["process"] = {
        "returncode": returncode,
        "spawn_to_ui_ready_ms": markers.get("benchmark_ui_ready"),
        "spawn_to_library_ready_ms": markers.get("benchmark_library_ready"),
        "spawn_to_complete_ms": markers.get("benchmark_complete"),
        "clock": "python time.monotonic_ns",
    }
    return data


# Analysis ----------------------------------------------------------------------

def stats(values: list[float]) -> dict[str, float] | None:
    if not values:
        return None
    ordered = sorted(values)

    def percentile(fraction: float) -> float:
        return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]

    return {
        "count": len(ordered), "mean": statistics.fmean(ordered), "median": statistics.median(ordered),
        "min": ordered[0], "max": ordered[-1], "p10": percentile(0.10), "p90": percentile(0.90),
        "stdev": statistics.stdev(ordered) if len(ordered) > 1 else 0.0,
    }


def rect_union(rects: list, width: int, height: int) -> tuple[int, int, int]:
    """Return (union, cumulative, largest) pixel areas of screen-clipped rectangles."""
    clipped = []
    for rect in rects:
        x, y, w, h = (int(value or 0) for value in rect[:4])
        x1, y1 = max(0, min(width, x)), max(0, min(height, y))
        x2, y2 = max(0, min(width, x + max(0, w))), max(0, min(height, y + max(0, h)))
        if x2 > x1 and y2 > y1:
            clipped.append((x1, y1, x2, y2))
    areas = [(x2 - x1) * (y2 - y1) for x1, y1, x2, y2 in clipped]
    xs = sorted({x for x1, _y1, x2, _y2 in clipped for x in (x1, x2)})
    union = 0
    for left, right in zip(xs, xs[1:]):
        spans = sorted((y1, y2) for x1, y1, x2, y2 in clipped if x1 <= left and x2 >= right)
        covered, start, end = 0, None, None
        for y1, y2 in spans:
            if end is None or y1 > end:
                covered += (end - start) if end is not None else 0
                start, end = y1, y2
            else:
                end = max(end, y2)
        covered += (end - start) if end is not None else 0
        union += (right - left) * covered
    return union, sum(areas), max(areas, default=0)


def analyze_iteration(iteration: dict, width: int, height: int) -> dict:
    screen = width * height
    union, cumulative, largest = rect_union(iteration.get("refresh_requests") or [], width, height)
    actual = iteration.get("actual_refreshes") or []
    actual_union = rect_union(actual, width, height)[0]
    if union > cumulative or not 0 <= union <= screen:
        iteration.update(status="FAILED", reason="Dirty-region invariant violation")
    iteration.update(
        spatial_union_dirty_area_pixels=union,
        cumulative_dirty_area_pixels=cumulative,
        unique_dirty_pct=union / screen * 100,
        cumulative_dirty_screen_equivalents=cumulative / screen,
        largest_single_dirty_pct=largest / screen * 100,
        actual_refresh_count=len(actual),
        actual_unique_dirty_pct=actual_union / screen * 100,
    )
    return iteration


def analyze_scenario(entry: dict, width: int, height: int) -> dict:
    iterations = [analyze_iteration(it, width, height) for it in entry.get("iterations") or []]
    valid = [it for it in iterations if it.get("status") == "PASS"]
    out = {key: entry[key] for key in ("kind", "total_pages", "per_page", "requested_transitions")
           if key in entry}
    out.update(count=len(iterations), valid_count=len(valid))
    if entry.get("status"):
        out.update(status=entry["status"], reason=entry.get("reason"))
    elif not valid:
        first = iterations[0] if iterations else {}
        out.update(status=first.get("status", "FAILED"), reason=first.get("reason", "No iterations"))
    else:
        bad = next((it for it in iterations if it.get("status") != "PASS"), None)
        out.update(status="PASS", reason=bad and bad.get("reason"))
        if entry.get("kind") == "paging" and len(valid) != entry.get("requested_transitions"):
            out.update(status="FAILED", reason=out["reason"] or "Paging stopped before requested transitions")
        previous = None
        for index, it in enumerate(iterations, 1):
            frame = it.get("framebuffer_hash")
            if entry.get("kind") == "paging" and frame and frame == previous:
                out.update(status="FAILED", reason=f"Screen unchanged at transition {index} (identical framebuffer)")
                break
            previous = frame or previous
    for metric in METRICS:
        values = [it[metric] for it in valid if isinstance(it.get(metric), (int, float))]
        if values:
            out[metric] = stats(values)
    return out


def analyze_run(data: dict) -> dict:
    width, height = data["screen"]["w"], data["screen"]["h"]
    memory = {name: {"forced_gc_live_heap_mib": snap["forced_gc_live_heap_kb"] / 1024,
                     "rss_peak_mib": snap["rss_peak_kib"] / 1024}
              for name, snap in (data.get("memory_checkpoints") or {}).items()}
    return {
        "variant": data.get("variant"),
        "run_status": data.get("run_status"),
        "failure_reason": data.get("failure_reason"),
        "screen": data["screen"],
        "process": data.get("process", {}),
        "internal_harness_to_ui_ready_ms": data.get("internal_harness_to_ui_ready_ms"),
        "paging_root": data.get("paging_root"),
        "iterations": {"warmup": data.get("iterations_warmup"), "measured": data.get("iterations_measured")},
        "memory": memory,
        "scenarios": {name: analyze_scenario(entry, width, height)
                      for name, entry in (data.get("scenarios") or {}).items()},
    }


def summarize_startup(first_run: dict, restarts: list[dict]) -> dict:
    def series(key: str) -> dict | None:
        return stats([run["process"][key] for run in restarts if run["process"].get(key) is not None])

    def heap(run: dict) -> float | None:
        snap = run.get("memory", {}).get("post_library_render_idle")
        return snap and snap["forced_gc_live_heap_mib"]

    return {
        "first_run": {
            "spawn_to_ui_ready_ms": first_run["process"].get("spawn_to_ui_ready_ms"),
            "spawn_to_library_ready_ms": first_run["process"].get("spawn_to_library_ready_ms"),
            "post_library_render_heap_mib": heap(first_run),
        },
        "restart": {
            "spawn_to_ui_ready_ms": series("spawn_to_ui_ready_ms"),
            "spawn_to_library_ready_ms": series("spawn_to_library_ready_ms"),
            "post_library_render_heap_mib": stats([h for h in map(heap, restarts) if h is not None]),
        },
        "runs": len(restarts),
    }


def failures(results: dict) -> list[str]:
    problems = []
    for corpus, run in results.get("corpora", {}).items():
        if run.get("run_status") != "PASS":
            problems.append(f"{corpus}: run {run.get('run_status')}: {run.get('failure_reason')}")
        for name, scenario in run["scenarios"].items():
            if scenario["status"] == "FAILED":
                problems.append(f"{corpus}/{name}: {scenario.get('reason')}")
    return problems


def regressions(results: dict, baseline: dict, wall_pct: float = 0.25, heap_pct: float = 0.10,
                min_ms: float = 5.0) -> list[str]:
    """ZenOS medians that got slower or heavier than the baseline beyond noise tolerances."""
    problems = []

    def check(label: str, current: float | None, previous: float | None, pct: float, floor: float) -> None:
        if current is not None and previous and current > previous * (1 + pct) and current - previous > floor:
            problems.append(f"{label}: {previous:.1f} -> {current:.1f} (+{(current / previous - 1) * 100:.0f}%)")

    for corpus, run in results.get("corpora", {}).items():
        base = baseline.get("corpora", {}).get(corpus)
        if not base:
            continue
        for name, scenario in run["scenarios"].items():
            check(f"{corpus}/{name} wall ms", _median(scenario), _median(base["scenarios"].get(name)),
                  wall_pct, min_ms)
        heap = (run["memory"].get("post_stress_idle") or {}).get("forced_gc_live_heap_mib")
        base_heap = (base["memory"].get("post_stress_idle") or {}).get("forced_gc_live_heap_mib")
        check(f"{corpus} post-stress heap MiB", heap, base_heap, heap_pct, 0.5)
    for key in ("spawn_to_ui_ready_ms", "spawn_to_library_ready_ms"):
        check(f"restart {key}",
              ((results.get("startup") or {}).get("restart", {}).get(key) or {}).get("median"),
              ((baseline.get("startup") or {}).get("restart", {}).get(key) or {}).get("median"),
              wall_pct, min_ms)
    return problems


# Report ------------------------------------------------------------------------

MS, MIB, KIB, PCT, SCREENS = " ms", " MiB", " KiB", "%", "×"


def _fmt(value: float | None, unit: str = "", digits: int = 1, sign: bool = False) -> str:
    if value is None:
        return "—"
    if unit == MS and abs(value) >= 1000:
        value, unit, digits = value / 1000, " s", 2
    return f"{value:{'+' if sign else ''}.{digits}f}{unit}"


def _range(low: float | None, high: float | None, unit: str = MS, digits: int = 1) -> str:
    """`7.2–8.6 ms`; the unit repeats only when the ends differ (ms vs s)."""
    if low is None or high is None:
        return "—"
    start, end = _fmt(low, unit, digits), _fmt(high, unit, digits)
    number, _sep, suffix = start.rpartition(" ")
    return f"{number}–{end}" if number and end.endswith(f" {suffix}") else f"{start}–{end}"


def _median(scenario: dict | None, metric: str = "wall_time_ms") -> float | None:
    block = scenario and scenario.get(metric)
    return block and block["median"]


def _delta(current: float | None, previous: float | None) -> str:
    if current is None or previous is None or previous == 0:
        return "—"
    return f"{(current - previous) / previous * 100:+.1f}%"


def _diff(zen: float | None, stock: float | None, unit: str = MS) -> str:
    return "—" if zen is None or stock is None else _fmt(zen - stock, unit, sign=True)


def _stock_section(results: dict, stock: dict) -> list[str]:
    lines = ["## ZenOS vs stock KOReader (median; ZenOS / stock, Δ = ZenOS − stock, + is slower/larger)", ""]
    zen_startup, stock_startup = results.get("startup") or {}, stock.get("startup") or {}
    if zen_startup and stock_startup:
        lines += ["| Startup | ZenOS | Stock | Δ |", "|---|---:|---:|---:|"]
        for label, key, unit in (("Restart → first screen", "spawn_to_ui_ready_ms", MS),
                                 ("Restart → library", "spawn_to_library_ready_ms", MS),
                                 ("Heap after library render", "post_library_render_heap_mib", MIB)):
            zen = (zen_startup["restart"].get(key) or {}).get("median")
            base = (stock_startup["restart"].get(key) or {}).get("median")
            lines.append(f"| {label} | {_fmt(zen, unit)} | {_fmt(base, unit)} | {_diff(zen, base, unit)} |")
        lines.append("")
    names = [name for name in results.get("corpora", {}) if name in stock.get("corpora", {})]
    if names:
        lines += ["| Scenario | " + " | ".join(names) + " |", "|---|" + "---:|" * len(names)]
        for scenario in SCENARIOS:
            cells = []
            for corpus in names:
                zen = _median(results["corpora"][corpus]["scenarios"].get(scenario))
                base = _median(stock["corpora"][corpus]["scenarios"].get(scenario))
                cells.append("—" if zen is None and base is None
                             else f"{_fmt(zen, MS)} / {_fmt(base, MS)} ({_diff(zen, base)})")
            lines.append(f"| {scenario} | " + " | ".join(cells) + " |")
        lines.append("")
        lines += ["| Heap post_stress_idle | " + " | ".join(names) + " |", "|---|" + "---:|" * len(names)]
        cells = []
        for corpus in names:
            zen, base = (run["memory"].get("post_stress_idle", {}).get("forced_gc_live_heap_mib")
                         for run in (results["corpora"][corpus], stock["corpora"][corpus]))
            cells.append(f"{_fmt(zen, MIB)} / {_fmt(base, MIB)} ({_diff(zen, base, MIB)})")
        lines += ["| ZenOS / stock | " + " | ".join(cells) + " |", ""]
    return lines


def render_report(results: dict, baseline: dict | None = None) -> str:
    env = results["environment"]
    corpora = results.get("corpora", {})
    lines = [
        "# ZenOS benchmark report", "",
        "| | |", "|---|---|",
        *(f"| {key} | {value} |" for key, value in env.items()), "",
    ]
    if baseline:
        lines += [f"Baseline: `{baseline['environment'].get('zenos_commit', '?')}` "
                  f"({baseline['environment'].get('generated', '?')})", ""]

    startup = results.get("startup")
    if startup:
        base = (baseline or {}).get("startup") or {}
        rows = (("Spawn → first screen (UI ready)", "spawn_to_ui_ready_ms", MS),
                ("Spawn → library ready (restart + navigation)", "spawn_to_library_ready_ms", MS),
                ("Live Lua heap after library render", "post_library_render_heap_mib", MIB))
        lines += [f"## Startup ({startup['corpus']}, {startup['runs']} restarts)", "",
                  "| Metric | First run (cold) | Restart median | Restart min–max |"
                  + (" Δ vs baseline |" if baseline else ""),
                  "|---|---:|---:|---:|" + ("---:|" if baseline else "")]
        for label, key, unit in rows:
            restart = startup["restart"].get(key) or {}
            prior = ((base.get("restart") or {}).get(key) or {}).get("median")
            lines.append(f"| {label} | {_fmt(startup['first_run'].get(key), unit)} | "
                         f"{_fmt(restart.get('median'), unit)} | "
                         f"{_range(restart.get('min'), restart.get('max'), unit)} |"
                         + (f" {_delta(restart.get('median'), prior)} |" if baseline else ""))
        lines.append("")

    stock = results.get("stock") or {}
    if stock.get("corpora") or stock.get("startup"):
        lines += _stock_section(results, stock)
    if corpora:
        names = list(corpora)
        lines += ["## Scenario wall time (median, p10–p90)", "",
                  "| Scenario | " + " | ".join(names) + " |", "|---|" + "---:|" * len(names)]
        for scenario in SCENARIOS:
            cells = []
            for corpus in names:
                entry = corpora[corpus]["scenarios"].get(scenario)
                if not entry:
                    cells.append("—")
                elif entry["status"] != "PASS":
                    cells.append(entry["status"])
                else:
                    wall = entry["wall_time_ms"]
                    cell = f"{_fmt(wall['median'], MS)} ({_range(wall['p10'], wall['p90'])})"
                    prior = (baseline or {}).get("corpora", {}).get(corpus, {}).get("scenarios", {})
                    if baseline:
                        cell += f" {_delta(wall['median'], _median(prior.get(scenario)))}"
                    cells.append(cell)
            lines.append(f"| {scenario} | " + " | ".join(cells) + " |")
        lines += ["", "## Memory checkpoints (forced-GC live Lua heap / RSS peak)", "",
                  "| Corpus | post_init_idle | post_library_render_idle | post_stress_idle |",
                  "|---|---:|---:|---:|"]
        for corpus, run in corpora.items():
            cells = [f"{_fmt(snap['forced_gc_live_heap_mib'], MIB)} / {_fmt(snap['rss_peak_mib'], MIB, 0)}"
                     if (snap := run["memory"].get(name)) else "—"
                     for name in ("post_init_idle", "post_library_render_idle", "post_stress_idle")]
            lines.append(f"| {corpus} | " + " | ".join(cells) + " |")
        lines.append("")
        for corpus, run in corpora.items():
            lines += [f"## {corpus}", "",
                      f"Run {run['run_status']}; screen {run['screen']['w']}×{run['screen']['h']}; "
                      f"{run['iterations']['warmup']} warm-ups + {run['iterations']['measured']} measured; "
                      f"spawn → UI ready {_fmt(run['process'].get('spawn_to_ui_ready_ms'), MS, 0)}"
                      + (f"; paging root `{Path(run['paging_root']).name}`" if run.get("paging_root") else ""),
                      "",
                      "| Scenario | Status | n | Wall median | min | p90 | First paint | Action CPU | "
                      "Refreshes | Unique dirty | Screen eq. | Actual unique | Heap Δ |",
                      "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
            ordered = sorted(run["scenarios"].items(),
                             key=lambda item: SCENARIOS.index(item[0]) if item[0] in SCENARIOS else len(SCENARIOS))
            for name, entry in ordered:
                wall = entry.get("wall_time_ms") or {}
                lines.append(" | ".join([
                    f"| {name}", entry["status"], f"{entry['valid_count']}/{entry['count']}",
                    _fmt(wall.get("median"), MS), _fmt(wall.get("min"), MS), _fmt(wall.get("p90"), MS),
                    _fmt(_median(entry, "first_content_paint_ms"), MS),
                    _fmt(_median(entry, "action_cpu_ms"), MS),
                    _fmt(_median(entry, "refresh_count"), digits=0),
                    _fmt(_median(entry, "unique_dirty_pct"), PCT),
                    _fmt(_median(entry, "cumulative_dirty_screen_equivalents"), SCREENS, 2),
                    _fmt(_median(entry, "actual_unique_dirty_pct"), PCT),
                    _fmt(_median(entry, "lua_heap_delta_kb"), KIB, 0),
                ]) + " |")
            lines.append("")
    notes = [f"- {corpus}/{name}: {entry['status']} — {entry.get('reason')}"
             for corpus, run in corpora.items() for name, entry in run["scenarios"].items()
             if entry["status"] != "PASS" or entry.get("reason")]
    if notes:
        lines += ["## Failures and unsupported scenarios", "", *notes, ""]
    return "\n".join(lines)


def environment(runtime: Path) -> dict[str, str]:
    def git(*args: str) -> str:
        result = subprocess.run(["git", *args], cwd=SPEC_DIR, capture_output=True, text=True)
        return result.stdout.strip() or "?"

    rev = runtime / "git-rev"
    return {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "zenos_commit": git("rev-parse", "--short", "HEAD") + (" (dirty)" if git("status", "--porcelain") != "?" else ""),
        "koreader": rev.read_text().strip() if rev.exists() else "?",
        "host": f"{sys.platform} {os.uname().machine}",
        "corpus_version": str(CORPUS_VERSION),
    }


def write_report(results: dict, out_dir: Path = ARTIFACTS, baseline_path: Path | None = None) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    baseline = json.loads(baseline_path.read_text()) if baseline_path and baseline_path.exists() else None
    (out_dir / "results.json").write_text(json.dumps(results, indent=1), encoding="utf-8")
    report = out_dir / "REPORT.md"
    report.write_text(render_report(results, baseline), encoding="utf-8")
    return report


def profile_summary(folded: Path, top: int = 25) -> str:
    """Self and inclusive sample counts per frame from a ZEN_UI_BENCH_JITP folded-stack file."""
    inclusive: Counter[str] = Counter()
    leaf: Counter[str] = Counter()
    total = 0
    for line in folded.read_text().splitlines():
        stack, _sep, samples = line.rpartition(" ")
        frames = [frame.split("koreader/", 1)[-1] for frame in stack.split(";")]
        total += int(samples)
        leaf[frames[-1]] += int(samples)
        for frame in set(frames):
            inclusive[frame] += int(samples)
    lines = [f"{total} samples (1 ms)", "", "inclusive  self  frame"]
    for frame, count in inclusive.most_common(top):
        lines.append(f"{count / total:9.1%} {leaf[frame] / total:5.1%}  {frame}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Re-render a report, or summarize a profile")
    parser.add_argument("results", type=Path, help="results.json, or a .folded profile")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path, default=ARTIFACTS)
    parser.add_argument("--top", type=int, default=25)
    args = parser.parse_args()
    if args.results.suffix == ".folded":
        print(profile_summary(args.results, args.top))
    else:
        print(write_report(json.loads(args.results.read_text()), args.output, args.baseline))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
