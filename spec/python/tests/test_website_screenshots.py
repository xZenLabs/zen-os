import hashlib
import io
import json
import sqlite3
from pathlib import Path
from types import SimpleNamespace
from zipfile import ZipFile

import pytest
from PIL import Image

from website_screenshots import (
    BB_TYPE_RGB32,
    EXPECTED_IDS,
    READER_FOOTER_PRESETS,
    READER_SHOWCASE_PAGE,
    READER_SHOWCASE_PRESET,
    SHOWCASE_BACKGROUND,
    SHOWCASE_BOOK_COUNT,
    SHOWCASE_NAVBAR_STATES,
    BookRequest,
    ResolvedBook,
    Scenario,
    StagedBook,
    _cover_blob,
    _embedded_description,
    _embedded_keywords,
    _lua_merge_override,
    _seed_bookinfo,
    _seed_sidecars,
    _zen_config,
    audit_inventory,
    crop_from_bounds,
    export_screenshots,
    load_catalog,
    load_profile,
    prepare_artifact_directory,
    resolve_calibre_books,
    select_scenarios,
    sha256_file,
    stage_books,
    stage_showcase_background,
    stage_placeholder_texts,
    write_report,
)


def _calibre_fixture(root: Path) -> None:
    with sqlite3.connect(root / "metadata.db") as connection:
        connection.executescript("""
            CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, path TEXT);
            CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER, format TEXT, name TEXT);
            CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER, author INTEGER);
            CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_series_link (id INTEGER PRIMARY KEY, book INTEGER, series INTEGER);
            CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_tags_link (id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER);
            INSERT INTO books VALUES (7, 'Example Book', 'Author/Example Book (7)');
            INSERT INTO data VALUES (1, 7, 'AZW3', 'Example Book - Author');
            INSERT INTO data VALUES (2, 7, 'EPUB', 'Example Book - Author');
            INSERT INTO authors VALUES (2, 'Example Author');
            INSERT INTO books_authors_link VALUES (1, 7, 2);
            INSERT INTO series VALUES (3, 'Example Series');
            INSERT INTO books_series_link VALUES (1, 7, 3);
            INSERT INTO tags VALUES (4, 'Example Tag');
            INSERT INTO books_tags_link VALUES (1, 7, 4);
        """)
    folder = root / "Author" / "Example Book (7)"
    folder.mkdir(parents=True)
    folder.joinpath("Example Book - Author.epub").write_bytes(b"epub")
    folder.joinpath("Example Book - Author.azw3").write_bytes(b"azw3")


def _color_cover_epub(
    path: Path,
    description: str = "",
    subjects: tuple[str, ...] = (),
) -> None:
    cover = io.BytesIO()
    image = Image.new("RGB", (120, 160), (220, 40, 20))
    image.paste((20, 80, 230), (60, 0, 120, 160))
    image.save(cover, format="PNG")
    with ZipFile(path, "w") as archive:
        archive.writestr(
            "META-INF/container.xml",
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>',
        )
        archive.writestr(
            "OPS/package.opf",
            '<package xmlns="http://www.idpf.org/2007/opf">'
            '<metadata><meta name="cover" content="cover-image"/>'
            '<dc:description xmlns:dc="http://purl.org/dc/elements/1.1/">'
            + description
            + '</dc:description>'
            + "".join(
                '<dc:subject xmlns:dc="http://purl.org/dc/elements/1.1/">'
                + subject + '</dc:subject>'
                for subject in subjects
            )
            + '</metadata>'
            '<manifest><item id="cover-image" href="cover.png" '
            'media-type="image/png" properties="cover-image"/></manifest></package>',
        )
        archive.writestr("OPS/cover.png", cover.getvalue())


def test_catalog_is_the_canonical_24_image_inventory() -> None:
    catalog = load_catalog()
    assert len(catalog) == 24
    assert {scenario.id for scenario in catalog} == EXPECTED_IDS
    assert [scenario.id for scenario in catalog if scenario.id.startswith("page_browser")] == [
        "page_browser_grid", "page_browser_carousel"
    ]
    assert "update_available" not in {scenario.id for scenario in catalog}
    assert "opds" not in {scenario.id for scenario in catalog}
    assert "opds_context" not in {scenario.id for scenario in catalog}
    assert "quick_settings_launcher" not in {scenario.id for scenario in catalog}
    assert "zen_mode" not in {scenario.id for scenario in catalog}
    assert "navbar" not in {scenario.id for scenario in catalog}
    assert "lockdown_mode" not in {scenario.id for scenario in catalog}
    assert "reader_menu" not in {scenario.id for scenario in catalog}
    zen_home = next(scenario for scenario in catalog if scenario.id == "zen_home")
    assert zen_home.options["navbar"] == "zen_home_icons"
    library_covers = next(
        scenario for scenario in catalog if scenario.id == "library_covers_full"
    )
    assert library_covers.options["navbar"] == "regular"
    stats = next(scenario for scenario in catalog if scenario.id == "stats")
    assert stats.options["navbar"] == "library_home_text"
    assert SHOWCASE_NAVBAR_STATES["library_home_text"] == {
        "tab_order": ["books", "home"],
        "show_icons": False,
        "show_labels": True,
    }
    launcher = next(scenario for scenario in catalog if scenario.id == "launcher")
    assert launcher.options["background"] == "home_simple"
    assert launcher.options["navbar"] == "library_home_icons"
    quicksettings = next(scenario for scenario in catalog if scenario.id == "quicksettings")
    assert quicksettings.options["navbar"] == "library_home_icons"
    bookshelf = next(scenario for scenario in catalog if scenario.id == "home_bookshelf")
    assert bookshelf.options["navbar"] == "library_home_text"
    home_simple = next(scenario for scenario in catalog if scenario.id == "home_simple")
    assert home_simple.options["navbar"] == "text_only"
    library_list = next(scenario for scenario in catalog if scenario.id == "library_list_full")
    assert library_list.options["navbar"] == "icons_only"
    assert library_list.options["visible_books"] == [
        "Project Hail Mary: A Novel",
        "Never Split the Difference",
        "The Creative Habit",
        "Atomic Habits: An Easy and Proven Way to Build Good Habits and Break Bad Ones",
        "Clean Coder",
    ]
    context_menu = next(scenario for scenario in catalog if scenario.id == "context_menu")
    assert context_menu.options["navbar"] == "few_items"
    metadata_editor = next(
        scenario for scenario in catalog if scenario.id == "metadata_editor"
    )
    assert metadata_editor.action == "metadata_editor"
    assert metadata_editor.options["book_title"] == "Deep Work"
    assert metadata_editor.docs == ("docs/library.md",)
    launcher_add = next(
        scenario for scenario in catalog if scenario.id == "launcher_add_plugin_menu"
    )
    assert launcher_add.action == "launcher_add_plugin_menu"
    launcher_add_koreader = next(
        scenario for scenario in catalog if scenario.id == "launcher_add_koreader_menu"
    )
    assert launcher_add_koreader.action == "launcher_add_koreader_menu"
    controls_buttons = next(
        scenario for scenario in catalog if scenario.id == "controls_buttons_settings"
    )
    assert controls_buttons.action == "controls_buttons_settings"
    dictionary = next(
        scenario for scenario in catalog if scenario.id == "reader_dict"
    )
    assert dictionary.options["footer_preset"] == "pages_bar_percent"
    assert "hilight_menu" not in {scenario.id for scenario in catalog}
    navbar_buttons = next(
        scenario for scenario in catalog if scenario.id == "navbar_buttons_settings"
    )
    assert navbar_buttons.options["navbar"] == "navbar_settings"
    assert SHOWCASE_NAVBAR_STATES["zen_home_icons"] == {
        "tab_order": ["books", "authors", "series", "stats", "to_be_read", "home"],
        "show_icons": True,
        "show_labels": False,
    }
    assert (
        SHOWCASE_NAVBAR_STATES["zen_home_icons"]["tab_order"]
        == SHOWCASE_NAVBAR_STATES["text_only"]["tab_order"]
    )


def test_example_profile_fills_the_four_by_three_library_grid() -> None:
    profile = Path(__file__).resolve().parents[1] / "website_screenshot_books.example.json"
    _calibre_root, books, quote = load_profile(profile)
    assert SHOWCASE_BOOK_COUNT == 12
    assert len(books) == SHOWCASE_BOOK_COUNT
    assert quote == "The secret of getting ahead is getting started."
    authors = {book.expected_title: book.authors for book in books}
    assert authors["The Creative Habit"] == "Twyla Tharp"
    assert authors["Clean Coder"] == "Robert C Martin"


def test_capture_overrides_use_custom_library_bar_and_zen_reader_preset() -> None:
    config = _zen_config()
    assert config["features"]["zen_mode"] is True
    assert config["features"]["lockdown_mode"] is False
    assert config["quick_settings"]["button_order"] == [
        "wifi", "night", "rotate", "zen", "lockdown", "incognito",
        "usb", "search", "restart", "exit", "sleep",
    ]
    assert config["quick_settings"]["layout_version"] == 2
    assert config["quick_settings"]["rotate_action"] == "90"
    assert config["quick_settings"]["custom_buttons"] == []
    assert {
        key: config["quick_settings"]["show_buttons"][key]
        for key in (
            "wifi", "night", "zen", "lockdown", "incognito", "usb",
            "search", "restart", "exit", "sleep",
        )
    } == {
        "wifi": True,
        "night": True,
        "zen": True,
        "lockdown": False,
        "incognito": False,
        "usb": False,
        "search": False,
        "restart": True,
        "exit": False,
        "sleep": True,
    }
    assert config["status_bar"] == {
        "left_order": ["time"],
        "center_order": [],
        "right_order": ["wifi", "battery"],
        "time_12h": True,
        "hide_browser_bar": True,
    }
    assert config["navbar"] == {
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
    }
    assert config["reader_top_status_bar"] == {
        "left_order": ["book_title"],
        "center_order": [],
        "right_order": ["chapter"],
        "show_bottom_border": False,
        "bottom_border_progress": False,
    }
    assert config["mosaic_title_strip"] == {"show_title": False, "show_author": False}
    assert config["library_background"] == {
        "enabled": True,
        "path": str(SHOWCASE_BACKGROUND.resolve()),
    }
    assert config["_meta"]["reader_defaults_apply_on_next_open"] is True
    assert READER_SHOWCASE_PAGE == 10
    assert READER_SHOWCASE_PRESET == "(ZenOS) L/C/R: Chapter Time | Page | %"
    assert READER_FOOTER_PRESETS["pages_bar_percent"] == "(ZenOS) Pages | Bar | %"


def test_showcase_background_is_staged_inside_the_emulator_home(tmp_path: Path) -> None:
    destination = stage_showcase_background(tmp_path)

    assert destination == (tmp_path / SHOWCASE_BACKGROUND.name).resolve()
    assert destination.read_bytes() == SHOWCASE_BACKGROUND.read_bytes()
    with Image.open(destination) as image:
        assert image.format == "JPEG"
        assert image.size == (4494, 2493)


def test_showcase_statistics_uses_koreader_enable_key() -> None:
    source = Path(__file__).resolve().parents[1].joinpath(
        "website_screenshots.py").read_text(encoding="utf-8")
    assert '"statistics": {"is_enabled": True, "max_sec": 120}' in source


def test_lua_merge_marks_lists_as_replacements() -> None:
    overrides = _lua_merge_override({"status": {"center": []}, "enabled": True})
    assert overrides == {
        "status": {"center": {"__zen_replace": True, "value": []}},
        "enabled": True,
    }


def test_cover_blob_preserves_color_in_rgba_layout(tmp_path: Path, monkeypatch) -> None:
    epub = tmp_path / "color.epub"
    _color_cover_epub(epub)
    compressed_input: dict[str, bytes] = {}

    def fake_run(*_args, **kwargs):
        compressed_input["raw"] = kwargs["input"]
        return SimpleNamespace(stdout=b"compressed")

    monkeypatch.setattr("website_screenshots.shutil.which", lambda _name: "zstd")
    monkeypatch.setattr("website_screenshots.subprocess.run", fake_run)
    blob = _cover_blob(epub)
    assert blob is not None
    assert blob[:3] == (120, 160, "120x160")
    raw = compressed_input["raw"]
    assert len(raw) == 120 * 160 * 4
    assert set(raw[3::4]) == {255}
    assert tuple(raw[:4]) == (220, 40, 20, 255)
    midpoint = (60 * 4)
    assert tuple(raw[midpoint:midpoint + 4]) == (20, 80, 230, 255)
    assert any(red != green or green != blue for red, green, blue in zip(
        raw[0::4], raw[1::4], raw[2::4], strict=True,
    ))


def test_embedded_description_uses_epub_metadata(tmp_path: Path) -> None:
    epub = tmp_path / "description.epub"
    _color_cover_epub(epub, "The book's real description.")
    assert _embedded_description(epub) == "The book's real description."


def test_embedded_keywords_use_epub_subjects(tmp_path: Path) -> None:
    epub = tmp_path / "keywords.epub"
    _color_cover_epub(epub, subjects=("Productivity", "Design"))
    assert _embedded_keywords(epub) == "Productivity, Design"


def test_bookinfo_seed_marks_rgb_covers_complete(tmp_path: Path, monkeypatch) -> None:
    source = tmp_path / "source.epub"
    staged = tmp_path / "library" / "book.epub"
    staged.parent.mkdir()
    source.write_bytes(b"source")
    staged.write_bytes(b"staged")
    book = StagedBook(None, "Book", "Author", None, source, staged, "featured", "EPUB")
    monkeypatch.setattr(
        "website_screenshots._cover_blob",
        lambda _path: (2, 3, "2x3", b"compressed"),
    )
    ko_home = tmp_path / "ko-home"
    _seed_bookinfo(ko_home, [book])
    with sqlite3.connect(ko_home / "settings" / "bookinfo_cache.sqlite3") as connection:
        row = connection.execute(
            "SELECT in_progress, cover_bb_type, cover_bb_stride FROM bookinfo"
        ).fetchone()
        settings = dict(connection.execute("SELECT key, value FROM config"))
    assert row == (0, BB_TYPE_RGB32, 8)
    assert settings == {
        "filemanager_display_mode": "mosaic_image",
        "files_per_page": "5",
        "nb_cols_portrait": "4",
        "nb_rows_portrait": "3",
        "no_hint_description": "Y",
    }


def test_select_scenarios_preserves_catalog_order() -> None:
    catalog = load_catalog()
    selected = select_scenarios(
        catalog,
        ["reader", "zen_home", "page_browser_grid"],
        None,
        False,
    )
    assert [scenario.id for scenario in selected] == [
        "zen_home", "reader", "page_browser_grid"
    ]
    with pytest.raises(ValueError, match="unknown screen"):
        select_scenarios(catalog, ["nope"], None, False)


def test_calibre_resolution_verifies_title_and_prefers_epub(tmp_path: Path) -> None:
    _calibre_fixture(tmp_path)
    books = resolve_calibre_books(tmp_path, [
        BookRequest(7, "Example Book", None, "featured"),
    ])
    assert books[0].format == "EPUB"
    assert books[0].authors == "Example Author"
    assert books[0].keywords == "Example Tag"
    assert books[0].series == "Example Series"
    assert books[0].source.suffix == ".epub"
    with pytest.raises(ValueError, match="title mismatch"):
        resolve_calibre_books(tmp_path, [
            BookRequest(7, "Wrong Book", None, "featured"),
        ])


def test_safe_staging_copies_only_books_and_preserves_sources(tmp_path: Path) -> None:
    _calibre_fixture(tmp_path)
    source_folder = tmp_path / "Author" / "Example Book (7)"
    source_folder.joinpath("metadata.opf").write_text("sidecar", encoding="utf-8")
    source_folder.joinpath("cover.jpg").write_bytes(b"cover")
    books = resolve_calibre_books(tmp_path, [
        BookRequest(7, "Example Book", None, "featured"),
    ])
    before = sha256_file(books[0].source)
    destination = tmp_path / "stage"
    staged = stage_books(books, destination)
    assert [path.name for path in destination.iterdir()] == [staged[0].path.name]
    assert staged[0].path.read_bytes() == b"epub"
    assert sha256_file(books[0].source) == before


def test_reader_showcase_sidecar_has_no_seeded_bookmark(tmp_path: Path) -> None:
    reader_path = tmp_path / "Reader.epub"
    library_path = tmp_path / "Library.epub"
    books = [
        StagedBook(None, "Reader", "Author", None, reader_path, reader_path,
                   "reader", "EPUB"),
        StagedBook(None, "Library", "Author", None, library_path, library_path,
                   "library", "EPUB"),
    ]

    _seed_sidecars(books)

    reader_sidecar = reader_path.with_suffix(".sdr") / "metadata.epub.lua"
    library_sidecar = library_path.with_suffix(".sdr") / "metadata.epub.lua"
    reader_metadata = reader_sidecar.read_text(encoding="utf-8")
    assert '["bookmarks"]' not in reader_metadata
    assert hashlib.md5(str(reader_path).encode()).hexdigest() in reader_metadata
    assert '["bookmarks"]' in library_sidecar.read_text(encoding="utf-8")


def test_placeholder_texts_fill_the_second_library_page(tmp_path: Path) -> None:
    stage_placeholder_texts(tmp_path)
    placeholders = sorted(tmp_path.glob("*.txt"))
    assert [path.name for path in placeholders] == [
        f"{index:02d} Placeholder {index - SHOWCASE_BOOK_COUNT:02d}.txt"
        for index in range(SHOWCASE_BOOK_COUNT + 1, SHOWCASE_BOOK_COUNT * 2 + 1)
    ]
    assert all(
        path.read_text(encoding="utf-8") == "Placeholder for library pagination screenshots.\n"
        for path in placeholders
    )


def test_staging_access_times_preserve_profile_recent_order(tmp_path: Path) -> None:
    first = tmp_path / "first.epub"
    second = tmp_path / "second.epub"
    first.write_bytes(b"first")
    second.write_bytes(b"second")
    books = [
        ResolvedBook(None, "First", "Author", None, first, "featured", "EPUB"),
        ResolvedBook(None, "Second", "Author", None, second, "reader", "EPUB"),
    ]
    staged = stage_books(books, tmp_path / "stage")
    assert staged[0].path.stat().st_atime - staged[1].path.stat().st_atime == 600


def test_crop_bounds_create_a_valid_png(tmp_path: Path) -> None:
    raw = tmp_path / "raw.png"
    Image.new("RGB", (1272, 1696), "white").save(raw)
    crop = tmp_path / "crop.png"
    assert crop_from_bounds(raw, crop, {"x": 100, "y": 200, "w": 300, "h": 400}, 10) == (
        320,
        420,
    )
    with Image.open(crop) as image:
        assert image.size == (320, 420)


def test_report_generation_is_sorted_json_with_newline(tmp_path: Path) -> None:
    output = tmp_path / "report.json"
    write_report(output, {"z": 1, "a": {"passed": True}})
    assert output.read_text(encoding="utf-8").endswith("\n")
    assert json.loads(output.read_text(encoding="utf-8")) == {"a": {"passed": True}, "z": 1}


def test_artifact_directory_replaces_the_previous_capture(tmp_path: Path) -> None:
    artifacts = tmp_path / ".artifacts" / "screenshots"
    previous = artifacts / "raw" / "old.png"
    previous.parent.mkdir(parents=True)
    previous.write_bytes(b"old capture")

    assert prepare_artifact_directory(artifacts) == artifacts.resolve()
    assert not artifacts.exists()


def test_manual_export_copies_pngs_only_into_an_empty_folder(tmp_path: Path) -> None:
    source = tmp_path / "source"
    source.mkdir()
    Image.new("RGB", (10, 10), "white").save(source / "first.png")
    Image.new("RGB", (20, 20), "black").save(source / "second.png")
    destination = tmp_path / "manual"
    assert export_screenshots(source, destination, ["second.png", "first.png"]) == destination
    assert sorted(path.name for path in destination.iterdir()) == ["first.png", "second.png"]
    with pytest.raises(ValueError, match="must be empty"):
        export_screenshots(source, destination, ["first.png"])


def test_docs_and_gallery_audit_allows_current_page_browser_views(tmp_path: Path) -> None:
    docs = tmp_path / "docs"
    docs.mkdir()
    docs.joinpath("reader.md").write_text(
        "![Grid](/images/zen_os/page_browser_grid.png)\n"
        "![Carousel](/images/zen_os/page_browser_carousel.png)\n"
        "![Install](/images/zen_os/plugins_folder.png)\n"
        "![OPDS](/images/zen_os/opds.png)\n",
        encoding="utf-8",
    )
    website = tmp_path / "ZenOsPage.tsx"
    website.write_text("'/images/zen_os/page_browser.png'", encoding="utf-8")
    audit = audit_inventory(load_catalog(), docs, website)
    assert audit["ok"] is True
    assert audit["errors"] == []
    assert "plugins_folder.png" in audit["excluded_non_emulator_assets"]
    assert audit["excluded_manual_screenshot_assets"] == ["opds.png"]
    assert audit["warnings"] == [
        "website carousel still contains retired page_browser.png; remove it when the website source is next updated"
    ]


def test_invalid_crop_declaration_is_rejected() -> None:
    catalog = load_catalog()
    first = catalog[0]
    invalid = Scenario(
        first.id,
        first.group,
        first.session,
        first.action,
        first.docs,
        {"crop": {"target": "coordinates"}},
    )
    from website_screenshots import validate_catalog

    with pytest.raises(ValueError, match="invalid crop"):
        validate_catalog([invalid, *catalog[1:]])
