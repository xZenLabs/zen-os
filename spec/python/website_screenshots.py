"""Generate deterministic ZenOS website screenshot review artifacts."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import posixpath
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Sequence
from xml.etree import ElementTree
from zipfile import BadZipFile, ZipFile

from PIL import Image

from zen_driver import ZenDriver, launch, wait_for_socket


REPO_ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = Path(__file__).with_name("website_screenshot_scenarios.json")
DEFAULT_PROFILE = REPO_ROOT / ".website-screenshot-books.json"
ARTIFACT_ROOT = REPO_ROOT / "spec" / ".artifacts" / "screenshots"
SHOWCASE_BACKGROUND = (
    REPO_ROOT / "spec" / "fixtures" / "beach.jpg"
)
SCREEN_SIZE = (1272, 1696)
BB_TYPE_RGB32 = 5
READER_SHOWCASE_PAGE = 10
READER_SHOWCASE_PRESET = "(ZenOS) L/C/R: Chapter Time | Page | %"
READER_FOOTER_PRESETS = {
    "default": READER_SHOWCASE_PRESET,
    "pages_bar_percent": "(ZenOS) Pages | Bar | %",
}
FIXED_LOCAL_TIME = datetime(2026, 6, 18, 10, 9, 0)
FORMAT_PREFERENCE = ("EPUB", "KEPUB", "AZW3", "MOBI")
GROUPS = frozenset(("home", "library", "menus", "reader"))
SESSIONS = frozenset(("general", "reader"))
EXPECTED_IDS = frozenset((
    "zen_home", "home_bookshelf", "home_simple",
    "library_covers_full", "library_list_full", "context_menu", "metadata_editor", "stats",
    "launcher", "quicksettings", "quickstart", "zen_settings",
    "launcher_add_plugin_menu", "launcher_add_koreader_menu",
    "controls_buttons_settings", "navbar_buttons_settings",
    "reader", "reader_launcher_book_switcher",
    "reader_launcher_book_details", "reader_book_details", "page_browser_grid",
    "page_browser_carousel", "reader_dict", "reader_highlight",
))
SHOWCASE_BOOK_COUNT = 12
SHOWCASE_PLACEHOLDER_COUNT = SHOWCASE_BOOK_COUNT
SHOWCASE_NAVBAR_STATES = {
    "default": {
        "tab_order": ["home"],
        "show_icons": True,
        "show_labels": False,
    },
    "library_home_icons": {
        "tab_order": ["books", "home"],
        "show_icons": True,
        "show_labels": False,
    },
    "regular": {
        "tab_order": ["books", "authors", "series", "stats", "to_be_read", "home"],
        "show_icons": True,
        "show_labels": True,
    },
    "zen_home_icons": {
        "tab_order": ["books", "authors", "series", "stats", "to_be_read", "home"],
        "show_icons": True,
        "show_labels": False,
    },
    "navbar_settings": {
        "tab_order": [
            "books", "home", "to_be_read", "authors", "tags", "ct_showcase_folder",
        ],
        "show_icons": True,
        "show_labels": False,
    },
    "library_home_text": {
        "tab_order": ["books", "home"],
        "show_icons": False,
        "show_labels": True,
    },
    "icons_only": {
        "tab_order": ["books", "authors", "series", "stats", "to_be_read", "home"],
        "show_icons": True,
        "show_labels": False,
    },
    "text_only": {
        "tab_order": ["books", "authors", "series", "stats", "to_be_read", "home"],
        "show_icons": False,
        "show_labels": True,
    },
    "few_items": {
        "tab_order": ["books", "stats", "home"],
        "show_icons": True,
        "show_labels": True,
    },
}
NON_EMULATOR_ASSETS = frozenset((
    "plugins_folder.png", "zen_update.svg", "banner.png", "social.png",
    "og-zen.png", "zenos-banner.png",
))
MANUAL_SCREENSHOT_ASSETS = frozenset(("opds.png", "opds_context.png"))
READER_BASELINE_SETTING_KEYS = (
    "alt_status_bar",
    "color_rendering",
    "cre_font",
    "footer",
    "page_overlap_style",
    "reader_footer_custom_text",
    "reader_footer_custom_text_repetitions",
    "reader_footer_mode",
    "rotation_mode",
    "view_mode",
)


@dataclass(frozen=True)
class Scenario:
    id: str
    group: str
    session: str
    action: str
    docs: tuple[str, ...]
    options: dict[str, object]

    @property
    def filename(self) -> str:
        return f"{self.id}.png"


@dataclass(frozen=True)
class BookRequest:
    calibre_id: int | None
    expected_title: str
    direct_path: str | None
    role: str
    keywords: str | None = None
    authors: str | None = None


@dataclass(frozen=True)
class ResolvedBook:
    calibre_id: int | None
    title: str
    authors: str
    series: str | None
    source: Path
    role: str
    format: str
    keywords: str | None = None


@dataclass(frozen=True)
class StagedBook:
    calibre_id: int | None
    title: str
    authors: str
    series: str | None
    source: Path
    path: Path
    role: str
    format: str
    keywords: str | None = None


class CaptureError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_files(paths: Sequence[Path]) -> dict[str, str]:
    return {
        str(path.resolve()): sha256_file(path)
        for path in sorted({path.resolve() for path in paths})
        if path.is_file()
    }


def snapshot_tree(root: Path | None) -> dict[str, str]:
    if root is None or not root.is_dir():
        return {}
    return snapshot_files([path for path in root.rglob("*") if path.is_file()])


def load_catalog(path: Path = CATALOG_PATH) -> list[Scenario]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError("scenario catalog must be a JSON list")
    scenarios: list[Scenario] = []
    for record in raw:
        if not isinstance(record, dict):
            raise ValueError("each scenario must be a JSON object")
        required = {"id", "group", "session", "action", "docs"}
        missing = required - record.keys()
        if missing:
            raise ValueError(f"scenario is missing fields: {sorted(missing)}")
        options = {key: value for key, value in record.items() if key not in required}
        scenarios.append(Scenario(
            id=str(record["id"]),
            group=str(record["group"]),
            session=str(record["session"]),
            action=str(record["action"]),
            docs=tuple(str(value) for value in record["docs"]),
            options=options,
        ))
    validate_catalog(scenarios)
    return scenarios


def validate_catalog(scenarios: Sequence[Scenario]) -> None:
    ids = [scenario.id for scenario in scenarios]
    if len(ids) != len(set(ids)):
        raise ValueError("scenario IDs must be unique")
    if set(ids) != EXPECTED_IDS or len(ids) != len(EXPECTED_IDS):
        missing = sorted(EXPECTED_IDS - set(ids))
        extra = sorted(set(ids) - EXPECTED_IDS)
        raise ValueError(
            f"catalog must contain the canonical {len(EXPECTED_IDS)} scenarios; "
            f"missing={missing}, extra={extra}"
        )
    for scenario in scenarios:
        if not re.fullmatch(r"[a-z][a-z0-9_]*", scenario.id):
            raise ValueError(f"invalid scenario ID: {scenario.id}")
        if scenario.group not in GROUPS:
            raise ValueError(f"invalid scenario group: {scenario.group}")
        if scenario.session not in SESSIONS:
            raise ValueError(f"invalid scenario session: {scenario.session}")
        navbar = scenario.options.get("navbar", "default")
        if navbar not in SHOWCASE_NAVBAR_STATES:
            raise ValueError(f"invalid navbar fixture for {scenario.id}: {navbar}")
        crop = scenario.options.get("crop")
        if crop is not None and (
            not isinstance(crop, dict)
            or crop.get("target") not in ("navbar", "panel_button")
        ):
            raise ValueError(f"invalid crop declaration for {scenario.id}")
    page_browser_ids = [value for value in ids if value.startswith("page_browser")]
    if page_browser_ids != ["page_browser_grid", "page_browser_carousel"]:
        raise ValueError("Page Browser scenarios must be grid then carousel")
    if "update_available" in ids:
        raise ValueError("update_available is intentionally outside the capture catalog")


def load_profile(path: Path) -> tuple[Path, list[BookRequest], str | None]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    calibre_root = Path(str(raw.get("calibre_root", "~/Calibre Library"))).expanduser()
    raw_quote = raw.get("quote")
    if raw_quote is not None and not isinstance(raw_quote, str):
        raise ValueError("book profile quote must be a string")
    quote = (raw_quote.strip() or None) if raw_quote is not None else None
    records = raw.get("books")
    if not isinstance(records, list) or not records:
        raise ValueError("book profile must contain a non-empty books list")
    books: list[BookRequest] = []
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("book profile entries must be objects")
        calibre_id = record.get("calibre_id")
        raw_keywords = record.get("keywords")
        if isinstance(raw_keywords, list):
            keywords = ", ".join(
                str(value).strip() for value in raw_keywords if str(value).strip()
            ) or None
        elif isinstance(raw_keywords, str):
            keywords = raw_keywords.strip() or None
        elif raw_keywords is None:
            keywords = None
        else:
            raise ValueError("book profile keywords must be a string or list")
        raw_authors = record.get("authors")
        if raw_authors is not None and not isinstance(raw_authors, str):
            raise ValueError("book profile authors must be a string")
        authors = (raw_authors.strip() or None) if raw_authors is not None else None
        books.append(BookRequest(
            calibre_id=int(calibre_id) if calibre_id is not None else None,
            expected_title=str(record.get("expected_title", "")).strip(),
            direct_path=str(record["direct_path"]) if record.get("direct_path") else None,
            role=str(record.get("role", "library")),
            keywords=keywords,
            authors=authors,
        ))
    if len(books) != SHOWCASE_BOOK_COUNT:
        raise ValueError(
            f"the showcase profile must resolve exactly {SHOWCASE_BOOK_COUNT} books, "
            f"found {len(books)}"
        )
    if sum(book.role == "featured" for book in books) != 1:
        raise ValueError("the showcase profile needs exactly one featured book")
    if sum(book.role == "reader" for book in books) != 1:
        raise ValueError("the showcase profile needs exactly one reader book")
    return calibre_root, books, quote


def _calibre_authors(connection: sqlite3.Connection, book_id: int) -> str:
    rows = connection.execute(
        """SELECT authors.name FROM authors
           JOIN books_authors_link ON books_authors_link.author = authors.id
           WHERE books_authors_link.book = ? ORDER BY books_authors_link.id""",
        (book_id,),
    ).fetchall()
    return " & ".join(str(row[0]) for row in rows) or "Unknown author"


def _calibre_series(connection: sqlite3.Connection, book_id: int) -> str | None:
    row = connection.execute(
        """SELECT series.name FROM series
           JOIN books_series_link ON books_series_link.series = series.id
           WHERE books_series_link.book = ? LIMIT 1""",
        (book_id,),
    ).fetchone()
    return str(row[0]) if row else None


def _calibre_keywords(connection: sqlite3.Connection, book_id: int) -> str | None:
    rows = connection.execute(
        """SELECT tags.name FROM tags
           JOIN books_tags_link ON books_tags_link.tag = tags.id
           WHERE books_tags_link.book = ? ORDER BY books_tags_link.id""",
        (book_id,),
    ).fetchall()
    return ", ".join(str(row[0]) for row in rows) or None


def resolve_calibre_books(calibre_root: Path, requests: Sequence[BookRequest]) -> list[ResolvedBook]:
    root = calibre_root.expanduser().resolve()
    database = root / "metadata.db"
    if not database.is_file():
        raise FileNotFoundError(f"Calibre metadata database not found: {database}")
    resolved: list[ResolvedBook] = []
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        for request in requests:
            title = request.expected_title
            authors = "Unknown author"
            series = None
            keywords = request.keywords
            selected_path: Path | None = None
            selected_format = ""
            if request.calibre_id is not None:
                book = connection.execute(
                    "SELECT title, path FROM books WHERE id = ?",
                    (request.calibre_id,),
                ).fetchone()
                if book is None:
                    raise ValueError(f"Calibre ID {request.calibre_id} does not exist")
                calibre_title, relative_dir = str(book[0]), str(book[1])
                if calibre_title.casefold() != title.casefold():
                    raise ValueError(
                        f"Calibre ID {request.calibre_id} title mismatch: "
                        f"expected {title!r}, found {calibre_title!r}"
                    )
                formats = {
                    str(fmt).upper(): str(name)
                    for fmt, name in connection.execute(
                        "SELECT format, name FROM data WHERE book = ?",
                        (request.calibre_id,),
                    )
                }
                for preferred in FORMAT_PREFERENCE:
                    if preferred in formats:
                        selected_format = preferred
                        selected_path = root / relative_dir / f"{formats[preferred]}.{preferred.lower()}"
                        break
                if selected_path is None:
                    raise ValueError(
                        f"Calibre ID {request.calibre_id} has none of {FORMAT_PREFERENCE}"
                    )
                authors = _calibre_authors(connection, request.calibre_id)
                series = _calibre_series(connection, request.calibre_id)
                keywords = keywords or _calibre_keywords(connection, request.calibre_id)
            if request.direct_path:
                direct_path = Path(request.direct_path).expanduser()
                if not direct_path.is_absolute():
                    direct_path = root / direct_path
                direct_path = direct_path.resolve()
                selected_path = direct_path
                selected_format = direct_path.suffix.lstrip(".").upper()
                if authors == "Unknown author" and " - " in direct_path.stem:
                    authors = direct_path.stem.rsplit(" - ", 1)[1]
                if keywords is None:
                    row = connection.execute(
                        "SELECT id FROM books WHERE title = ? COLLATE NOCASE LIMIT 1",
                        (title,),
                    ).fetchone()
                    if row is not None:
                        keywords = _calibre_keywords(connection, int(row[0]))
            if selected_path is None:
                raise ValueError(f"{title!r} needs calibre_id or direct_path")
            selected_path = selected_path.resolve()
            if not selected_path.is_file():
                raise FileNotFoundError(f"showcase book file not found: {selected_path}")
            if root not in selected_path.parents:
                raise ValueError(f"book path escapes the Calibre root: {selected_path}")
            keywords = keywords or _embedded_keywords(selected_path)
            authors = request.authors or authors
            resolved.append(ResolvedBook(
                calibre_id=request.calibre_id,
                title=title,
                authors=authors,
                series=series,
                source=selected_path,
                role=request.role,
                format=selected_format,
                keywords=keywords,
            ))
    return resolved


def stage_books(books: Sequence[ResolvedBook], destination: Path) -> list[StagedBook]:
    destination.mkdir(parents=True, exist_ok=True)
    staged: list[StagedBook] = []
    names: set[str] = set()
    newest_access = int(time.mktime(FIXED_LOCAL_TIME.timetuple()))
    for index, book in enumerate(books, start=1):
        safe_stem = re.sub(r"[^A-Za-z0-9 ._'()-]+", "", book.title).strip() or f"Book {index}"
        filename = f"{index:02d} {safe_stem}{book.source.suffix.lower()}"
        if filename.casefold() in names:
            raise ValueError(f"staged filename collision: {filename}")
        names.add(filename.casefold())
        target = destination / filename
        shutil.copyfile(book.source, target)
        os.utime(target, (newest_access - (index - 1) * 600, newest_access))
        staged.append(StagedBook(**asdict(book), path=target))
    staged_names = {book.path.name for book in staged}
    if {path.name for path in destination.iterdir()} != staged_names:
        raise CaptureError("staging produced files other than the selected book copies")
    return staged


def stage_placeholder_texts(destination: Path) -> None:
    newest_access = int(time.mktime(FIXED_LOCAL_TIME.timetuple()))
    for index in range(1, SHOWCASE_PLACEHOLDER_COUNT + 1):
        target = destination / f"{SHOWCASE_BOOK_COUNT + index:02d} Placeholder {index:02d}.txt"
        target.write_text("Placeholder for library pagination screenshots.\n", encoding="utf-8")
        timestamp = newest_access - (SHOWCASE_BOOK_COUNT + index - 1) * 600
        os.utime(target, (timestamp, timestamp))


def _lua(value: object, indent: int = 0) -> str:
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, (str, Path)):
        return json.dumps(str(value), ensure_ascii=False)
    if isinstance(value, (list, tuple)):
        if not value:
            return "{}"
        inner = ",\n".join(" " * (indent + 2) + _lua(item, indent + 2) for item in value)
        return "{\n" + inner + "\n" + " " * indent + "}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        rows = []
        for key, item in value.items():
            rows.append(" " * (indent + 2) + f"[{_lua(str(key))}] = {_lua(item, indent + 2)}")
        return "{\n" + ",\n".join(rows) + "\n" + " " * indent + "}"
    raise TypeError(f"cannot serialize {type(value).__name__} to Lua")


def _write_lua(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("return " + _lua(value) + "\n", encoding="utf-8")


def _lua_merge_override(value: object) -> object:
    if isinstance(value, dict):
        return {key: _lua_merge_override(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return {
            "__zen_replace": True,
            "value": [_lua_merge_override(item) for item in value],
        }
    return value


def _write_merged_lua(
    runtime: Path,
    baseline: Path,
    destination: Path,
    overrides: dict[str, object],
    baseline_keys: Sequence[str] | None = None,
    baseline_prefixes: Sequence[str] = (),
) -> None:
    if not baseline.is_file():
        _write_lua(destination, overrides)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    override_path = destination.with_name(f".{destination.name}.website-overrides.lua")
    merge_overrides = _lua_merge_override(overrides)
    if not isinstance(merge_overrides, dict):
        raise TypeError("Lua merge overrides must be a table")
    if baseline_keys is not None:
        merge_overrides["__zen_baseline_keys"] = list(baseline_keys)
        merge_overrides["__zen_baseline_prefixes"] = list(baseline_prefixes)
    _write_lua(override_path, merge_overrides)
    script = """
local base = assert(dofile(arg[0]))
local overrides = assert(dofile(arg[1]))
local baseline_keys = overrides.__zen_baseline_keys
local baseline_prefixes = overrides.__zen_baseline_prefixes
overrides.__zen_baseline_keys = nil
overrides.__zen_baseline_prefixes = nil
if type(baseline_keys) == "table" then
    local selected = {}
    for key_i, key in ipairs(baseline_keys) do
        selected[key] = base[key]
    end
    for key, value in pairs(base) do
        if type(key) == "string" then
            for prefix_i, prefix in ipairs(baseline_prefixes or {}) do
                if key:sub(1, #prefix) == prefix then selected[key] = value end
            end
        end
    end
    base = selected
end
local function merge(target, source)
    for key, value in pairs(source) do
        if type(value) == "table" and value.__zen_replace == true then
            target[key] = value.value
        elseif type(value) == "table" and type(target[key]) == "table" then
            merge(target[key], value)
        else
            target[key] = value
        end
    end
end
merge(base, overrides)
io.write("return ", require("dump")(base), "\\n")
"""
    environment = os.environ.copy()
    environment["LUA_PATH"] = "frontend/?.lua;;"
    try:
        completed = subprocess.run(
            [str(runtime / "luajit"), "-e", script, str(baseline), str(override_path)],
            cwd=runtime,
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        destination.write_text(completed.stdout, encoding="utf-8")
    except (OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        raise CaptureError(f"could not seed KOReader settings from {baseline}: {detail}") from error
    finally:
        override_path.unlink(missing_ok=True)


def _settings_baseline_files(runtime: Path) -> list[Path]:
    return [
        runtime / "settings.reader.lua",
        runtime / "settings" / "ZenOS" / "config.lua",
        runtime / "settings" / "ZenOS" / "reader.lua",
    ]


def _zen_config(background_path: Path = SHOWCASE_BACKGROUND) -> dict[str, object]:
    return {
        "_meta": {
            "quickstart_completed": True,
            "quickstart_shown_for_version": True,
            "quickstart_menu_tour_pending": False,
            # ReaderDefaults applies Hyperreadable SemiBold to both reader bars.
            "reader_defaults_apply_on_next_open": True,
        },
        "updater": {"update_auto_check": False, "update_available": False},
        "features": {
            "navbar": True,
            "quick_settings": True,
            "app_launcher": True,
            "zen_mode": True,
            "lockdown_mode": False,
            "status_bar": True,
            "page_browser": True,
            "highlight_lookup": True,
            "dict_quick_lookup": True,
            "zen_opds": True,
            "automatic_series_grouping": False,
        },
        "navbar": {
            "default_tab": "home",
            "show_icons": True,
            "show_labels": False,
            "show_tabs": {
                "books": True,
                "authors": True,
                "series": True,
                "home": True,
                "stats": True,
                "to_be_read": True,
            },
            "tab_order": ["home"],
        },
        "quick_settings": {
            "button_order": [
                "wifi", "night", "rotate", "zen", "lockdown", "incognito",
                "usb", "search", "restart", "exit", "sleep",
            ],
            "show_buttons": {
                "wifi": True,
                "bluetooth": False,
                "night": True,
                "frontlight": False,
                "gyro": False,
                "rotate": True,
                "zen": True,
                "lockdown": False,
                "incognito": False,
                "usb": False,
                "search": False,
                "quickrss": False,
                "cloud": False,
                "zlibrary": False,
                "calibre": False,
                "restart": True,
                "exit": False,
                "sleep": True,
                "notion": False,
                "streak": False,
                "opds": False,
                "tailscale": False,
                "zenfm": False,
                "filebrowser": False,
            },
            "show_labels": True,
            "show_frontlight": True,
            "show_warmth": True,
            "rotate_action": "90",
            "screenshot_timer_seconds": 3,
            "custom_buttons": [],
            "next_custom_id": 0,
            "layout_version": 2,
        },
        "status_bar": {
            "left_order": ["time"],
            "center_order": [],
            "right_order": ["wifi", "battery"],
            "time_12h": True,
            "hide_browser_bar": True,
        },
        "reader_top_status_bar": {
            "left_order": ["book_title"],
            "center_order": [],
            "right_order": ["chapter"],
            "show_bottom_border": False,
            "bottom_border_progress": False,
        },
        "opds": {"display_mode": "mosaic"},
        "browser_cover_badges": {
            "show_mosaic_progress": True,
            "show_native_progress_bar": False,
            "show_new_banner": True,
            "badge_size": "compact",
        },
        "browser_page_count": {"show_page_count": True},
        "mosaic_title_strip": {"show_title": False, "show_author": False},
        "group_view": {"include_new_in_tbr": False},
        "library_background": {
            "enabled": True,
            "path": str(background_path.resolve()),
        },
    }


def _embedded_cover(source: Path) -> tuple[Image.Image, str] | None:
    if source.suffix.lower() not in (".epub", ".kepub"):
        return None
    try:
        with ZipFile(source) as archive:
            names = archive.namelist()
            opf_name: str | None = None
            if "META-INF/container.xml" in names:
                container = ElementTree.fromstring(archive.read("META-INF/container.xml"))
                rootfile = container.find(".//{*}rootfile")
                if rootfile is not None:
                    opf_name = rootfile.attrib.get("full-path")
            if not opf_name:
                opf_name = next((name for name in names if name.lower().endswith(".opf")), None)
            candidates: list[str] = []
            if opf_name and opf_name in names:
                package = ElementTree.fromstring(archive.read(opf_name))
                cover_ids = {
                    element.attrib.get("content")
                    for element in package.findall(".//{*}meta")
                    if element.attrib.get("name", "").casefold() == "cover"
                }
                base = posixpath.dirname(opf_name)
                for item in package.findall(".//{*}manifest/{*}item"):
                    properties = item.attrib.get("properties", "").split()
                    if item.attrib.get("id") in cover_ids or "cover-image" in properties:
                        href = item.attrib.get("href")
                        if href:
                            candidates.append(posixpath.normpath(posixpath.join(base, href)))
            candidates.extend(
                name for name in names
                if re.search(r"(^|[/_.-])cover([/_.-]|$)", name, re.IGNORECASE)
                and name.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))
            )
            candidates.extend(
                name for name in names
                if name.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))
            )
            for name in dict.fromkeys(candidates):
                if name not in names:
                    continue
                try:
                    with Image.open(io.BytesIO(archive.read(name))) as image:
                        if image.width < 100 or image.height < 100:
                            continue
                        return image.convert("RGB"), f"{image.width}x{image.height}"
                except (OSError, ValueError):
                    continue
    except (BadZipFile, KeyError, ElementTree.ParseError):
        return None
    return None


def _embedded_description(source: Path) -> str | None:
    if source.suffix.lower() not in (".epub", ".kepub"):
        return None
    try:
        with ZipFile(source) as archive:
            names = archive.namelist()
            opf_name: str | None = None
            if "META-INF/container.xml" in names:
                container = ElementTree.fromstring(archive.read("META-INF/container.xml"))
                rootfile = container.find(".//{*}rootfile")
                if rootfile is not None:
                    opf_name = rootfile.attrib.get("full-path")
            if not opf_name:
                opf_name = next((name for name in names if name.lower().endswith(".opf")), None)
            if not opf_name or opf_name not in names:
                return None
            package = ElementTree.fromstring(archive.read(opf_name))
            metadata = package.find(".//{*}metadata")
            if metadata is None:
                return None
            description = metadata.find("{*}description")
            if description is None:
                description = next((
                    item for item in metadata.findall("{*}meta")
                    if item.attrib.get("name", "").casefold() == "description"
                ), None)
            if description is None:
                return None
            text = description.attrib.get("content") or "".join(description.itertext())
            text = text.strip()
            return text or None
    except (BadZipFile, KeyError, ElementTree.ParseError):
        return None


def _embedded_keywords(source: Path) -> str | None:
    if source.suffix.lower() not in (".epub", ".kepub"):
        return None
    try:
        with ZipFile(source) as archive:
            names = archive.namelist()
            opf_name: str | None = None
            if "META-INF/container.xml" in names:
                container = ElementTree.fromstring(archive.read("META-INF/container.xml"))
                rootfile = container.find(".//{*}rootfile")
                if rootfile is not None:
                    opf_name = rootfile.attrib.get("full-path")
            if not opf_name:
                opf_name = next((name for name in names if name.lower().endswith(".opf")), None)
            if not opf_name or opf_name not in names:
                return None
            package = ElementTree.fromstring(archive.read(opf_name))
            metadata = package.find(".//{*}metadata")
            if metadata is None:
                return None
            subjects = ["".join(item.itertext()).strip() for item in metadata.findall("{*}subject")]
            return ", ".join(subject for subject in subjects if subject) or None
    except (BadZipFile, KeyError, ElementTree.ParseError):
        return None


def _cover_blob(source: Path) -> tuple[int, int, str, bytes] | None:
    cover = _embedded_cover(source)
    zstd = shutil.which("zstd")
    if cover is None or zstd is None:
        return None
    image, size_tag = cover
    image.thumbnail((360, 540), Image.Resampling.LANCZOS)
    image = image.convert("RGBA")
    raw = image.tobytes()
    compressed = subprocess.run(
        [zstd, "-q", "-c", f"--stream-size={len(raw)}", "-"],
        input=raw,
        capture_output=True,
        check=True,
    ).stdout
    return image.width, image.height, size_tag, compressed


def _seed_bookinfo(ko_home: Path, books: Sequence[StagedBook]) -> None:
    database = ko_home / "settings" / "bookinfo_cache.sqlite3"
    database.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(database) as connection:
        connection.executescript("""
            PRAGMA user_version=20201210;
            CREATE TABLE bookinfo (
                bcid INTEGER PRIMARY KEY AUTOINCREMENT,
                directory TEXT NOT NULL, filename TEXT NOT NULL,
                filesize INTEGER, filemtime INTEGER, in_progress INTEGER,
                unsupported TEXT, cover_fetched TEXT, has_meta TEXT,
                has_cover TEXT, cover_sizetag TEXT, ignore_meta TEXT,
                ignore_cover TEXT, pages INTEGER, title TEXT, authors TEXT,
                series TEXT, series_index REAL, language TEXT, keywords TEXT,
                description TEXT, cover_w INTEGER, cover_h INTEGER,
                cover_bb_type INTEGER, cover_bb_stride INTEGER, cover_bb_data BLOB
            );
            CREATE UNIQUE INDEX dir_filename ON bookinfo(directory, filename);
            CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT);
        """)
        connection.executemany(
            "INSERT INTO config (key, value) VALUES (?, ?)",
            (
                ("filemanager_display_mode", "mosaic_image"),
                ("no_hint_description", "Y"),
                ("files_per_page", "5"),
                ("nb_cols_portrait", "4"),
                ("nb_rows_portrait", "3"),
            ),
        )
        for index, book in enumerate(books):
            stat = book.path.stat()
            cover = _cover_blob(book.source)
            description = _embedded_description(book.source)
            connection.execute(
                """INSERT INTO bookinfo (
                    directory, filename, filesize, filemtime, in_progress,
                    cover_fetched, has_meta, has_cover, cover_sizetag,
                    pages, title, authors, series, series_index, language,
                    keywords, description, cover_w, cover_h, cover_bb_type,
                    cover_bb_stride, cover_bb_data
                ) VALUES (?, ?, ?, ?, ?, ?, 'Y', ?, ?, ?, ?, ?, ?, ?, 'en', ?, ?, ?, ?, ?, ?, ?)""",
                (
                    str(book.path.parent.resolve()) + "/",
                    book.path.name,
                    stat.st_size,
                    int(stat.st_mtime),
                    0,
                    "Y" if cover else None,
                    "Y" if cover else None,
                    cover[2] if cover else None,
                    384 + index * 17,
                    book.title,
                    book.authors,
                    book.series,
                    index + 1,
                    book.keywords,
                    description,
                    cover[0] if cover else None,
                    cover[1] if cover else None,
                    BB_TYPE_RGB32 if cover else None,
                    cover[0] * 4 if cover else None,
                    cover[3] if cover else None,
                ),
            )


def _seed_statistics(ko_home: Path, books: Sequence[StagedBook]) -> None:
    database = ko_home / "settings" / "statistics.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.executescript("""
            PRAGMA user_version=20221111;
            CREATE TABLE book (
                id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, authors TEXT,
                notes INTEGER, last_open INTEGER, highlights INTEGER, pages INTEGER,
                series TEXT, language TEXT, md5 TEXT, total_read_time INTEGER,
                total_read_pages INTEGER
            );
            CREATE UNIQUE INDEX book_title_authors_md5 ON book(title, authors, md5);
            CREATE TABLE page_stat_data (
                id_book INTEGER, page INTEGER NOT NULL DEFAULT 0,
                start_time INTEGER NOT NULL DEFAULT 0, duration INTEGER NOT NULL DEFAULT 0,
                total_pages INTEGER NOT NULL DEFAULT 0,
                UNIQUE (id_book, page, start_time)
            );
            CREATE INDEX page_stat_data_start_time ON page_stat_data(start_time);
            CREATE TABLE numbers (number INTEGER PRIMARY KEY);
            CREATE VIEW page_stat AS
                SELECT id_book, first_page + idx - 1 AS page, start_time,
                       duration / (last_page - first_page + 1) AS duration
                FROM (
                    SELECT id_book, page, total_pages, pages, start_time, duration,
                        ((page - 1) * pages) / total_pages + 1 AS first_page,
                        max(((page - 1) * pages) / total_pages + 1,
                            (page * pages) / total_pages) AS last_page,
                        idx
                    FROM page_stat_data
                    JOIN book ON book.id = id_book
                    JOIN (SELECT number AS idx FROM numbers) AS N
                      ON idx <= (last_page - first_page + 1)
                );
        """)
        connection.executemany(
            "INSERT INTO numbers(number) VALUES (?)",
            ((value,) for value in range(1, 1001)),
        )
        fixed_ts = int(time.mktime(FIXED_LOCAL_TIME.timetuple()))
        for index, book in enumerate(books, start=1):
            connection.execute(
                """INSERT INTO book (
                    id, title, authors, notes, last_open, highlights, pages,
                    series, language, md5, total_read_time, total_read_pages
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'en', ?, ?, ?)""",
                (
                    index, book.title, book.authors, index % 3,
                    fixed_ts - index * 600, index % 4, 384 + (index - 1) * 17,
                    book.series, hashlib.md5(str(book.path).encode()).hexdigest(),
                    7200 + index * 300, 80 + index * 5,
                ),
            )
        active_offsets = list(range(0, 9)) + list(range(10, 15))
        for day_offset in active_offsets:
            day = FIXED_LOCAL_TIME - timedelta(days=day_offset)
            page_count = 24 if day_offset == 0 else 8 + (day_offset % 7)
            total_duration = 38 * 60 if day_offset == 0 else page_count * (70 + day_offset)
            for page_index in range(page_count):
                book_id = day_offset % len(books) + 1
                stamp = int(time.mktime(day.replace(
                    hour=8 + page_index % 3,
                    minute=(page_index * 7) % 60,
                    second=0,
                ).timetuple()))
                duration = total_duration // page_count
                if page_index == page_count - 1:
                    duration += total_duration - duration * page_count
                connection.execute(
                    "INSERT INTO page_stat_data VALUES (?, ?, ?, ?, ?)",
                    (book_id, page_index + 1, stamp, duration, 384 + (book_id - 1) * 17),
                )


def _seed_sidecars(books: Sequence[StagedBook]) -> None:
    progress = (
        0.62, 0.18, 0.45, 1.0, 0.0, 0.77,
        0.31, 0.54, 0.12, 0.28, 0.69, 0.08,
    )
    statuses = (
        "reading", "reading", "tbr", "complete", None, "reading",
        None, "reading", "tbr", "reading", "complete", "tbr",
    )
    for index, book in enumerate(books):
        sidecar = book.path.with_suffix(".sdr") / f"metadata.{book.path.suffix.lstrip('.').lower()}.lua"
        metadata = {
            "doc_pages": 384 + index * 17,
            "percent_finished": progress[index],
            "partial_md5_checksum": hashlib.md5(str(book.path).encode()).hexdigest(),
            "summary": {"status": statuses[index]},
        }
        if book.role != "reader":
            metadata["bookmarks"] = [{
                "page": 3 + index,
                "datetime": "2026-06-17 21:14:00",
                "text": "A deterministic showcase bookmark.",
            }]
        _write_lua(sidecar, metadata)


def stage_showcase_background(ko_home: Path) -> Path:
    destination = ko_home / SHOWCASE_BACKGROUND.name
    shutil.copyfile(SHOWCASE_BACKGROUND, destination)
    return destination.resolve()


def seed_showcase(ko_home: Path, books: Sequence[StagedBook], runtime: Path) -> None:
    settings = ko_home / "settings"
    zen_settings = settings / "ZenOS"
    settings.mkdir(parents=True, exist_ok=True)
    zen_settings.mkdir(parents=True, exist_ok=True)
    background_path = stage_showcase_background(ko_home)
    _write_merged_lua(
        runtime,
        runtime / "settings.reader.lua",
        ko_home / "settings.reader.lua",
        {
            "home_dir": str(books[0].path.parent.resolve()),
            "lastdir": str(books[0].path.parent.resolve()),
            "language": "en",
            "night_mode": False,
            "collate": "access",
            "reverse_collate": False,
            "collate_mixed": False,
            "file_ask_to_open": False,
            "statistics": {"is_enabled": True, "max_sec": 120},
        },
        baseline_keys=READER_BASELINE_SETTING_KEYS,
        baseline_prefixes=("copt_",),
    )
    _write_merged_lua(
        runtime,
        runtime / "settings" / "ZenOS" / "config.lua",
        zen_settings / "config.lua",
        _zen_config(background_path),
    )
    reader_baseline = runtime / "settings" / "ZenOS" / "reader.lua"
    if reader_baseline.is_file():
        shutil.copyfile(reader_baseline, zen_settings / "reader.lua")
    _write_lua(zen_settings / "stats.lua", {
        "settings": {
            "widgets": {
                "order": [
                    "this_year", "trend_graph", "goal_progress", "calendar", "library",
                    "today", "this_week", "this_month", "all_time", "personal_records",
                    "current_book",
                ],
                "enabled": {
                    "this_year": True,
                    "trend_graph": True,
                    "goal_progress": True,
                    "calendar": True,
                },
                "options": {
                    "trend_graph": {"id": "trend_graph", "metric": "pages", "range_days": 14},
                },
            },
            "font_size": 15,
            "stat_style": "divider",
        },
        "presets": {},
        "version": 1,
    })
    _write_lua(zen_settings / "app_launcher.lua", {
        "entries": [
            {
                "id": "showcase_vocabulary", "type": "plugin",
                "label": "Vocabulary builder", "icon": "lookup.translate",
                "plugin": {"key": "vocabbuilder", "method": "__menu_callback"},
            },
            {
                "id": "showcase_rakuyomi", "type": "plugin",
                "label": "Rakuyomi", "icon": "tab_manga",
                "plugin": {"key": "rakuyomi", "method": "__menu_callback"},
            },
            {
                "id": "showcase_opds", "type": "quick_setting",
                "label": "OPDS", "icon": "quick_opds", "quick_setting_id": "opds",
            },
            {
                "id": "showcase_calibre", "type": "plugin",
                "label": "Calibre", "icon": "quick_calibre",
                "plugin": {"key": "calibre", "method": "__menu_submenu"},
            },
            {
                "id": "showcase_battery", "type": "plugin",
                "label": "Battery", "icon": "quick_battery",
                "plugin": {"key": "batterystat", "method": "__menu_callback"},
            },
            {
                "id": "showcase_terminal", "type": "plugin",
                "label": "Terminal", "icon": "terminal",
                "plugin": {"key": "terminal", "method": "__menu_submenu"},
            },
            {
                "id": "showcase_zenfm", "type": "action",
                "label": "ZenFM", "icon": "zenfm", "action": {"gesture_overview": True},
            },
            {
                "id": "showcase_games", "type": "folder",
                "label": "Games", "icon": "folder_open", "children": [],
            },
            {
                "id": "showcase_network", "type": "koreader_menu",
                "label": "Network", "icon": "network",
                "koreader_menu": {"id": "network", "title": "Network"},
            },
            {
                "id": "showcase_zenpm", "type": "plugin",
                "label": "ZenPM", "icon": "zenpm",
                "plugin": {"key": "zenpm", "method": "open"},
            },
        ],
        "next_id": 10,
        "show_labels": True,
        "open_first": False,
        "page_order": ["buttons", "book_switcher", "book_details"],
        "show_book_switcher": True,
        "book_switcher_reader_only": False,
        "show_book_details": True,
        "book_details_enabled": {
            "read_time": True,
            "time_remaining": True,
            "pages_today": True,
            "time_today": True,
            "pages": True,
            "progress": True,
        },
        "zenpm_launcher_added": True,
    })
    fixed_ts = int(time.mktime(FIXED_LOCAL_TIME.timetuple()))
    _write_lua(ko_home / "history.lua", [
        {"time": fixed_ts - index * 600, "file": str(book.path.resolve())}
        for index, book in enumerate(books)
    ])
    _write_lua(settings / "collection.lua", {
        "favorites": [
            *({"file": str(book.path.resolve()), "order": index + 1}
              for index, book in enumerate(books[:3])),
        ],
        "To Be Read": [
            *({"file": str(book.path.resolve()), "order": index + 1}
              for index, book in enumerate((books[2], books[8]))),
        ],
    })
    _seed_bookinfo(ko_home, books)
    _seed_statistics(ko_home, books)
    _seed_sidecars(books)


def extract_docs_inventory(docs_root: Path) -> dict[str, list[str]]:
    pattern = re.compile(r"/images/zen_os/([A-Za-z0-9_.-]+)")
    inventory: dict[str, list[str]] = {}
    for document in sorted(docs_root.glob("*.md")):
        try:
            display_path = document.relative_to(REPO_ROOT)
        except ValueError:
            display_path = document.relative_to(docs_root.parent)
        for filename in pattern.findall(document.read_text(encoding="utf-8")):
            inventory.setdefault(filename, []).append(str(display_path))
    return inventory


def extract_gallery_inventory(source: Path | None) -> list[str]:
    if source is None or not source.is_file():
        return []
    pattern = re.compile(r"/images/zen_os/([A-Za-z0-9_.-]+)")
    return sorted(set(pattern.findall(source.read_text(encoding="utf-8"))))


def audit_inventory(
    scenarios: Sequence[Scenario],
    docs_root: Path = REPO_ROOT / "docs",
    website_source: Path | None = None,
) -> dict[str, object]:
    catalog_files = {scenario.filename for scenario in scenarios}
    docs = extract_docs_inventory(docs_root)
    gallery = extract_gallery_inventory(website_source)
    errors: list[str] = []
    warnings: list[str] = []
    for filename, references in sorted(docs.items()):
        if (filename in NON_EMULATOR_ASSETS
                or filename in MANUAL_SCREENSHOT_ASSETS
                or filename.endswith(".svg")):
            continue
        if filename not in catalog_files:
            errors.append(f"untracked emulator image {filename}: {', '.join(references)}")
        if filename.startswith("page_browser") and filename not in (
                "page_browser_grid.png", "page_browser_carousel.png"):
            errors.append(f"retired Page Browser image remains in docs: {filename}")
        if filename == "update_available.png":
            errors.append("update_available.png remains in docs")
    for filename in gallery:
        if (filename in NON_EMULATOR_ASSETS
                or filename in MANUAL_SCREENSHOT_ASSETS
                or filename.endswith(".svg")):
            continue
        if filename.startswith("page_browser") and filename not in (
                "page_browser_grid.png", "page_browser_carousel.png"):
            warnings.append(
                f"website carousel still contains retired {filename}; remove it when the website source is next updated"
            )
        elif filename not in catalog_files:
            warnings.append(f"website carousel contains non-catalog image {filename}")
    documented = {
        filename for filename in docs
        if filename in catalog_files
    }
    return {
        "ok": not errors,
        "catalog_count": len(catalog_files),
        "docs": docs,
        "gallery": gallery,
        "documented_catalog_images": sorted(documented),
        "undocumented_catalog_images": sorted(catalog_files - documented),
        "excluded_non_emulator_assets": sorted(
            filename for filename in docs if filename in NON_EMULATOR_ASSETS or filename.endswith(".svg")
        ),
        "excluded_manual_screenshot_assets": sorted(
            filename for filename in docs if filename in MANUAL_SCREENSHOT_ASSETS
        ),
        "errors": errors,
        "warnings": warnings,
    }


def runtime_version(runtime: Path) -> dict[str, str]:
    result = {"path": str(runtime.resolve()), "directory": runtime.parent.name}
    for name in ("git-rev", "version.log"):
        path = runtime / name
        if path.is_file():
            result[name.replace(".", "_")] = path.read_text(encoding="utf-8", errors="replace").strip()
    return result


def write_report(path: Path, report: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def export_screenshots(source: Path, destination: Path, filenames: Sequence[str]) -> Path:
    requested = sorted(set(filenames))
    missing = [filename for filename in requested if not (source / filename).is_file()]
    if missing:
        raise ValueError(f"website-ready source images are missing: {', '.join(missing)}")
    if destination.exists():
        if not destination.is_dir():
            raise ValueError(f"output path is not a folder: {destination}")
        if any(destination.iterdir()):
            raise ValueError(f"output folder must be empty: {destination}")
    else:
        destination.mkdir(parents=True)
    for filename in requested:
        shutil.copyfile(source / filename, destination / filename)
    return destination


def _require_ok(response: dict[str, object], action: str) -> dict[str, object]:
    if response.get("ok") is not True:
        raise CaptureError(f"{action} failed: {response.get('error', response)}")
    return response


def _wait_for(
    callback: object,
    predicate: object,
    description: str,
    timeout: float = 30,
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    latest: dict[str, object] = {}
    while time.monotonic() < deadline:
        latest = callback()  # type: ignore[operator]
        if predicate(latest):  # type: ignore[operator]
            return latest
        time.sleep(0.25)
    raise CaptureError(f"timed out waiting for {description}: {latest}")


def stable_frame(driver: ZenDriver, raw_output: Path, timeout: float = 30) -> str:
    raw_output.parent.mkdir(parents=True, exist_ok=True)
    first = raw_output.with_suffix(".first.png")
    second = raw_output.with_suffix(".second.png")
    deadline = time.monotonic() + timeout
    previous_hash: str | None = None
    try:
        while time.monotonic() < deadline:
            driver.screenshot(first)
            first_hash = sha256_file(first)
            time.sleep(0.3)
            driver.screenshot(second)
            second_hash = sha256_file(second)
            if first_hash == second_hash and (previous_hash is None or previous_hash == second_hash):
                shutil.copyfile(second, raw_output)
                with Image.open(raw_output) as image:
                    if image.size != SCREEN_SIZE:
                        raise CaptureError(
                            f"raw framebuffer has {image.size}, expected {SCREEN_SIZE}"
                        )
                    image.verify()
                return second_hash
            previous_hash = second_hash if first_hash == second_hash else None
        raise CaptureError("framebuffer did not produce two matching hashes")
    finally:
        first.unlink(missing_ok=True)
        second.unlink(missing_ok=True)


def crop_from_bounds(raw: Path, output: Path, bounds: dict[str, object], padding: int = 0) -> tuple[int, int]:
    required = ("x", "y", "w", "h")
    if any(not isinstance(bounds.get(key), (int, float)) for key in required):
        raise ValueError(f"invalid semantic crop bounds: {bounds}")
    with Image.open(raw) as source:
        x = max(0, int(bounds["x"]) - padding)
        y = max(0, int(bounds["y"]) - padding)
        right = min(source.width, int(bounds["x"]) + int(bounds["w"]) + padding)
        bottom = min(source.height, int(bounds["y"]) + int(bounds["h"]) + padding)
        if right <= x or bottom <= y:
            raise ValueError(f"empty semantic crop bounds: {bounds}")
        cropped = source.crop((x, y, right, bottom))
        output.parent.mkdir(parents=True, exist_ok=True)
        cropped.save(output, format="PNG", optimize=True)
        return cropped.size


class CaptureWorkflow:
    def __init__(
        self,
        runtime: Path,
        scenarios: Sequence[Scenario],
        books: Sequence[ResolvedBook],
        run_dir: Path,
        website_root: Path | None,
        calibre_root: Path | None = None,
        quote: str | None = None,
    ):
        self.runtime = runtime
        self.scenarios = list(scenarios)
        self.books = list(books)
        self.run_dir = run_dir
        self.raw_dir = run_dir / "raw"
        self.output_dir = run_dir
        self.website_root = website_root
        self.calibre_root = calibre_root
        self.quote = quote
        self.results: list[dict[str, object]] = []

    def _role(self, books: Sequence[StagedBook], role: str) -> StagedBook:
        matches = [book for book in books if book.role == role]
        if len(matches) != 1:
            raise CaptureError(f"expected one {role} book, found {len(matches)}")
        return matches[0]

    def _reset(self, driver: ZenDriver, session: str) -> None:
        _require_ok(driver.command("reset_showcase_ui", session=session), "reset showcase UI")

    def _reader_at_showcase_page(self, driver: ZenDriver, book: StagedBook) -> None:
        state = driver.reader_state()
        if state.get("reader", {}).get("open") is not True:
            _require_ok(driver.open_book(book.path), "open reader book")
            _wait_for(
                driver.reader_state,
                lambda value: value.get("reader", {}).get("open") is True,
                "reader",
            )
        _require_ok(driver.command("ensure_reader_status_fonts"), "reader status fonts")
        _require_ok(
            driver.command("goto_reader_page", page=READER_SHOWCASE_PAGE),
            f"go to reader page {READER_SHOWCASE_PAGE}",
        )
        _wait_for(
            driver.reader_state,
            lambda value: value.get("reader", {}).get("page") == READER_SHOWCASE_PAGE,
            f"reader page {READER_SHOWCASE_PAGE}",
        )
        _wait_for(
            driver.reader_state,
            lambda value: value.get("reader", {}).get("active_preset")
            == READER_SHOWCASE_PRESET,
            READER_SHOWCASE_PRESET,
        )
        _require_ok(
            driver.command("ensure_reader_chapter_time"),
            "reader chapter time remaining",
        )

    def _prepare_scenario(
        self,
        driver: ZenDriver,
        scenario: Scenario,
        books: Sequence[StagedBook],
    ) -> None:
        action = scenario.action
        options = scenario.options
        expected_navbar = None
        if scenario.session == "general":
            navbar_mode = str(options.get("navbar", "default"))
            expected_navbar = SHOWCASE_NAVBAR_STATES[navbar_mode]
            navbar_response = _require_ok(
                driver.command("showcase_navbar", mode=navbar_mode),
                f"{scenario.id} navbar",
            )
            if navbar_response.get("navbar") != expected_navbar:
                raise CaptureError(
                    f"{scenario.id} navbar state mismatch: {navbar_response.get('navbar')}"
                )
        if action in ("home_preset", "home_simple"):
            response = driver.command(
                "showcase_home",
                preset=options.get("preset"),
                simple=action == "home_simple",
            )
            _require_ok(response, action)
            featured_title = self._role(books, "featured").title
            expected_quote = (
                self.quote
                if action == "home_preset" and options.get("preset") == "Zen Default"
                else None
            )
            minimum_images = 5
            _wait_for(
                lambda: driver.command("home_state"),
                lambda value: value.get("home", {}).get("active") is True
                and int(value.get("home", {}).get("image_widget_count", 0)) >= minimum_images
                and featured_title in value.get("home", {}).get("visible_texts", [])
                and (
                    expected_quote is None
                    or expected_quote
                    in (
                        value.get("home", {})
                        .get("quote_content_bounds", {})
                        .get("text")
                        or ""
                    )
                )
                and value.get("home", {}).get("navbar") == expected_navbar
                and (
                    action != "home_simple"
                    or (
                        all(widget_id in value.get("home", {}).get("widget_ids", []) for widget_id in (
                            "datetime", "featured", "stats_triplet", "strip",
                        ))
                        and int(value.get("home", {}).get("strip_control_count", 0)) > 0
                    )
                ),
                scenario.id,
            )
            return
        if action == "library":
            visible_books = options.get("visible_books")
            ordered_books = None
            if isinstance(visible_books, list):
                visible_titles = [str(title) for title in visible_books]
                if len(visible_titles) != len(set(visible_titles)):
                    raise CaptureError("list showcase book titles must be unique")
                books_by_title = {book.title: book for book in books}
                missing = [title for title in visible_titles if title not in books_by_title]
                if missing:
                    raise CaptureError(
                        f"list showcase books were not staged: {', '.join(missing)}"
                    )
                requested = set(visible_titles)
                ordered_books = [books_by_title[title] for title in visible_titles]
                ordered_books.extend(book for book in books if book.title not in requested)
            _require_ok(
                driver.command("set_library_display_mode", mode=options["mode"]),
                action,
            )
            if ordered_books is not None:
                _require_ok(
                    driver.command(
                        "showcase_library_order",
                        paths=[str(book.path.resolve()) for book in ordered_books],
                    ),
                    f"{scenario.id} book order",
                )
            _wait_for(
                lambda: driver.command("file_chooser_items"),
                lambda value: value.get("file_chooser", {}).get("display_mode_type")
                in ("mosaic", "list")
                and value.get("file_chooser", {}).get("status_bar", {}).get(
                    "hide_browser_bar"
                ) is True
                and value.get("file_chooser", {}).get("status_bar", {}).get(
                    "center_item_count"
                ) == 0
                and int(value.get("file_chooser", {}).get("status_bar", {}).get(
                    "custom_height", 0
                )) > 0
                and value.get("file_chooser", {}).get("mosaic_title_strip", {}).get(
                    "show_title"
                ) is False
                and value.get("file_chooser", {}).get("mosaic_title_strip", {}).get(
                    "show_author"
                ) is False,
                scenario.id,
            )
            if ordered_books is not None:
                expected_paths = [
                    str(next(book.path for book in books if book.title == title).resolve())
                    for title in visible_titles
                ]
                _wait_for(
                    lambda: driver.command("file_chooser_items"),
                    lambda value: [
                        item.get("path")
                        for item in value.get("file_chooser", {}).get("items", [])[
                            :len(expected_paths)
                        ]
                    ] == expected_paths,
                    f"{scenario.id} visible books",
                )
            return
        if action == "context":
            book = self._role(books, str(options["book_role"]))
            _require_ok(driver.command("set_library_display_mode", mode="mosaic_image"), action)
            _require_ok(driver.command("open_file_context", path=str(book.path.resolve())), action)
            return
        if action == "metadata_editor":
            title = str(options["book_title"])
            book = next((book for book in books if book.title == title), None)
            if book is None:
                raise CaptureError(f"metadata editor book was not staged: {title}")
            response = _require_ok(
                driver.command(
                    "show_metadata_editor_fixture",
                    orientation="portrait",
                    file=str(book.path.resolve()),
                ),
                action,
            )
            metadata = response.get("metadata", {})
            if (metadata.get("file") != str(book.path.resolve())
                    or metadata.get("title") != book.title
                    or metadata.get("dirty") is not False
                    or metadata.get("has_current_cover") is not True):
                raise CaptureError(f"metadata editor fixture mismatch: {metadata}")
            return
        if action == "navbar":
            _require_ok(driver.command("set_library_display_mode", mode="mosaic_image"), action)
            return
        if action == "stats":
            _require_ok(driver.command("activate_navbar_tab", id="stats"), action)
            _wait_for(
                lambda: driver.command("navbar_state"),
                lambda value: value.get("navbar", {}).get("top_name") == "stats",
                scenario.id,
            )
            return
        if action in ("menu_tab", "menu_button"):
            background = options.get("background")
            if background in ("home", "home_simple"):
                _require_ok(
                    driver.command(
                        "showcase_home",
                        preset="Zen Default",
                        simple=background == "home_simple",
                    ),
                    "Home background",
                )
                featured_title = self._role(books, "featured").title
                _wait_for(
                    lambda: driver.command("home_state"),
                    lambda value: value.get("home", {}).get("active") is True
                    and int(value.get("home", {}).get("image_widget_count", 0)) >= 5
                    and featured_title in value.get("home", {}).get("visible_texts", []),
                    "Home background",
                )
            if options.get("show_lockdown_control") is True:
                _require_ok(driver.command("showcase_lockdown_control"), action)
            _require_ok(driver.command("menu_tab_layout", tab_id=options["tab"]), action)
            return
        if action == "quickstart":
            _require_ok(driver.command("open_quickstart"), action)
            return
        if action == "zen_settings":
            _require_ok(driver.command("open_settings_page"), action)
            _wait_for(
                lambda: driver.command("settings_page_state"),
                lambda value: value.get("ok") is True,
                scenario.id,
            )
            return
        if action in (
            "launcher_add_plugin_menu",
            "launcher_add_koreader_menu",
            "controls_buttons_settings",
            "navbar_buttons_settings",
        ):
            _require_ok(driver.command("open_settings_page"), action)
            _wait_for(
                lambda: driver.command("settings_page_state"),
                lambda value: value.get("settings", {}).get("title") == "Settings",
                "settings root",
            )
            if action.startswith("launcher_add_"):
                root_label = "Launcher"
            elif action == "controls_buttons_settings":
                root_label = "Controls"
            else:
                root_label = "Navbar"
            _require_ok(
                driver.command("settings_page_select", label=root_label),
                root_label,
            )
            opener = "Tabs" if action == "navbar_buttons_settings" else "Buttons"
            _wait_for(
                lambda: driver.command("settings_page_state"),
                lambda value: value.get("settings", {}).get("title") == root_label
                and opener in value.get("settings", {}).get("labels", []),
                f"{root_label} settings",
            )
            _require_ok(
                driver.command("settings_page_select", label=opener),
                opener,
            )
            arrange = _wait_for(
                lambda: driver.command("arrange_page_state"),
                lambda value: value.get("arrange", {}).get("title") == opener,
                f"{opener} settings",
            )["arrange"]
            if action == "navbar_buttons_settings":
                expected = {
                    "Library": True,
                    "Home": True,
                    "To Be Read": True,
                    "Authors": False,
                    "Tags": False,
                    "Sci-Fi folder": False,
                }
                actual = dict(zip(arrange["labels"], arrange["checked"], strict=True))
                if any(actual.get(label) is not checked for label, checked in expected.items()):
                    raise CaptureError(f"navbar button states did not match: {actual}")
                return

            if action == "controls_buttons_settings":
                expected = {
                    "Wi-Fi": True,
                    "Night mode": True,
                    "Zen mode": True,
                    "Lockdown": False,
                    "Incognito": False,
                    "USB": False,
                    "File search": False,
                    "Restart": True,
                    "Exit": False,
                    "Sleep": True,
                }
                actual = dict(zip(arrange["labels"], arrange["checked"], strict=True))
                if any(actual.get(label) is not checked for label, checked in expected.items()):
                    raise CaptureError(f"Controls button states did not match: {actual}")
                return

            _require_ok(driver.command("arrange_page_action"), "Launcher Add")
            picker_label = (
                "Plugin Menu" if action == "launcher_add_plugin_menu"
                else "KOReader menu"
            )
            add_menu = _wait_for(
                lambda: driver.command("arrange_page_state"),
                lambda value: value.get("arrange", {}).get("title") == "Add"
                and picker_label in value.get("arrange", {}).get("labels", []),
                "Launcher Add menu",
            )["arrange"]
            picker_index = add_menu["labels"].index(picker_label) + 1
            _require_ok(
                driver.command("arrange_page_select", index=picker_index),
                f"Add {picker_label}",
            )
            picker_title = (
                "Choose plugin menu" if action == "launcher_add_plugin_menu"
                else "Choose KOReader menu"
            )
            _wait_for(
                lambda: driver.command("showcase_picker_state"),
                lambda value: value.get("picker", {}).get("title") == picker_title
                and len(value.get("picker", {}).get("labels", [])) >= 3,
                picker_title,
            )
            return
        if action == "reader":
            book = self._role(books, str(options["book_role"]))
            self._reader_at_showcase_page(driver, book)
            return
        if action == "reader_control":
            reader_book = self._role(books, "reader")
            self._reader_at_showcase_page(driver, reader_book)
            _require_ok(
                driver.command("clear_reader_bookmarks"),
                "clear reader bookmarks",
            )
            control = str(options["control"])
            footer_preset = str(options.get("footer_preset", "default"))
            expected_preset = READER_FOOTER_PRESETS.get(footer_preset)
            if expected_preset is None:
                raise CaptureError(f"unknown reader footer preset: {footer_preset}")
            if footer_preset != "default":
                _require_ok(
                    driver.command(
                        "ensure_reader_status_fonts",
                        preset=footer_preset,
                    ),
                    expected_preset,
                )
                _wait_for(
                    driver.reader_state,
                    lambda value: value.get("reader", {}).get("active_preset")
                    == expected_preset,
                    expected_preset,
                )
            if control in ("page_browser_grid", "page_browser_carousel"):
                _require_ok(driver.command("activate_reader_control", name="page_browser"), control)
                _wait_for(
                    lambda: driver.command("page_browser_state"),
                    lambda value: value.get("ok") is True,
                    "Page Browser",
                )
            elif control == "highlight_dictionary":
                _require_ok(
                    driver.command("activate_reader_control", name="show_highlight_menu"),
                    "highlight menu",
                )
            elif control == "launcher_book_details_fullscreen":
                _require_ok(
                    driver.command("activate_reader_control", name="seed_annotations"),
                    "book annotations",
                )
            _require_ok(driver.command("activate_reader_control", name=control), control)
            if control in ("launcher_book_switcher", "launcher_book_details"):
                expected_page = 2 if control == "launcher_book_switcher" else 3
                _wait_for(
                    lambda: driver.command("reader_launcher_state"),
                    lambda value: value.get("launcher", {}).get("open") is True
                    and value.get("launcher", {}).get("page") == expected_page,
                    control,
                )
            elif control == "launcher_book_details_fullscreen":
                _wait_for(
                    lambda: driver.command("hardware_overlay_state"),
                    lambda value: value.get("overlay", {}).get("kind") == "book_info"
                    and int(value.get("overlay", {}).get("annotation_count", 0)) >= 3,
                    control,
                )
            elif control == "highlight_dictionary":
                dictionary_dir = str((self.runtime / "data" / "dict").resolve())
                _wait_for(
                    lambda: driver.command("reader_overlay_state"),
                    lambda value: value.get("overlays", {}).get("dictionary_menu") is True
                    and value.get("overlays", {}).get("dictionary_data_dir") == dictionary_dir,
                    control,
                )
            return
        raise CaptureError(f"unsupported scenario action: {action}")

    def _semantic_bounds(self, driver: ZenDriver, scenario: Scenario) -> dict[str, object] | None:
        crop = scenario.options.get("crop")
        if not isinstance(crop, dict):
            return None
        response = _require_ok(
            driver.command(
                "showcase_bounds",
                target=crop["target"],
                label=crop.get("label"),
            ),
            f"{scenario.id} crop bounds",
        )
        bounds = response.get("bounds")
        if not isinstance(bounds, dict):
            raise CaptureError(f"{scenario.id} returned no semantic bounds")
        return bounds

    def _capture_one(
        self,
        driver: ZenDriver,
        scenario: Scenario,
        books: Sequence[StagedBook],
    ) -> None:
        started = time.monotonic()
        result: dict[str, object] = {
            "id": scenario.id,
            "filename": scenario.filename,
            "group": scenario.group,
            "session": scenario.session,
            "docs": list(scenario.docs),
        }
        try:
            self._reset(driver, scenario.session)
            self._prepare_scenario(driver, scenario, books)
            raw = self.raw_dir / scenario.filename
            raw_hash = stable_frame(driver, raw)
            if scenario.session == "reader":
                reader = driver.reader_state().get("reader", {})
                result["reader_page"] = reader.get("page")
                result["reader_preset"] = reader.get("active_preset")
            bounds = self._semantic_bounds(driver, scenario)
            output = self.output_dir / scenario.filename
            if bounds is None:
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(raw, output)
                dimensions = SCREEN_SIZE
            else:
                crop = scenario.options["crop"]
                dimensions = crop_from_bounds(raw, output, bounds, int(crop.get("padding", 0)))
                result["crop_bounds"] = bounds
            with Image.open(output) as image:
                image.verify()
            result.update({
                "status": "passed",
                "raw_dimensions": list(SCREEN_SIZE),
                "dimensions": list(dimensions),
                "raw_sha256": raw_hash,
                "sha256": sha256_file(output),
            })
        except Exception as error:
            result.update({"status": "failed", "error": f"{type(error).__name__}: {error}"})
        result["duration_seconds"] = round(time.monotonic() - started, 3)
        self.results.append(result)

    def _session(
        self,
        session: str,
        scenarios: Sequence[Scenario],
        books: Sequence[StagedBook],
        root: Path,
    ) -> None:
        ko_home = root / f"ko-home-{session}"
        ko_home.mkdir()
        seed_showcase(ko_home, books, self.runtime)
        socket_path = root / f"driver-{session}.sock"
        window_size = (
            (SCREEN_SIZE[0] // 2, SCREEN_SIZE[1] // 2)
            if sys.platform == "darwin" else SCREEN_SIZE
        )
        process = launch(
            self.runtime,
            ko_home,
            socket_path,
            books[0].path.parent,
            env_overrides={
                "EMULATE_READER_W": str(window_size[0]),
                "EMULATE_READER_H": str(window_size[1]),
                "EMULATE_READER_DPI": "300",
                "LC_ALL": "en_US.UTF-8",
                "TZ": "America/New_York",
                "STARDICT_DATA_DIR": str((self.runtime / "data" / "dict").resolve()),
                "ZEN_UI_SHOWCASE_TIMESTAMP": str(int(time.mktime(FIXED_LOCAL_TIME.timetuple()))),
                "ZEN_UI_SHOWCASE_BATTERY": "82",
            },
            language="en",
            initialize_settings=False,
        )
        try:
            wait_for_socket(socket_path, timeout=45)
            driver = ZenDriver(socket_path)
            showcase_options: dict[str, object] = {
                "timestamp": int(time.mktime(FIXED_LOCAL_TIME.timetuple())),
                "battery": 82,
                "wifi": True,
            }
            if self.quote is not None:
                showcase_options["quote"] = self.quote
            _require_ok(
                driver.command("configure_showcase", **showcase_options),
                "configure showcase",
            )
            for scenario in scenarios:
                self._capture_one(driver, scenario, books)
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def run(self) -> dict[str, object]:
        self.run_dir.mkdir(parents=True, exist_ok=False)
        website_paths = _website_watch_paths(self.website_root)
        website_before = snapshot_files(website_paths)
        settings_baseline_before = snapshot_files(_settings_baseline_files(self.runtime))
        source_before = (
            snapshot_tree(self.calibre_root)
            if self.calibre_root else snapshot_files([book.source for book in self.books])
        )
        started = time.monotonic()
        with tempfile.TemporaryDirectory(prefix="zenos-website-screenshots-") as temporary:
            root = Path(temporary)
            self.raw_dir = root / "raw"
            staged = stage_books(self.books, root / "library")
            stage_placeholder_texts(root / "library")
            for session in ("general", "reader"):
                selected = [scenario for scenario in self.scenarios if scenario.session == session]
                if selected:
                    self._session(session, selected, staged, root)
        source_after = (
            snapshot_tree(self.calibre_root)
            if self.calibre_root else snapshot_files([book.source for book in self.books])
        )
        website_after = snapshot_files(website_paths)
        settings_baseline_after = snapshot_files(_settings_baseline_files(self.runtime))
        sources_unchanged = source_before == source_after
        website_unchanged = website_before == website_after
        settings_baseline_unchanged = settings_baseline_before == settings_baseline_after
        audit = audit_inventory(
            load_catalog(),
            website_source=(self.website_root / "src/pages/ZenOsPage.tsx")
            if self.website_root else None,
        )
        report = {
            "schema_version": 1,
            "created_at": datetime.now().astimezone().isoformat(),
            "fixed_showcase_time": FIXED_LOCAL_TIME.isoformat(),
            "quote": self.quote,
            "runtime": runtime_version(self.runtime),
            "screen": {"width": SCREEN_SIZE[0], "height": SCREEN_SIZE[1], "dpi": 300},
            "selected_count": len(self.scenarios),
            "catalog_count": len(EXPECTED_IDS),
            "website_ready_directory": str(self.output_dir.resolve()),
            "results": self.results,
            "source_files": source_before,
            "source_files_unchanged": sources_unchanged,
            "settings_baseline_files": settings_baseline_before,
            "settings_baseline_files_unchanged": settings_baseline_unchanged,
            "website_watch_files": website_before,
            "website_files_unchanged": website_unchanged,
            "audit": audit,
            "duration_seconds": round(time.monotonic() - started, 3),
        }
        write_report(self.run_dir / "report.json", report)
        if not sources_unchanged:
            raise CaptureError("one or more Calibre source files changed during capture")
        if not website_unchanged:
            raise CaptureError("one or more watched website files changed during capture")
        if not settings_baseline_unchanged:
            raise CaptureError("one or more KOReader baseline settings files changed during capture")
        return report


def _website_watch_paths(website_root: Path | None) -> list[Path]:
    if website_root is None or not website_root.is_dir():
        return []
    paths: list[Path] = []
    for directory_name in ("src", "public"):
        directory = website_root / directory_name
        if directory.is_dir():
            paths.extend(path for path in directory.rglob("*") if path.is_file())
    paths.extend(
        website_root / name
        for name in (
            "package.json", "package-lock.json", "vite.config.ts", "tsconfig.json",
        )
    )
    return [path for path in paths if path.is_file()]


def prepare_artifact_directory(root: Path = ARTIFACT_ROOT) -> Path:
    root = root.expanduser()
    if root.is_symlink():
        raise ValueError(f"refusing to clear symlinked artifact directory: {root}")
    root = root.resolve()
    if root.name != "screenshots" or root.parent.name != ".artifacts":
        raise ValueError(f"refusing to clear unexpected artifact directory: {root}")
    if root.exists():
        if not root.is_dir():
            raise ValueError(f"artifact path is not a directory: {root}")
        shutil.rmtree(root)
    return root


def select_scenarios(
    catalog: Sequence[Scenario],
    screen_ids: Sequence[str] | None,
    group: str | None,
    all_screens: bool,
) -> list[Scenario]:
    if all_screens:
        return list(catalog)
    if group:
        return [scenario for scenario in catalog if scenario.group == group]
    if screen_ids:
        by_id = {scenario.id: scenario for scenario in catalog}
        unknown = sorted(set(screen_ids) - by_id.keys())
        if unknown:
            raise ValueError(f"unknown screen ID(s): {', '.join(unknown)}")
        wanted = set(screen_ids)
        return [scenario for scenario in catalog if scenario.id in wanted]
    raise ValueError("choose --screen, --group, or --all")


def _website_root() -> Path | None:
    candidate = REPO_ROOT.parent / "website"
    return candidate if candidate.is_dir() else None


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Capture deterministic ZenOS website screenshots into review artifacts.",
    )
    selector = parser.add_mutually_exclusive_group()
    selector.add_argument("--list", action="store_true", help="list the tracked scenario catalog")
    selector.add_argument("--audit", action="store_true", help="audit docs and website carousel references")
    selector.add_argument("--all", action="store_true", help="capture all catalog scenarios")
    selector.add_argument("--group", choices=sorted(GROUPS), help="capture a scenario group")
    selector.add_argument("--screen", action="append", metavar="ID", help="capture one screen; may be repeated")
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE, help="personal Calibre book profile")
    parser.add_argument(
        "--output",
        type=Path,
        metavar="FOLDER",
        help="also copy successful PNGs into a new or empty folder for manual website use",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    catalog = load_catalog()
    if args.list:
        for scenario in catalog:
            print(f"{scenario.id:26} {scenario.group:8} {scenario.session}")
        return 0
    website_root = _website_root()
    if args.audit:
        audit = audit_inventory(
            catalog,
            website_source=(website_root / "src/pages/ZenOsPage.tsx") if website_root else None,
        )
        print(json.dumps(audit, indent=2, sort_keys=True))
        return 0 if audit["ok"] else 1
    try:
        selected = select_scenarios(catalog, args.screen, args.group, args.all)
    except ValueError as error:
        parser.error(str(error))
    profile = args.profile.expanduser().resolve()
    manual_output = args.output.expanduser().resolve() if args.output else None
    if manual_output and website_root and _is_within(manual_output, website_root.resolve()):
        parser.error("--output must be outside the website repository; copy approved images manually")
    if manual_output and manual_output.exists() and (
            not manual_output.is_dir() or any(manual_output.iterdir())):
        parser.error(f"--output must name a new or empty folder: {manual_output}")
    if not profile.is_file():
        parser.error(
            f"book profile not found: {profile}; copy "
            "spec/python/website_screenshot_books.example.json to "
            ".website-screenshot-books.json and adjust it"
        )
    runtime_value = os.environ.get("KOREADER_DIR", "")
    runtime = Path(runtime_value).resolve() if runtime_value else None
    if runtime is None or not (runtime / "reader.lua").is_file():
        parser.error("KOREADER_DIR must point to the staged KOReader runtime")
    calibre_root, requests, quote = load_profile(profile)
    books = resolve_calibre_books(calibre_root, requests)
    if shutil.which("zstd") is None:
        parser.error("zstd is required to seed deterministic embedded cover thumbnails")
    run_dir = prepare_artifact_directory()
    workflow = CaptureWorkflow(
        runtime, selected, books, run_dir, website_root, calibre_root, quote
    )
    try:
        report = workflow.run()
    except Exception as error:
        print(f"capture failed: {error}")
        print(f"review artifacts: {run_dir}")
        return 1
    failures = [result for result in report["results"] if result["status"] != "passed"]
    print(f"captured {len(report['results']) - len(failures)}/{len(report['results'])} screens")
    print(f"review artifacts: {run_dir}")
    print(f"website-ready images: {workflow.output_dir}")
    if failures:
        for failure in failures:
            print(f"  {failure['id']}: {failure['error']}")
        return 1
    if args.all and len(report["results"]) != len(catalog):
        print(f"full capture did not produce exactly {len(catalog)} results")
        return 1
    if manual_output:
        try:
            export_screenshots(
                workflow.output_dir,
                manual_output,
                [str(result["filename"]) for result in report["results"]],
            )
        except ValueError as error:
            print(f"manual output failed: {error}")
            return 1
        report["manual_output_directory"] = str(manual_output)
        write_report(run_dir / "report.json", report)
        print(f"manual output: {manual_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
