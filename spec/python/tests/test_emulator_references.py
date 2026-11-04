import io
import itertools
import math
import os
import sys
import tempfile
import time
import zipfile
from pathlib import Path

import pytest
from PIL import Image, ImageChops, ImageDraw

from zen_driver import ZenDriver, launch, stop, wait_for_socket
from test_emulator_reader_tools import _write_reader_epub


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires the KOReader emulator"
)


def _capture(driver, name):
    output = Path(__file__).resolve().parents[2] / ".artifacts" / "references" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    driver.screenshot(output)
    return output


def _write_book(path: Path) -> None:
    if path.suffix != ".epub":
        pages = []
        for number in range(1, 5):
            page = Image.new("RGB", (600, 800), "white")
            ImageDraw.Draw(page).rectangle((0, 0, 599, 799), outline="black", width=2)
            ImageDraw.Draw(page).text((60, 100), f"Reference page {number}", fill="black")
            pages.append(page)
        if path.suffix == ".pdf":
            pages[0].save(path, save_all=True, append_images=pages[1:])
        else:
            with zipfile.ZipFile(path, "w") as archive:
                for index, page in enumerate(pages):
                    output = io.BytesIO()
                    page.save(output, format="PNG")
                    archive.writestr(f"{index:02d}.png", output.getvalue())
        return
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", """<container version="1.0"
          xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
          <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles></container>""")
        archive.writestr("content.opf", """<package version="3.0" unique-identifier="id"
          xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">zen-references</dc:identifier><dc:title>References</dc:title>
          <dc:language>en</dc:language></metadata><manifest>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
          <item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/>
          </manifest><spine><itemref idref="chapter"/><itemref idref="notes"/></spine></package>""")
        archive.writestr("chapter.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"
          xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Reading</title></head><body>
          <h1>Reference tests</h1><p>Short note<a epub:type="noteref" id="ref1" href="notes.xhtml#n1">1</a>.
          Long note<a epub:type="noteref" id="ref2" href="notes.xhtml#n2">2</a>.</p>"""
          + "<p>Keep this reading position while looking at references.</p>" * 150
          + "<h1>Second chapter</h1>"
          + "<p>Keep this reading position while looking at references.</p>" * 150
          + "</body></html>")
        archive.writestr("notes.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"
          xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Notes</title></head><body>
          <aside epub:type="footnote" id="n1"><p>Short test footnote.
          <a href="chapter.xhtml#ref1">Return</a></p></aside>
          <aside epub:type="footnote" id="n2">"""
          + "<p>This longer footnote has no backlink and must remain readable. </p>" * 100
          + "</aside></body></html>")


def _wait_reader(driver: ZenDriver) -> None:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if driver.command("reader_state").get("reader", {}).get("open"):
            return
        time.sleep(0.1)
    raise AssertionError("reader did not open")


def _ref(driver: ZenDriver, action="state", **params):
    result = driver.command("reference_action", action=action, **params)
    assert result["ok"], result
    state = result["references"]
    if action == "state" and state.get("return_button", {}).get("visible") and "bounds" not in state["return_button"]:
        deadline = time.monotonic() + 2
        while "bounds" not in state["return_button"] and time.monotonic() < deadline:
            time.sleep(0.05)
            state = driver.command("reference_action", action="state")["references"]
    if action in {"confirm", "expand", "gesture", "goto", "browser_jump", "toc_jump", "return", "turn", "expire_return", "suspend"} or (
        action != "state" and state.get("drawer") and "bounds" not in state["drawer"]
    ):
        return _ref(driver)
    return state


def _navigate(driver: ZenDriver, action="expand", **params):
    prompt = _ref(driver, action, **params)
    assert prompt["confirm_text"]
    assert prompt.get("drawer") and prompt["history"] == _ref(driver, "confirm", cancel=True)["history"]
    assert _ref(driver)["page"] == prompt["page"]
    _ref(driver, action, **params)
    return _ref(driver, "confirm")


def _browser(driver: ZenDriver):
    assert driver.command("activate_reader_control", name="page_browser")["activated"]
    return _ref(driver)


def _assert_pin_padding(state):
    box = state["pin_footer"]
    scale = min(state["screen"]["w"], state["screen"]["h"]) / 600
    assert state["pin_icon_bounds"]["w"] == state["pin_icon_bounds"]["h"] == math.ceil(16 * scale)
    for key in ("pin_icon_bounds", "pin_count_bounds"):
        content = state[key]
        assert content["x"] - box["x"] >= math.ceil(8 * scale), key
        assert box["x"] + box["w"] - content["x"] - content["w"] >= math.ceil(8 * scale), key
        assert content["y"] - box["y"] >= math.ceil(scale), key
        assert box["y"] + box["h"] - content["y"] - content["h"] >= math.ceil(scale), key
    assert 0 <= box["y"] < box["y"] + box["h"] <= state["screen"]["h"]


def _assert_pin_alignment(driver, state, name):
    image = Image.open(_capture(driver, name)).convert("RGB")
    centers = {}
    for key in ("pin_icon_bounds", "pin_count_bounds", "footer_text"):
        bounds = state[key]
        crop = image.crop((bounds["x"], bounds["y"], bounds["x"] + bounds["w"], bounds["y"] + bounds["h"]))
        ink = ImageChops.difference(crop, Image.new("RGB", crop.size, image.getpixel((0, 0)))).convert("L")
        pixels = ink.point(lambda value: 255 if value > 30 else 0).getbbox()
        assert pixels, key
        centers[key] = bounds["y"] + (pixels[1] + pixels[3]) / 2
    assert abs(centers["pin_icon_bounds"] - centers["pin_count_bounds"]) <= 1
    assert abs(centers["pin_icon_bounds"] - centers["footer_text"]) <= 2


def _assert_pin_header_padding(state):
    drawer = state["drawer"]
    assert not drawer.get("control_radius") and not drawer.get("dots_background")
    bounds, menu, close = (drawer[key] for key in ("bounds", "menu", "close"))
    right = min(state["screen"]["w"], bounds["x"] + bounds["w"])
    assert drawer["close_icon"].endswith("/chevron.up.svg")
    label = drawer["page_label"]
    assert drawer["page_label_text"].endswith(str(drawer["page"]))
    assert drawer["page_icon"].endswith("/pin.svg")
    assert drawer["page_icon_first"]
    scale = min(state["screen"].values()) / 600
    padding = math.ceil(4 * scale)
    assert label["x"] + padding == drawer["page_icon_bounds"]["x"]
    assert drawer["page_label_content_width"] + 2 * padding == label["w"]
    assert label["x"] + label["w"] + (math.ceil(8 * scale) if drawer["full_image"] else 0) == menu["x"]
    assert label["y"] == menu["y"] == close["y"] and label["h"] == menu["h"] == close["h"]
    assert drawer["content"]["y"] - label["y"] - label["h"] == math.ceil(8 * scale)
    assert right - close["x"] - close["w"] == math.ceil(8 * scale) + math.ceil(2 * scale)
    _assert_pin_header_icon_padding(state)


def _assert_pin_header_icon_padding(state):
    drawer = state["drawer"]
    scale = min(state["screen"].values()) / 600
    for name in ("menu", "zoom", "zoom_in", "zoom_out", "close"):
        if not drawer.get(name):
            continue
        padding = math.ceil((2 if name == "menu" else 4) * scale)
        button, icon = drawer[name], drawer[name + "_icon_bounds"]
        assert icon["x"] == button["x"] + padding
        assert icon["y"] == button["y"] + padding
        assert icon["w"] == button["w"] - 2 * padding
        assert icon["h"] == button["h"] - 2 * padding


def _assert_action_dividers(driver, state, name):
    for action in state["actions"]:
        assert action["id"] == "reference:back"
        assert action["icon"].endswith("/icons/return.svg")
        assert action["icon_first"]
        assert action["content_width"] <= action["bounds"]["w"]
    image = Image.open(_capture(driver, name)).convert("RGB")
    line_y = state["actions"][0]["bounds"]["y"] - 1
    line_color = image.getpixel((0, line_y))
    assert line_color != image.getpixel((0, line_y + 2))
    assert all(image.getpixel((x, line_y)) == line_color for x in range(state["screen"]["w"]))
    for left, right in zip(state["actions"], state["actions"][1:]):
        a, b = left["bounds"], right["bounds"]
        divider_x = a["x"] + a["w"]
        assert divider_x < b["x"]
        assert image.getpixel((divider_x, a["y"] + a["h"] // 2)) == line_color


@pytest.mark.parametrize("stylesheet", ["default", "linked", "inline", "spaced"])
def test_pinned_text_preserves_paragraph_indentation_and_spacing(stylesheet):
    with tempfile.TemporaryDirectory(prefix="zen-pin-indent-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "indents.epub"
        _write_book(book)
        with zipfile.ZipFile(book) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        indent = {"default": 1.2, "linked": 2, "inline": 3, "spaced": 2}[stylesheet]
        margin = "margin-top: 0.5em; margin-bottom: 0.5em;" if stylesheet == "spaced" else ""
        css = f".chapter p {{ text-indent: {indent}em; {margin} }} .chapter p.noindent {{ text-indent: 0; }}"
        styles = ""
        if stylesheet in {"linked", "spaced"}:
            files["book.css"] = css.encode()
            files["content.opf"] = files["content.opf"].replace(b"<manifest>", b"""<manifest>
              <item id="styles" href="book.css" media-type="text/css"/>""")
            styles = '<link rel="stylesheet" href="book.css"/>'
        elif stylesheet == "inline":
            styles = f"<style>{css}</style>"
        first_style = 'style="text-indent:0"' if stylesheet == "default" else 'class="noindent"'
        files["chapter.xhtml"] = (f"""<html xmlns="http://www.w3.org/1999/xhtml"><head>{styles}</head>
          <body><div class="chapter"><p {first_style}>Paragraph opening.</p>
          <p>Paragraph indented.</p><p style="text-indent:0">Paragraph reset.</p>
          <h2 style="font-size:1em;font-weight:normal">Paragraph heading.</h2>
          <p>Paragraph after heading.</p>"""
          + "<p>Additional reading text.</p>" * 100 + "</div></body></html>").encode()
        with zipfile.ZipFile(book, "w") as archive:
            for name, content in files.items():
                archive.writestr(name, content)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            start = _ref(driver)
            book_image = Image.open(_capture(driver, f"pin-spacing-book-{stylesheet}.png")).convert("L")
            _ref(driver, "pin", page=1)
            opened = _ref(driver, "open_pin")
            drawer = opened["drawer"]
            assert not drawer["image"]
            assert drawer["font_size"] == opened["reader_font_size"]
            assert opened["location"] == start["location"] and opened["history"] == start["history"]
            image = Image.open(_capture(driver, f"pin-indent-{stylesheet}.png")).convert("L")
            content = drawer["content"]
            crop = image.crop((content["x"], content["y"],
                               drawer["scroll_bar"]["x"] - 1, content["y"] + content["h"]))
            def ink_lines(image):
                lines = []
                ink = False
                for y in range(image.height):
                    bounds = image.crop((0, y, image.width, y + 1)).point(lambda pixel: 255 if pixel < 128 else 0).getbbox()
                    if bounds and not ink:
                        lines.append([bounds[0], y])
                    elif bounds:
                        lines[-1][0] = min(lines[-1][0], bounds[0])
                    ink = bounds is not None
                return lines

            lines = ink_lines(crop)
            header = start.get("header_bounds") or {"y": 0, "h": 0}
            book_lines = ink_lines(book_image.crop((0, header["y"] + header["h"], book_image.width, book_image.height)))
            assert len(lines) >= 5 and len(book_lines) >= 5
            assert lines[1][0] - lines[0][0] == pytest.approx(indent * drawer["font_size"], abs=2)
            assert abs(lines[2][0] - lines[0][0]) <= 2
            for index in range(1, 5):
                assert lines[index][1] - lines[index - 1][1] == pytest.approx(
                    book_lines[index][1] - book_lines[index - 1][1], abs=2)
        finally:
            stop(process)


@pytest.mark.parametrize("landscape", [False, True])
def test_reference_popups_preserve_the_reader_header(landscape):
    with tempfile.TemporaryDirectory(prefix="zen-reference-header-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "header.epub"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            if landscape:
                _ref(driver, "resize", mode=1)
            _ref(driver, "header")
            original = _ref(driver, "paint")
            header = original["header_left"]
            area = (header["x"], header["y"], header["x"] + header["w"], header["y"] + header["h"])
            orientation = "landscape" if landscape else "portrait"
            before = Image.open(_capture(driver, f"header-{orientation}-before.png")).convert("RGB").crop(area)
            assert before.convert("L").getextrema()[0] < 200
            for reference in ("footnote", "open_pin"):
                if reference == "open_pin":
                    _ref(driver, "pin", page=1)
                    pinned = _ref(driver, "pin", page=original["page_count"] - 1)
                    assert len(pinned["pins"]) == 2
                page = Image.open(_capture(driver, f"shadow-{orientation}-{reference}-before.png")).convert("RGB")
                _ref(driver, reference, index=2)
                opened = _ref(driver, "paint")
                assert opened["drawer"] and opened["location"] == original["location"]
                bounds = opened["drawer"]["bounds"]
                if reference == "footnote":
                    margin = math.ceil(8 * min(opened["screen"].values()) / 600)
                    available = opened["screen"]["w"] // (2 if landscape else 1)
                    assert bounds["w"] == available - 2 * margin
                    assert bounds["x"] > 0
                    assert bounds["x"] + bounds["w"] == opened["screen"]["w"] - margin
                after = Image.open(_capture(driver, f"header-{orientation}-{reference}.png")).convert("RGB")
                assert ImageChops.difference(before, after.crop(area)).getbbox() is None
                shadow = math.ceil(4 * min(opened["screen"].values()) / 600)
                middle = bounds["y"] + bounds["h"] // 2
                strip = (bounds["x"] - shadow, middle, bounds["x"], middle + 1)
                expected = page.crop(strip).point(lambda value: round(value * 0.7))
                assert ImageChops.difference(page.crop(strip), after.crop(strip)).getbbox()
                assert max(ImageChops.difference(expected, after.crop(strip)).convert("L").getextrema()) <= 1
                outside = (bounds["x"] - shadow - 1, middle)
                assert after.getpixel(outside) == page.getpixel(outside)
                for turn in range(3):
                    previous = _ref(driver)
                    changed = _ref(driver, "next")
                    if reference == "footnote":
                        assert changed["drawer"]["ratio"] > previous["drawer"]["ratio"]
                    else:
                        assert changed["drawer"]["page"] != previous["drawer"]["page"]
                    repainted = Image.open(_capture(driver, f"shadow-{orientation}-{reference}-turn-{turn}.png")).convert("RGB")
                    assert ImageChops.difference(after.crop(strip), repainted.crop(strip)).getbbox() is None
                _ref(driver, "close")
                restored = Image.open(_capture(driver, f"shadow-{orientation}-{reference}-closed.png")).convert("RGB")
                assert ImageChops.difference(page.crop(strip), restored.crop(strip)).getbbox() is None
            _ref(driver, "goto", page=original["page_count"] - 1)
            before = Image.open(_capture(driver, f"header-{orientation}-back-before.png")).convert("RGB").crop(area)
            _ref(driver, "open_pin")
            _ref(driver, "paint")
            after = Image.open(_capture(driver, f"header-{orientation}-back-popup.png")).convert("RGB").crop(area)
            assert ImageChops.difference(before, after).getbbox() is None
        finally:
            stop(process)


@pytest.mark.parametrize("landscape", [False, True])
def test_top_menu_gestures_over_pins_and_page_browser_status_bar(landscape):
    with tempfile.TemporaryDirectory(prefix="zen-reference-menu-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "menu.epub"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            if landscape:
                _ref(driver, "resize", mode=1)
            original = _ref(driver, "pin", page=3)
            for gesture, activation, opens in (
                ("tap", "tap", True), ("tap", "swipe_tap", True),
                ("swipe", "swipe", True), ("swipe", "swipe_tap", True),
                ("swipe", "tap", False), ("tap", "swipe", False),
            ):
                _ref(driver, "open_pin")
                result = _ref(driver, "top_menu", gesture=gesture, activation=activation)
                assert result["top_menu_open"] is opens, (gesture, activation)
                assert result["location"] == original["location"]
                assert result["history"] == original["history"]
                if opens:
                    assert result.get("drawer")
                if result.get("drawer"):
                    _ref(driver, "close")
            _browser(driver)
            for tab in ("pages", "controls", "bookmarks", "toc"):
                assert driver.command("activate_reader_control", name=f"page_browser_{tab}")["activated"]
                for activation in ("tap", "swipe_tap", "swipe"):
                    result = _ref(driver, "top_menu", gesture="tap", activation=activation)
                    assert result["top_menu_open"] is (activation != "swipe"), (tab, activation)
                    assert result["browser_open"]
                    assert result["location"] == original["location"]
                    assert result["history"] == original["history"]
        finally:
            stop(process)


@pytest.mark.parametrize("format", ["epub", "pdf", "cbz"])
def test_return_button_tracks_jumps_without_tracking_page_turns(format):
    with tempfile.TemporaryDirectory(prefix="zen-return-button-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / f"return.{format}"
        _write_book(book)
        socket = root / "driver.sock"
        config = ("return {updater={update_auto_check=false},features={reader_status_bar_margins=%s}}"
                  % ("false" if format == "cbz" else "true"))
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library,
                         zen_config_source=config,
                         language="fr" if format == "epub" else "en")
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            _ref(driver, "header")
            original = _ref(driver)
            assert not original["return_button"]["visible"]
            assert original.get("header_left")
            assert not _ref(driver, "turn")["return_button"]["visible"]
            _ref(driver, "jump", page=1)
            _browser(driver)
            preview = _ref(driver, "preview", page=3)
            assert preview["page"] == 1 and not preview["return_button"]["visible"]
            jumped = _ref(driver, "browser_jump", page=3)
            button = jumped["return_button"]
            assert button["visible"] and button["duration"] == 10
            assert button["text"] == ("Retour à la page 1" if format == "epub" else "Return to page 1")
            assert button["bounds"]["x"] == jumped["footer_left_margin"]
            assert jumped["screen"]["h"] / 2 < button["bounds"]["y"] < jumped["screen"]["h"]
            assert button["bounds"]["y"] + button["bounds"]["h"] > jumped["screen"]["h"]
            assert button["bounds"]["w"] < jumped["screen"]["w"] / 2
            assert jumped.get("header_left")
            painted = _ref(driver, "paint")["return_button"]
            image = Image.open(_capture(driver, f"return-{format}.png")).convert("RGB")
            centers = []
            for key in ("icon_bounds", "text_bounds"):
                bounds = painted[key]
                assert bounds["y"] + bounds["h"] <= jumped["screen"]["h"]
                crop = image.crop((bounds["x"], bounds["y"], bounds["x"] + bounds["w"], bounds["y"] + bounds["h"]))
                ink = ImageChops.difference(crop, Image.new("RGB", crop.size, crop.getpixel((0, 0)))).convert("L")
                pixels = ink.point(lambda value: 255 if value > 30 else 0).getbbox()
                assert pixels, key
                centers.append(bounds["y"] + (pixels[1] + pixels[3]) / 2)
            assert abs(centers[0] - centers[1]) <= 1
            _ref(driver, "header_refresh")
            assert _ref(driver)["return_button"]["timer"] == button["timer"]
            turned = _ref(driver, "turn", step=-1)
            assert turned["return_button"]["timer"] == button["timer"]
            assert turned["history"] == jumped["history"]
            returned = _ref(driver, "return")
            assert returned["page"] == 1 and not returned["return_button"]["visible"]
            assert returned.get("header_left")
            assert not returned["browser_open"]
            jumped = _ref(driver, "goto", page=3)
            dismissed = _ref(driver, "return", gesture="swipe", direction="south")
            assert not dismissed["return_button"]["visible"] and not dismissed["return_button"].get("timer")
            assert dismissed["page"] == jumped["page"] and dismissed["history"] == jumped["history"]
            _browser(driver)
            assert _ref(driver, "page_action", id="back")["page"] == 1
            _ref(driver, "pin", page=3)
            pin = _ref(driver, "open_pin")
            assert not pin["return_button"]["visible"]
            expanded = _navigate(driver)
            assert expanded["return_button"]["visible"]
            same_pin = _ref(driver, "open_pin")
            no_op = _ref(driver, "check_pin_navigation")
            assert no_op["navigation_updates"] == 0
            assert no_op["drawer"]["bounds"] == same_pin["drawer"]["bounds"]
            assert no_op["page"] == same_pin["page"] and no_op["history"] == same_pin["history"]
            assert no_op["return_button"]["timer"] == same_pin["return_button"]["timer"]
            _ref(driver, "close")
            expired = _ref(driver, "expire_return")
            assert not expired["return_button"]["visible"]
            _browser(driver)
            assert _ref(driver, "page_action", id="back")["page"] == 1
            if format == "epub":
                toc = _ref(driver, "toc_jump")
                assert toc["page"] > 1 and toc["return_button"]["visible"]
                _ref(driver, "return")
                _ref(driver, "footnote", index=2)
                assert not _ref(driver)["return_button"]["visible"]
                assert _navigate(driver)["return_button"]["visible"]
                _ref(driver, "return")
            _ref(driver, "goto", page=3)
            assert not _ref(driver, "suspend")["return_button"]["visible"]
            _ref(driver, "goto", page=original["page_count"] - 1 if format == "epub" else 2)
            assert _ref(driver)["return_button"]["visible"]
            disabled = _ref(driver, "enabled", enabled=False)
            assert not disabled["return_button"]["visible"] and not disabled["return_button"].get("timer")
            _ref(driver, "close_book")
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            assert not _ref(driver)["return_button"]["visible"]
        finally:
            stop(process)


@pytest.mark.parametrize("format", ["epub", "pdf", "cbz"])
def test_return_tab_overlays_footer_without_changing_items(format):
    with tempfile.TemporaryDirectory(prefix="zen-return-footer-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / f"footer.{format}"
        _write_book(book)
        socket = root / "driver.sock"
        config = """return {
            updater = { update_auto_check = false },
            _meta = { reader_footer_hide_cbz_default_migrated = true },
            reader_footer = { hide_in_cbz = false },
        }"""
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library,
                         zen_config_source=config)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            _ref(driver, "footer_enabled", enabled=True)
            for preset in (2, 6):
                _ref(driver, "pin_preset", index=preset)
                _ref(driver, "jump", page=1)
                baseline = _ref(driver, "paint")
                assert baseline["footer_visible"]
                bounds = baseline["footer_bounds"]
                area = (0, bounds["y"], baseline["screen"]["w"], baseline["screen"]["h"])
                expected = Image.open(_capture(driver, f"footer-{format}-{preset}-before.png")).convert("RGB").crop(area)
                assert expected.convert("L").getextrema()[0] < 200
                covered = _ref(driver, "goto", page=3)
                assert covered["return_button"]["visible"]
                assert covered["footer_order"] == baseline["footer_order"]
                assert covered.get("footer_left_text") or covered["footer_label"].strip()
                returned = _ref(driver, "return")
                assert returned["page"] == baseline["page"] and not returned["return_button"]["visible"]
                after = Image.open(_capture(driver, f"footer-{format}-{preset}-returned.png")).convert("RGB").crop(area)
                assert ImageChops.difference(expected, after).getbbox() is None
                _ref(driver, "jump", page=3)
                covered = _ref(driver, "goto", page=1)
                assert covered["return_button"]["visible"]
                assert covered["footer_label"] == baseline["footer_label"]
                assert covered.get("footer_left_text") == baseline.get("footer_left_text")
                expired = _ref(driver, "expire_return")
                assert not expired["return_button"]["visible"]
                assert expired["footer_order"] == baseline["footer_order"]
                assert expired["footer_bounds"] == baseline["footer_bounds"]
                after = Image.open(_capture(driver, f"footer-{format}-{preset}-expired.png")).convert("RGB").crop(area)
                assert ImageChops.difference(expected, after).getbbox() is None
        finally:
            stop(process)


@pytest.mark.parametrize("format,use_pack", [("epub", False), ("pdf", False), ("cbz", False), ("pdf", True)])
def test_pin_drawer_preserves_reading_and_page_actions(format, use_pack):
    with tempfile.TemporaryDirectory(prefix="zen-references-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / f"references.{format}"
        _write_book(book)
        home = root / "home"
        pack = home / "icons" / "zen" / "pins"
        if use_pack:
            pack.mkdir(parents=True)
            (pack / "pack.json").write_text('{"schema_version":1,"id":"pins","name":"Pins"}')
            (pack / "pin.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">'
                '<circle cx="12" cy="12" r="8" fill="black"/></svg>'
            )
        config = 'return {features={custom_icons_enabled=true},custom_icons={active_pack="pins"}}' if use_pack else None
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library, zen_config_source=config)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            start = _ref(driver)
            pinned = _ref(driver, "pin", page=3)
            pin = pinned["pin"]
            assert pin and pinned["annotations"] == start["annotations"]
            assert pinned["pin_anchor"] == (pinned["requested_anchor"] if format == "epub" else 3)
            single = _ref(driver, "open_pin")
            if use_pack:
                assert Path(single["drawer"]["page_icon"]).resolve() == (pack / "pin.svg").resolve()
            assert single["double_tap_disabled"]
            _assert_pin_header_padding(single)
            assert not single["drawer"].get("pager")
            assert not single["drawer"].get("pager_left")
            assert not single["drawer"].get("pager_right")
            scale = min(single["screen"].values()) / 600
            label, content = (single["drawer"][key] for key in ("page_label", "content"))
            assert content["y"] == label["y"] + label["h"] + math.ceil(8 * scale)
            assert single["screen"]["h"] - content["y"] - content["h"] == math.ceil(4 * scale)
            _capture(driver, f"{format}-single-pin.png")
            assert _ref(driver, "previous")["drawer"]["page"] == pin
            assert _ref(driver, "next")["drawer"]["page"] == pin
            _ref(driver, "close")
            second_pin = _ref(driver, "pin", page=6 if format == "epub" else 4)
            opened = _ref(driver, "open_pin")
            _assert_pin_header_padding(opened)
            assert opened["drawer"]["content"]["h"] + math.ceil(32 * scale) == content["h"]
            assert opened["drawer"]["page"] == second_pin["pins"][0]["page"]  # Newest pin on top, opened first.
            assert opened["page"] == start["page"] and opened["history"] == start["history"]
            _capture(driver, f"{format}-drawer.png")
            pin = second_pin["pins"][1]["page"]
            assert _ref(driver, "next")["drawer"]["page"] == pin
            _ref(driver, "zoom", factor=1.25)
            _ref(driver, "close")
            assert _ref(driver, "open_pin")["drawer"]["page"] == pin
            expanded = _navigate(driver)
            assert expanded["page"] == pin and expanded["history"] == start["history"] + 1
            _browser(driver)
            for mode in ("single", "carousel", "grid"):
                assert driver.command("activate_reader_control", name=f"page_browser_{mode}")["activated"]
                state = _ref(driver)
                assert [action["id"] for action in state["actions"]] == ["reference:back"]
                first = state["actions"][0]["bounds"]
                preview = state["preview_bounds"]
                assert first["y"] >= preview["y"] + preview["h"] - 2
                assert state["page"] == pin and state["history"] == expanded["history"]
                _assert_action_dividers(driver, state, f"{format}-actions-{mode}.png")
            _capture(driver, f"{format}-actions.png")
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            state = _ref(driver)
            assert not state["actions"]
            scale = min(state["screen"]["w"], state["screen"]["h"]) / 600
            assert state["panel_height"] == min(math.ceil(226 * scale), state["screen"]["h"] * 0.45)
            assert driver.command("activate_reader_control", name="page_browser_pages")["activated"]
            returned = _ref(driver, "page_action", id="back")
            assert not returned["browser_open"] and returned["page"] == start["page"]
            _browser(driver)
            assert all(action["id"] != "reference:pinned" for action in _ref(driver)["actions"])
            assert driver.command("page_browser_key", key="Back")["handled"]
            resumed = _ref(driver, "pin_control", target="footer")
            assert resumed["drawer"]["page"] == pin
            _ref(driver, "close")
            _ref(driver, "close_book")
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            assert _ref(driver)["pin_anchor"] == second_pin["pin_anchor"]  # Native pin mirrors the top one.
        finally:
            stop(process)


def test_footnote_drawer_reopens_and_returns_after_expansion():
    with tempfile.TemporaryDirectory(prefix="zen-footnotes-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "footnotes.epub"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            _ref(driver, "pin", page=3)
            start = _ref(driver)
            short = _ref(driver, "footnote", index=1)
            assert short["drawer"]["footnote"] and short["last_footnote"]
            assert short["page"] == start["page"] and short["history"] == start["history"]
            assert short["drawer"]["content"]["h"] == math.ceil(2 * short["drawer"]["font_size"] * 1.3)
            assert short["drawer"]["bounds"]["h"] < math.ceil(short["screen"]["h"] * 0.2)
            _capture(driver, "footnote-short.png")
            _ref(driver, "close")
            long = _ref(driver, "footnote", index=2)
            assert long["drawer"]["bounds"]["h"] > short["drawer"]["bounds"]["h"]
            scrolled = _ref(driver, "scroll", ratio=0.6)
            _capture(driver, "footnote-long.png")
            _ref(driver, "close")
            _browser(driver)
            actions = _ref(driver)["actions"]
            assert not actions
            assert driver.command("page_browser_key", key="Back")["handled"]
            reopened = _ref(driver, "open_note")
            assert reopened["drawer"]["ratio"] == pytest.approx(scrolled["drawer"]["ratio"])
            assert not reopened["browser_open"] and reopened["location"] == start["location"]
            expanded = _navigate(driver, "gesture", target="body")
            assert not expanded.get("drawer") and expanded["page"] != start["page"]
            assert expanded["history"] == start["history"] + 1
            assert expanded["return_button"]["visible"]
            assert expanded["return_button"]["text"] == f'Return to page {start["page"]}'
            actions = _browser(driver)["actions"]
            assert actions[0]["id"] == "reference:back"
            assert actions[0]["text"] == expanded["return_button"]["text"]
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            assert not _ref(driver)["actions"]
            assert driver.command("activate_reader_control", name="page_browser_pages")["activated"]
            assert _ref(driver)["actions"] == actions
            returned = _ref(driver, "page_action", id="back")
            assert returned["page"] == start["page"]
            _ref(driver, "open_note")
            _ref(driver, "gesture", target="body")
            assert _ref(driver, "return")["page"] == start["page"]
            _ref(driver, "enabled", enabled=False)
            _browser(driver)
            assert not _ref(driver)["actions"]
        finally:
            stop(process)


@pytest.mark.parametrize("night", [False, True])
def test_reference_popup_defaults_theme_outline_and_gestures(night):
    with tempfile.TemporaryDirectory(prefix="zen-reference-popup-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "popup.epub"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            start = _ref(driver)
            assert start["popup_enabled"] and start["book_font"]
            default = _ref(driver, "footnote")
            assert default["double_tap_disabled"]
            assert default["drawer"]["font_size"] == default["reader_font_size"]
            assert "KOReaderFootnoteFont" in default["drawer"]["css"]
            assert default["drawer"]["radius"] > 0 and not default["drawer"]["grabber"]
            assert default["drawer"]["border"] > 0
            closed = _ref(driver, "gesture", target="outside")
            assert not closed.get("drawer") and closed["history"] == start["history"]
            assert closed["location"] == start["location"]

            assert driver.command("reader_controls", action="setting", name="font_size", value=26)["ok"]
            assert driver.command("reader_controls", action="setting", name="font_face", value="Noto Serif")["ok"]
            assert driver.command("reader_controls", action="theme", theme={
                "enabled": True,
                "light_mode": {"text": "#3f3524", "background": "#f3ead2"},
                "dark_mode": {"text": "#dcdccc", "background": "#1f1f1f"},
            })["ok"]
            if night:
                _ref(driver, "night")
            current = _ref(driver)
            themed = _ref(driver, "footnote", index=2)
            popup = themed["drawer"]
            # UI colors are pre-inverted before the screen's night-mode inversion.
            assert popup["background"] == ([224, 224, 224] if night else [243, 234, 210])
            assert popup["foreground"] == ([35, 35, 51] if night else [63, 53, 36])
            assert popup["font_size"] == themed["reader_font_size"] and themed["reader_font"] == "Noto Serif"
            assert popup["font_size"] != default["drawer"]["font_size"]
            assert "NotoSerif" in popup["css"].replace("-", "").replace(" ", "")
            assert "@page { background-color:" in popup["css"]
            image = Image.open(_capture(driver, f"popup-{'night' if night else 'sepia'}.png")).convert("RGB")
            bounds = popup["bounds"]
            background = image.getpixel((0, 0))
            center = bounds["x"] + bounds["w"] // 2
            outline = image.getpixel((center, bounds["y"]))
            assert outline != background
            assert image.getpixel((center, bounds["y"] + popup["radius"] // 2)) == background
            for x in (bounds["x"], bounds["x"] + bounds["w"] - 1):
                assert image.getpixel((x, bounds["y"])) != outline
                assert image.getpixel((x, bounds["y"] + popup["radius"] * 2)) == outline
            scale = min(themed["screen"].values()) / 600
            scroll_bar = popup["scroll_bar"]
            assert scroll_bar["w"] == math.ceil(4 * scale)
            assert bounds["x"] + bounds["w"] - scroll_bar["x"] - scroll_bar["w"] == math.ceil(4 * scale)
            scrolled = _ref(driver, "gesture", target="body", gesture="swipe", direction="north")
            assert scrolled["drawer"]["ratio"] > popup["ratio"]
            closed = _ref(driver, "gesture", gesture="swipe", direction="south")
            assert not closed.get("drawer") and closed["location"] == current["location"]
            assert closed["history"] == current["history"]
            _ref(driver, "open_note")
            expanded = _navigate(driver, "gesture", gesture="swipe", direction="north")
            assert not expanded.get("drawer") and expanded["history"] == current["history"] + 1
            _browser(driver)
            assert _ref(driver, "page_action", id="back")["page"] == current["page"]

            _ref(driver, "pin", page=3)
            pinned = _ref(driver, "open_pin")
            image = Image.open(_capture(driver, f"pin-icons-{'night' if night else 'sepia'}.png")).convert("RGB")
            button = pinned["drawer"]["menu"]
            assert image.getpixel((button["x"] + 1, button["y"] + 1)) == background
            assert image.getpixel((button["x"] + button["w"] - 2, button["y"] + button["h"] - 2)) == background
            assert not _ref(driver, "gesture", gesture="swipe", direction="south").get("drawer")
            _ref(driver, "open_pin")
            expanded = _navigate(driver, "gesture", target="header")
            assert not expanded.get("drawer") and expanded["page"] == expanded["pin"]
        finally:
            stop(process)


@pytest.mark.parametrize("language,landscape,night", [("fr", True, False), ("zh_TW", False, True)])
def test_reference_controls_fit_compact_screens_and_hardware(language, landscape, night):
    with tempfile.TemporaryDirectory(prefix="zen-reference-layout-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "layout.epub"
        _write_book(book)
        socket = root / "driver.sock"
        scale = 2 if sys.platform == "darwin" else 1
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library,
                         language=language, env_overrides={"EMULATE_READER_W": str(640 // scale),
                                                          "EMULATE_READER_H": str(960 // scale)})
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            _ref(driver, "pin", page=3)
            _ref(driver, "footnote", index=1)
            _ref(driver, "close")
            _ref(driver, "goto", page=2)
            if night:
                _ref(driver, "night")
            if landscape:
                _ref(driver, "resize", mode=1)
            state = _ref(driver, "open_pin")
            _assert_pin_header_padding(state)
            assert not state["drawer"].get("pager")
            screen, bounds = state["screen"], state["drawer"]["bounds"]
            assert screen["w"] - bounds["x"] == math.floor(screen["w"] * 0.7)
            assert bounds["h"] == math.floor(screen["h"] * 0.7)
            assert bounds["x"] + bounds["w"] > screen["w"]
            assert bounds["y"] + bounds["h"] == screen["h"]
            assert bounds["y"] + state["drawer"]["paint_height"] == screen["h"]
            _ref(driver, "resize", mode=0 if landscape else 1)
            rotated = _ref(driver)
            _assert_pin_header_padding(rotated)
            assert not rotated["drawer"].get("pager")
            assert rotated["drawer"]["bounds"]["x"] == rotated["screen"]["w"] - math.floor(rotated["screen"]["w"] * 0.7)
            _ref(driver, "resize", mode=1 if landscape else 0)
            assert _ref(driver)["drawer"]
            _ref(driver, "key", key="Back")
            assert not _ref(driver).get("drawer")
            _browser(driver)
            state = _ref(driver)
            assert [a["id"] for a in state["actions"]] == ["reference:back"]
            for action in state["actions"]:
                bounds = action["bounds"]
                assert action["border"] == 0
                assert action["label_height"] <= bounds["h"]
                assert 0 <= bounds["x"] < bounds["x"] + bounds["w"] <= screen["w"]
                assert bounds["y"] + bounds["h"] <= state["divider_bounds"]["y"] + 1
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                preview = driver.command("page_browser_state")["page_browser"]
                if preview["preview_ready"]:
                    break
                time.sleep(0.1)
            assert preview["preview_ready"]
            _assert_action_dividers(driver, state, f"actions-{language}.png")
            assert driver.command("activate_reader_control", name="page_browser_controls")["activated"]
            assert driver.command("page_browser_state")["page_browser"]["full_page"]
            assert not _ref(driver)["actions"]
            _capture(driver, f"actions-{language}-aa-full.png")
            assert driver.command("activate_reader_control", name="page_browser_bookmarks")["activated"]
            assert not _ref(driver)["actions"]
            assert driver.command("activate_reader_control", name="page_browser_pages")["activated"]
            _ref(driver, "focus_action", id="back")
            assert driver.command("page_browser_key", key="Return")["handled"]
            assert not _ref(driver)["browser_open"]
        finally:
            stop(process)


@pytest.mark.parametrize("footer_enabled", [True, False])
def test_pin_status_colors_follow_reader_theme(footer_enabled):
    with tempfile.TemporaryDirectory(prefix="zen-pin-colors-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "colors.epub"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            current = _ref(driver)
            _ref(driver, "pin", page=current["page"])
            _ref(driver, "pin", page=3)
            _ref(driver, "footer_enabled", enabled=footer_enabled)

            def check_color(name, color):
                state = _ref(driver, "paint")
                image = Image.open(_capture(driver, f"pin-colors-{footer_enabled}-{name}.png")).convert("RGB")
                # Older KOReader screenshots retain the night-mode pre-inversion.
                if name == "night" and image.getpixel((0, 0)) == (224, 224, 224):
                    image = ImageChops.invert(image)
                expected = tuple(bytes.fromhex(color.removeprefix("#")))
                for key in ("header_pin", "pin_icon_bounds", "pin_count_bounds", "pin_footer"):
                    bounds = state[key]
                    pixels = image.crop((bounds["x"], bounds["y"],
                                         bounds["x"] + bounds["w"], bounds["y"] + bounds["h"])).getdata()
                    assert min(max(abs(pixel[i] - expected[i]) for i in range(3)) for pixel in pixels) <= 2, key

            theme = {"enabled": True,
                     "light_mode": {"text": "#3f3524", "background": "#f3ead2"},
                     "dark_mode": {"text": "#dcdccc", "background": "#1f1f1f"}}
            assert driver.command("reader_controls", action="theme", theme=theme)["ok"]
            check_color("sepia", "#3f3524")
            theme["light_mode"]["text"] = "#20546c"
            assert driver.command("reader_controls", action="theme", theme=theme)["ok"]
            check_color("changed", "#20546c")
            _ref(driver, "night")
            check_color("night", "#dcdccc")
            _ref(driver, "night")
            check_color("day", "#20546c")
            assert driver.command("reader_controls", action="theme", theme={"enabled": False})["ok"]
            check_color("default", "#000000")
        finally:
            stop(process)


@pytest.mark.parametrize("format", ["epub", "pdf", "cbz"])
def test_pinned_page_icon_uses_top_status_bar_and_clears_bookmark(format):
    with tempfile.TemporaryDirectory(prefix="zen-pin-marker-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / ("marker." + format)
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            _ref(driver, "header", right=True)
            original = _ref(driver, "paint")
            assert not original.get("pin_marker")
            _ref(driver, "pin", page=original["page"])
            pinned = _ref(driver, "paint")
            assert pinned["header_pin"]["icon"].endswith("/icons/pin.svg")
            assert pinned["header_pin"]["y"] + pinned["header_pin"]["h"] <= pinned["header_bounds"]["h"]
            marker = pinned["header_right"]
            assert marker["x"] > pinned["screen"]["w"] * 0.9
            assert marker["y"] < pinned["screen"]["h"] * 0.1
            assert marker["y"] + marker["h"] <= pinned["header_bounds"]["y"] + pinned["header_bounds"]["h"]
            assert marker["w"] > original["header_right"]["w"]
            assert not pinned.get("pin_marker")
            assert pinned["header_right"]["x"] < original["header_right"]["x"]
            _ref(driver, "bookmark")
            both = _ref(driver, "paint")
            assert both["header_right"]["x"] < both["dogear"]["x"]
            assert both["header_right"]["x"] < pinned["header_right"]["x"]
            bounds = both["header_right"]
            crop = (bounds["x"], bounds["y"], both["dogear"]["x"], bounds["y"] + bounds["h"])
            before = Image.open(_capture(driver, "pin-marker-" + format + ".png")).convert("RGB").crop(crop)
            _ref(driver, "header_refresh")
            after = Image.open(_capture(driver, "pin-marker-refresh-" + format + ".png")).convert("RGB").crop(crop)
            assert ImageChops.difference(before, after).getbbox() is None
            _ref(driver, "jump", page=2)
            other = _ref(driver, "paint")
            assert other["header_right"]["w"] == original["header_right"]["w"]
            assert not other.get("header_pin")
            assert other["header_right"]["x"] == original["header_right"]["x"]
            _ref(driver, "jump", page=original["page"])
            assert _ref(driver, "paint")["header_right"]["w"] == both["header_right"]["w"]
            _ref(driver, "remove")
            assert _ref(driver, "paint")["header_right"]["w"] < both["header_right"]["w"]
            _ref(driver, "pin", page=original["page"])
            _ref(driver, "resize", mode=1)
            rotated = _ref(driver, "paint")
            marker = rotated["header_right"]
            assert marker["x"] + marker["w"] <= rotated["screen"]["w"]
            assert marker["x"] < rotated["dogear"]["x"]
            _ref(driver, "header", pin_side="left")
            left = _ref(driver, "paint")
            assert left["header_pin"]["icon"].endswith("/icons/pin.svg")
            assert left["header_left"]["x"] < left["screen"]["w"] / 2
            assert not left.get("header_right")
            _capture(driver, "pin-header-left-" + format + ".png")
            _ref(driver, "header", long_text=True)
            crowded = _ref(driver, "paint")
            assert crowded["header_pin"]["icon"].endswith("/icons/pin.svg")
            assert crowded["header_pin"]["x"] + crowded["header_pin"]["w"] <= crowded["dogear"]["x"]
            if format == "epub":
                heights = []
                for spacing in (100, 150):
                    _ref(driver, "line_spacing", value=spacing)
                    _ref(driver, "paint")
                    opened = _ref(driver, "open_pin")
                    heights.append(float(opened["drawer"]["css"].split("line-height: ")[1].split(";")[0]))
                    _ref(driver, "close")
                assert heights[1] == pytest.approx(heights[0] * 1.5, abs=0.002)
        finally:
            stop(process)


def test_pin_button_preserves_new_selections_and_saved_highlights():
    with tempfile.TemporaryDirectory(prefix="zen-pin-menu-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "selection.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            original = _ref(driver)
            seeded = driver.command("highlight_tools", action="seed")
            assert seeded["ok"], seeded
            assert "zen_pin" in seeded["menu_ids"]
            pinned = _ref(driver, "pin_button")
            assert pinned["pin"] and pinned["annotations"] == original["annotations"]
            assert not pinned["pin_menu"] and not pinned["selected_text"]
            _ref(driver, "remove")
            saved = driver.command("highlight_tools", action="seed", saved=True)
            assert saved["ok"], saved
            assert "zen_pin" in saved["menu_ids"]
            count = _ref(driver)["annotations"]
            pinned = _ref(driver, "pin_button")
            assert pinned["pin"] and pinned["annotations"] == count and not pinned["pin_menu"]
            _ref(driver, "remove")
            for saved_menu in (False, True):
                _ref(driver, "pin")
                menu = driver.command("highlight_tools", action="seed", saved=saved_menu)
                assert menu["menu_icon_files"][-1].endswith("/icons/pin_remove.svg")
                count = _ref(driver)["annotations"]
                removed = _ref(driver, "pin_button")
                assert not removed.get("pin") and removed["annotations"] == count
            assert driver.command("highlight_tools", action="seed")["ok"]
            assert driver.command("activate_reader_control", name="highlight_dictionary")["activated"]
            lookup_pin = _ref(driver, "pin_button", lookup=True)
            assert lookup_pin["pin"] and lookup_pin["annotations"] == count
        finally:
            stop(process)


def test_multiple_pins_footer_pager_and_independent_text_settings():
    with tempfile.TemporaryDirectory(prefix="zen-multiple-pins-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "pins.epub"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            start = _ref(driver, "paint")
            assert not start.get("pin_footer")
            assert not start["pins"]
            added = _ref(driver, "pin", page=start["page"])
            assert len(added["pins"]) == 1
            _ref(driver, "pin", page=3)
            pinned = _ref(driver, "pin", page=5)
            assert len(pinned["pins"]) == 3
            footer = _ref(driver, "paint")
            text, pin = footer["footer_text"], footer["pin_footer"]
            assert text["x"] + text["w"] <= footer["pin_label_left"]
            assert pin["x"] + pin["w"] <= footer["screen"]["w"]
            assert pin["y"] > footer["screen"]["h"] * 0.9
            for preset in range(1, 7):
                _ref(driver, "pin_preset", index=preset)
                layout = _ref(driver, "paint")
                _assert_pin_padding(layout)
                text = layout["footer_text"]
                if preset == 4:
                    assert text["x"] + text["w"] <= layout["pin_label_left"], preset
                else:
                    gap = layout["footer_percentage"]["x"] - layout["pin_footer"]["x"] - layout["pin_footer"]["w"]
                    assert gap >= math.ceil(4 * min(layout["screen"].values()) / 600), preset
                _assert_pin_alignment(driver, layout, f"pin-footer-preset-{preset}.png")
            opened = _ref(driver, "pin_control", target="footer")
            scale = min(opened["screen"]["w"], opened["screen"]["h"]) / 600
            assert opened["drawer"]["pin_index"] == 1
            _assert_pin_header_padding(opened)
            bounds = opened["drawer"]["bounds"]
            assert opened["screen"]["w"] - bounds["x"] == math.floor(opened["screen"]["w"] * 0.7)
            assert bounds["x"] + bounds["w"] > opened["screen"]["w"]
            assert bounds["h"] == math.floor(opened["screen"]["h"] * 0.7)
            assert bounds["y"] + bounds["h"] == opened["screen"]["h"]
            assert bounds["y"] + opened["drawer"]["paint_height"] == opened["screen"]["h"]
            assert opened["drawer"]["border"] == math.ceil(2 * scale)
            assert opened["drawer"]["radius"] > 0
            assert opened["drawer"]["menu_icon"].endswith("/icons/more_vertical.svg")
            label, pager, content = (opened["drawer"][key] for key in ("page_label", "pager", "content"))
            menu = opened["drawer"]["menu"]
            assert menu["h"] == math.ceil(28 * scale)
            assert menu["y"] - bounds["y"] == math.ceil(6 * scale)
            assert content["y"] == menu["y"] + menu["h"] + math.ceil(8 * scale)
            assert content["h"] >= bounds["h"] - math.ceil(94 * scale)
            assert label["y"] == menu["y"]
            assert label["h"] == math.ceil(28 * scale)
            assert pager["y"] == content["y"] + content["h"]
            assert pager["h"] == math.ceil(32 * scale)
            assert opened["screen"]["h"] - pager["y"] - pager["h"] == math.ceil(4 * scale)
            scroll_bar = opened["drawer"]["scroll_bar"]
            assert scroll_bar["w"] == math.ceil(4 * scale)
            assert opened["screen"]["w"] - scroll_bar["x"] - scroll_bar["w"] == math.ceil(4 * scale)
            for direction in ("left", "right"):
                arrow = opened["drawer"]["pager_" + direction]
                assert arrow["icon"].endswith(f"/chevron.{direction}.svg")
                assert arrow["bounds"]["h"] == pager["h"]
            pin_pages = [pin["page"] for pin in opened["pins"]]
            assert _ref(driver, "pin_control", target="previous")["drawer"]["page"] == pin_pages[2]
            assert _ref(driver, "pin_control", target="next")["drawer"]["page"] == pin_pages[0]
            assert _ref(driver, "gesture", target="body", gesture="swipe", direction="east")["drawer"]["page"] == pin_pages[2]
            assert _ref(driver, "gesture", target="body", gesture="swipe", direction="west")["drawer"]["page"] == pin_pages[0]
            assert _ref(driver, "pin_control", target="next")["drawer"]["page"] == pin_pages[1]
            assert _ref(driver, "pin_control", target="next")["drawer"]["page"] == pin_pages[2]
            assert _ref(driver, "pin_control", target="next")["drawer"]["page"] == pin_pages[0]
            assert _ref(driver, "pin_control", target="previous")["drawer"]["page"] == pin_pages[2]
            assert _ref(driver, "pin_control", target="previous")["drawer"]["page"] == pin_pages[1]
            _ref(driver, "close")
            assert _ref(driver, "pin_control", target="footer")["drawer"]["page"] == pin_pages[1]
            assert _ref(driver)["location"] == start["location"]
            assert _ref(driver)["history"] == start["history"]
            image = Image.open(_capture(driver, "multiple-pins.png")).convert("RGB")
            edge = opened["screen"]["w"] - 1
            assert image.getpixel((edge, bounds["y"])) == (0, 0, 0)
            # The rounded corner exposes the drawer's 30% shadow.
            assert image.getpixel((bounds["x"], opened["screen"]["h"] - 1)) == (179, 179, 179)
            assert image.getpixel((bounds["x"], opened["screen"]["h"] - opened["drawer"]["radius"] * 2)) == (0, 0, 0)
            assert all(image.getpixel((x, opened["screen"]["h"] - 1)) == (0, 0, 0)
                       for x in range(bounds["x"] + opened["drawer"]["radius"] * 2, edge + 1))
            assert image.getpixel((edge, bounds["y"] + bounds["h"] // 2)) == (255, 255, 255)
            left_arrow, right_arrow = (opened["drawer"]["pager_" + direction]["bounds"] for direction in ("left", "right"))
            row = [image.getpixel((x, pager["y"] + pager["h"] // 2)) != (255, 255, 255)
                   for x in range(left_arrow["x"] + left_arrow["w"], right_arrow["x"])]
            assert [len(list(group)) for painted, group in itertools.groupby(row) if painted] == [math.ceil(6 * scale)] * 3
            default_size = _ref(driver)["drawer"]["font_size"]
            _ref(driver, "pin_control", target="menu")
            assert _ref(driver)["pin_popup_buttons"] == ["Remove pin", "Settings"]
            _capture(driver, "multiple-pins-menu.png")
            _ref(driver, "pin_popup_action", text="Settings")
            settings = driver.command("settings_page_state")["settings"]
            assert settings["title"] == "Pinned page options"
            assert "Font size" in settings["labels"]
            assert "Position" in settings["labels"]
            assert not _ref(driver).get("drawer")
            assert driver.command("settings_page_select", label="Justify text in popups")["ok"]
            assert driver.command("settings_page_select", label="Font size")["ok"]
            _ref(driver, "pin_font_size", value=3)
            assert driver.command("close_settings_page")["ok"]
            resized = _ref(driver, "open_pin", index=2)
            assert resized["drawer"]["font_size"] == default_size + 3
            assert "text-align: left" in resized["drawer"]["css"]
            _ref(driver, "pin_control", target="menu")
            _ref(driver, "pin_popup_action", text="Settings")
            assert driver.command("settings_page_select", label="Font size")["ok"]
            _ref(driver, "pin_font_size", absolute=True)
            _ref(driver, "pin_font_size", value=20)
            assert driver.command("settings_page_select", label="Use book font in popups")["ok"]
            assert driver.command("close_settings_page")["ok"]
            absolute = _ref(driver, "open_pin", index=2)
            assert absolute["drawer"]["font_size"] == math.ceil(20 * scale)
            font = _ref(driver)
            assert "@font-face" not in font["drawer"]["css"]
            assert font["reader_font_size"] == start["reader_font_size"]
            _ref(driver, "pin_control", target="menu")
            _ref(driver, "pin_popup_action", text="Settings")
            assert driver.command("settings_page_select", label="Position")["ok"]
            assert driver.command("settings_page_state")["settings"]["labels"] == ["Left", "Right"]
            assert driver.command("settings_page_select", label="Left")["ok"]
            assert driver.command("close_settings_page")["ok"]
            left = _ref(driver, "open_pin", index=2)
            _assert_pin_header_padding(left)
            bounds = left["drawer"]["bounds"]
            assert bounds["x"] < 0
            assert bounds["x"] + bounds["w"] == math.floor(left["screen"]["w"] * 0.7)
            assert bounds["y"] + bounds["h"] == left["screen"]["h"]
            assert bounds["y"] + left["drawer"]["paint_height"] == left["screen"]["h"]
            assert left["drawer"]["content"]["x"] >= 0
            image = Image.open(_capture(driver, "multiple-pins-left.png")).convert("RGB")
            assert image.getpixel((0, bounds["y"])) == (0, 0, 0)
            assert image.getpixel((bounds["x"] + bounds["w"] - 1, left["screen"]["h"] - 1)) == (179, 179, 179)
            assert all(image.getpixel((x, left["screen"]["h"] - 1)) == (0, 0, 0)
                       for x in range(bounds["x"] + bounds["w"] - left["drawer"]["radius"] * 2))
            assert image.getpixel((0, bounds["y"] + bounds["h"] // 2)) == (255, 255, 255)
            _ref(driver, "gesture", target="header", gesture="swipe", direction="south")
            assert not _ref(driver).get("drawer")
            _ref(driver, "footnote")
            assert _ref(driver)["drawer"]["font_size"] == start["reader_font_size"]
            _ref(driver, "close")
            _ref(driver, "open_pin", index=2)
            _ref(driver, "gesture", target="outside")
            assert not _ref(driver).get("drawer")
            _ref(driver, "close_book")
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            reopened = _ref(driver)
            assert len(reopened["pins"]) == 3
            assert reopened["pin_locations"] == pinned["pin_locations"]
            assert _ref(driver, "pin_control", target="footer")["drawer"]["page"] == reopened["pins"][1]["page"]
            _ref(driver, "close")
            _ref(driver, "open_pin", index=3)
            restored = _ref(driver)["drawer"]
            assert restored["page"] == reopened["pins"][2]["page"]
            assert restored["bounds"]["x"] < 0
            _ref(driver, "pin_control", target="menu")
            removed = _ref(driver, "pin_popup_action", text="Remove pin")
            assert len(removed["pins"]) == 2
            assert removed["drawer"]["pin_index"] == 2
            assert removed["drawer"]["page"] == removed["pins"][1]["page"]
            _ref(driver, "pin_control", target="menu")
            single = _ref(driver, "pin_popup_action", text="Remove pin")
            assert len(single["pins"]) == 1
            assert not single["drawer"].get("pager")
            assert single["drawer"]["content"]["h"] == removed["drawer"]["content"]["h"] + math.ceil(32 * scale)
            _assert_pin_header_padding(single)
        finally:
            stop(process)


@pytest.mark.parametrize("format", ["epub", "pdf", "cbz"])
def test_pinned_preview_spacing_and_swipe_dismissal(format):
    with tempfile.TemporaryDirectory(prefix="zen-pin-dismiss-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / f"dismiss.{format}"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library,
                         zen_config_source="return { reader_pins = { font_size = 48 } }")
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            original = _ref(driver)
            _ref(driver, "pin", page=3)
            for target in ("header", "preview"):
                opened = _ref(driver, "open_pin")
                _assert_pin_header_padding(opened)
                if format == "epub":
                    content, bar = (opened["drawer"][key] for key in ("content", "scroll_bar"))
                    shortening = math.ceil(8 * min(opened["screen"].values()) / 600)
                    assert bar["y"] == content["y"] + shortening // 2
                    assert bar["h"] == content["h"] - shortening
                    top = _ref(driver, "gesture", target="body", x_ratio=0.1)
                    assert top["drawer"]["ratio"] == 0
                    forward = _ref(driver, "gesture", target="body", x_ratio=0.9)
                    assert forward["drawer"]["ratio"] > 0
                    back = _ref(driver, "gesture", target="body", x_ratio=0.1)
                    assert back["drawer"]["ratio"] == 0
                    scrolled = _ref(driver, "scroll", ratio=1)["drawer"]["ratio"]
                    assert scrolled > 0
                    bottom = _ref(driver, "gesture", target="body", x_ratio=0.9)
                    assert bottom["drawer"]["ratio"] == scrolled
                    assert bottom["page"] == original["page"] and bottom["history"] == original["history"]
                    body = _ref(driver, "gesture", target="body", gesture="swipe", direction="south")
                    assert body["drawer"]["ratio"] < scrolled
                else:
                    zoomed = _ref(driver, "zoom", factor=2)["drawer"]
                    assert zoomed["scale"] > opened["drawer"]["scale"]
                    body = _ref(driver, "gesture", target="body", gesture="swipe", direction="south", distance=35)
                    assert body["drawer"]["center"]["y"] < zoomed["center"]["y"]
                boundary = _ref(driver, "gesture", target="preview", gesture="swipe", direction="south", y_ratio=0.07)
                assert boundary.get("drawer")
                closed = _ref(driver, "gesture", target=target, gesture="swipe", direction="south",
                              y_ratio=0.07 - 1 / opened["drawer"]["bounds"]["h"])
                assert not closed.get("drawer")
                assert closed["page"] == original["page"] and closed["history"] == original["history"]
                assert closed.get("location") == original.get("location")
                assert len(closed["pins"]) == 1
            _ref(driver, "open_pin")
            navigated = _navigate(driver, "gesture", target="header")
            assert not navigated.get("drawer") and navigated["page"] == opened["drawer"]["page"]
            assert navigated["history"] == original["history"] + 1
            if format == "epub":
                _ref(driver, "open_pin")
                _ref(driver, "pin_menu")
                _ref(driver, "pin_popup_action", text="Settings")
                assert driver.command("settings_page_select", label="Position")["ok"]
                assert driver.command("settings_page_select", label="Left")["ok"]
                assert driver.command("close_settings_page")["ok"]
                left = _ref(driver, "open_pin")
                _assert_pin_header_padding(left)
                _ref(driver, "scroll", ratio=0)
                forward = _ref(driver, "gesture", target="body", x_ratio=0.6)
                assert forward["drawer"]["ratio"] > 0
                back = _ref(driver, "gesture", target="body", x_ratio=0.4)
                assert back["drawer"]["ratio"] == 0
                assert back["page"] == navigated["page"] and back["history"] == navigated["history"]
        finally:
            stop(process)


@pytest.mark.parametrize("format,show_labels", [("pdf", False), ("cbz", False), ("epub", False), ("epub", True)])
def test_pinned_images_pan_and_zoom_without_switching_pins(format, show_labels):
    with tempfile.TemporaryDirectory(prefix="zen-image-pin-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / f"image.{format}"
        picture = Image.new("RGB", (600, 800), "white")
        draw = ImageDraw.Draw(picture)
        for y in range(0, 800, 80):
            for x in range(0, 600, 80):
                draw.rectangle((x, y, x + 79, y + 79), fill="#c0c0c0" if (x + y) % 160 else "white")
                draw.text((x + 10, y + 10), f"{x},{y}", fill="black")
        if format == "epub" and show_labels:
            picture = picture.convert("RGBA")
            ImageDraw.Draw(picture).rectangle((0, 0, 79, 79), fill=(0, 0, 0, 0))
        if format == "epub":
            _write_book(book)
            with zipfile.ZipFile(book) as archive:
                files = {name: archive.read(name) for name in archive.namelist()}
            files["content.opf"] = files["content.opf"].replace(b"<manifest>", b"""<manifest>
              <item id="illustration" href="illustration.xhtml" media-type="application/xhtml+xml"/>
              <item id="illustration2" href="illustration2.xhtml" media-type="application/xhtml+xml"/>
              <item id="marker" href="marker.png" media-type="image/png"/>
              <item id="image" href="image.png" media-type="image/png"/>""").replace(
                  b"<spine>", b'<spine><itemref idref="illustration"/>').replace(
                  b"</spine>", b'<itemref idref="illustration2"/></spine>')
            files["illustration.xhtml"] = b"""<html xmlns="http://www.w3.org/1999/xhtml"><head>
              <title>Illustration</title></head><body style="margin:0"><h1>Map</h1><p style="margin:0">
              <img src="marker.png" alt="Marker" style="width:2em"/>
              <img src="image.png" alt="Illustration" style="height:70vh"/></p></body></html>"""
            files["illustration2.xhtml"] = files["illustration.xhtml"].replace(b"<h1>Map</h1>", b"").replace(
                b' style="height:70vh"', b"").replace(
                b'<img src="marker.png" alt="Marker" style="width:2em"/>', b"")
            buffer = io.BytesIO()
            Image.new("RGB", (40, 30), "black").save(buffer, format="PNG")
            files["marker.png"] = buffer.getvalue()
            buffer = io.BytesIO()
            picture.save(buffer, format="PNG")
            files["image.png"] = buffer.getvalue()
            with zipfile.ZipFile(book, "w") as archive:
                for name, data in files.items():
                    archive.writestr(name, data)
        elif format == "pdf":
            picture.save(book, save_all=True, append_images=[picture, picture])
        else:
            with zipfile.ZipFile(book, "w") as archive:
                for index in range(3):
                    buffer = io.BytesIO()
                    picture.save(buffer, format="PNG")
                    archive.writestr(f"{index}.png", buffer.getvalue())
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library, zen_config_source=(
            "return { reader_pins = { minimap = true }, highlight_lookup = { show_labels = "
            + str(show_labels).lower() + " } }"
        ))
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            original = _ref(driver)
            if format == "epub":
                held = _ref(driver, "hold_image")
                assert held["image_menu"] and not held["image_viewer"]
                assert not held["selected_text"]
                assert len(held["image_buttons"]) == 1
                buttons = held["image_buttons"][0]
                assert len(buttons) == 2
                assert buttons[0]["icon"].endswith("/fullscreen.svg")
                assert buttons[1]["icon"].endswith("/pin.svg")
                assert [button["text"] for button in buttons] == (["View image", "Pin"] if show_labels else ["", ""])
                assert all(button["content_width"] <= button["width"] for button in buttons)
                _capture(driver, "image-highlight-labels.png" if show_labels else "image-highlight-menu.png")
                _ref(driver, "image_view")
                assert _ref(driver)["image_viewer"]
                _ref(driver, "close_image")
                _ref(driver, "hold_image")
                dismissed = _ref(driver, "dismiss_image_menu")
                assert not dismissed["image_menu"] and not dismissed["pins"]
                _ref(driver, "enabled", enabled=False)
                native = _ref(driver, "hold_image")
                assert native["image_viewer"] and not native["image_menu"]
                _ref(driver, "close_image")
                _ref(driver, "enabled", enabled=True)
                _ref(driver, "hold_image")
                pinned = _ref(driver, "pin_button")
                assert len(pinned["pins"]) == 1 and not pinned["image_menu"]
                assert pinned["pins"][0].get("image", "").endswith("/img[2].0"), pinned["pins"]
                assert pinned["annotations"] == original["annotations"]
                assert pinned["location"] == original["location"]
            else:
                _ref(driver, "pin", page=1)
            initial = _ref(driver, "open_pin")
            if format == "epub":
                assert initial["drawer"]["original_image"], initial["drawer"]
                assert initial["drawer"]["source_size"] == {"w": 600, "h": 800}
            single = _ref(driver, "pin_control", target="zoom")
            assert not single["pin_popup_buttons"]
            assert single["drawer"]["zoom_icon"].endswith("/icons/fullscreen_exit.svg")
            _assert_pin_header_icon_padding(single)
            single_drawer = single["drawer"]
            assert single_drawer["full_image"] and not single_drawer.get("pager")
            zoom_in = single_drawer["zoom_in"]
            scale = min(single["screen"].values()) / 600
            menu = single_drawer["menu"]
            assert zoom_in["y"] == menu["y"] + menu["h"] + 2 * math.ceil(8 * scale)
            single_zoomed = _ref(driver, "pin_control", target="zoom_in")["drawer"]
            assert single_zoomed["scale"] > single_drawer["scale"]
            _ref(driver, "close")
            restored = _ref(driver, "open_pin")["drawer"]
            assert restored["full_image"] and restored["scale"] == pytest.approx(single_zoomed["scale"])
            _ref(driver, "close")
            _ref(driver, "pin", page=original["page_count"])
            fresh = _ref(driver, "open_pin", index=1)["drawer"]
            assert fresh["image"] and not fresh["full_image"]
            assert max(fresh["image_view"][axis] / fresh["content"][axis] for axis in ("w", "h")) == pytest.approx(1, abs=0.01)
            fresh_scale = fresh["scale"]
            restored = _ref(driver, "next")["drawer"]
            assert restored["full_image"] and restored["scale"] == pytest.approx(single_zoomed["scale"])
            _ref(driver, "previous")
            _ref(driver, "pin_control", target="zoom")
            _ref(driver, "zoom", factor=2)
            _ref(driver, "pin_menu")
            _ref(driver, "pin_popup_action", text="Remove pin")
            _ref(driver, "close")
            _ref(driver, "pin", page=original["page_count"])
            fresh = _ref(driver, "open_pin", index=1)["drawer"]
            assert not fresh["full_image"]
            assert fresh["scale"] == pytest.approx(fresh_scale)
            _ref(driver, "pin_menu")
            restored = _ref(driver, "pin_popup_action", text="Remove pin")["drawer"]
            assert restored["full_image"] and restored["scale"] == pytest.approx(single_zoomed["scale"])
            _ref(driver, "pin_control", target="zoom")
            _ref(driver, "close")
            _ref(driver, "pin", page=3)
            opened = _ref(driver, "open_pin", index=2)
            assert opened["drawer"]["image"] and not opened["drawer"].get("minimap")  # Fitted: nothing to pan.
            assert opened["double_tap_disabled"]
            drawer = opened["drawer"]
            _assert_pin_header_padding(opened)
            zoom, menu = drawer["zoom"], drawer["menu"]
            assert drawer["zoom_icon"].endswith("/icons/fullscreen.svg")
            assert drawer["menu_icon"].endswith("/icons/more_vertical.svg")
            assert not drawer.get("zoom_in") and not drawer.get("zoom_out")
            assert drawer["page_label"]["x"] + drawer["page_label"]["w"] <= zoom["x"]
            gap = math.ceil(8 * min(opened["screen"].values()) / 600)
            assert zoom["x"] + zoom["w"] + gap == drawer["close"]["x"]
            assert zoom["y"] == menu["y"] and zoom["h"] == menu["h"]
            toggled = _ref(driver, "pin_control", target="zoom")
            assert toggled["drawer"]["full_image"]
            assert toggled["drawer"]["zoom_icon"].endswith("/icons/fullscreen_exit.svg")
            assert not toggled["pin_popup_buttons"]
            unzoomed = _ref(driver, "pin_control", target="zoom")
            assert not unzoomed["drawer"]["full_image"]
            assert unzoomed["drawer"]["zoom_icon"].endswith("/icons/fullscreen.svg")
            assert not unzoomed["pin_popup_buttons"]
            assert unzoomed["drawer"]["scale"] == pytest.approx(drawer["scale"])
            content, image = drawer["content"], drawer["image_view"]
            assert content["x"] == drawer["bounds"]["x"] + drawer["border"]
            assert content["x"] + content["w"] == opened["screen"]["w"]
            assert drawer["center"] == {"x": 0.5, "y": 0.5}
            assert image["w"] <= content["w"] and image["h"] <= content["h"]
            assert image["w"] / image["h"] == pytest.approx(0.75, abs=0.01)
            assert min(content["w"] - image["w"], content["h"] - image["h"]) <= 1
            fitted = Image.open(_capture(driver, f"pin-{format}-fit.png")).convert("RGB")
            if format == "epub" and show_labels:
                x = content["x"] - image["x"] + math.floor(40 * drawer["scale"])
                y = content["y"] - image["y"] + math.floor(40 * drawer["scale"])
                assert fitted.getpixel((x, y)) == tuple(drawer["background"])
            for distance in (100000, -100000):
                _ref(driver, "gesture", target="body", gesture="pan", relative={"x": distance, "y": distance})
                edge = _ref(driver, "gesture", target="outside", gesture="pan_release")["drawer"]
                for axis, size in (("x", "w"), ("y", "h")):
                    limit = (min if distance > 0 else max)(0, image[size] - content[size])
                    assert edge["image_view"][axis] == pytest.approx(limit, abs=1)
            assert edge["center"] != drawer["center"]
            _ref(driver, "close")
            restored = _ref(driver, "open_pin")["drawer"]
            assert restored["center"] == pytest.approx(edge["center"])
            assert restored["image_view"] == edge["image_view"]
            full = _ref(driver, "pin_control", target="zoom")
            _assert_pin_header_icon_padding(full)
            assert not full["image_viewer"] and full["drawer"]["full_image"]
            assert full["drawer"]["pin_index"] == opened["drawer"]["pin_index"]
            assert full["page"] == original["page"] and full["history"] == original["history"]
            filled = full["drawer"]
            viewport, bounds, image = filled["content"], filled["bounds"], filled["image_view"]
            assert viewport["x"] == bounds["x"] + filled["border"]
            assert viewport["y"] == bounds["y"] + filled["border"]
            assert viewport["h"] == bounds["h"] - 2 * filled["border"]
            assert viewport["y"] < filled["menu"]["y"]
            assert viewport["y"] + viewport["h"] > filled["pager"]["y"]
            assert image["w"] >= viewport["w"] - 1 and image["h"] >= viewport["h"] - 1
            assert image["w"] / image["h"] == pytest.approx(0.75, abs=0.01)
            assert filled["control_radius"] == filled["feedback_radius"]
            zoom_out, zoom_in = filled["zoom_out"], filled["zoom_in"]
            assert filled["zoom_in_icon"].endswith("/icons/zoom_in.svg")
            assert filled["zoom_out_icon"].endswith("/icons/zoom_out.svg")
            assert zoom_out["x"] == zoom_in["x"] == filled["close"]["x"]
            assert zoom_in["y"] + zoom_in["h"] + gap == zoom_out["y"]
            assert zoom_in["x"] + zoom_in["w"] == filled["close"]["x"] + filled["close"]["w"]
            assert zoom_in["y"] == filled["menu"]["y"] + filled["menu"]["h"] + 2 * gap
            assert zoom_out["y"] + zoom_out["h"] < filled["pager"]["y"]
            snapshot = Image.open(_capture(driver, f"pin-{format}-full.png")).convert("RGB")
            for y in (viewport["y"], viewport["y"] + viewport["h"] - 1):
                assert snapshot.getpixel((viewport["x"], y)) == fitted.getpixel((viewport["x"], y))
            inset = math.ceil(min(full["screen"].values()) / 600) + 1
            for key in ("zoom", "menu", "zoom_in", "zoom_out", "dots_background"):
                control = filled[key]
                assert snapshot.getpixel((control["x"], control["y"] + control["h"] // 2)) == (0, 0, 0)
                assert snapshot.getpixel((control["x"] + inset, control["y"] + control["h"] // 2)) == (255, 255, 255)
            for key in ("pager_left", "pager_right"):
                control = filled[key]["bounds"]
                assert snapshot.getpixel((control["x"], control["y"] + control["h"] // 2)) == (0, 0, 0)
                assert snapshot.getpixel((control["x"] + inset, control["y"] + control["h"] // 2)) == (255, 255, 255)
            magnified = _ref(driver, "pin_control", target="zoom_in")
            assert magnified["drawer"]["full_image"] and magnified["drawer"]["scale"] > filled["scale"]
            assert not magnified["pin_popup_buttons"]
            # Minimap: bottom-left inside the image, gray with a lighter viewport box.
            minimap, viewport = magnified["drawer"]["minimap"], magnified["drawer"]["content"]
            area, view = minimap["dimen"], minimap["view"]
            assert area["x"] > viewport["x"] and area["x"] + area["w"] < viewport["x"] + viewport["w"] // 2
            assert area["y"] > viewport["y"] + viewport["h"] // 2 and area["y"] + area["h"] < viewport["y"] + viewport["h"]
            assert area["x"] < view["x"] and area["y"] < view["y"]
            assert view["x"] + view["w"] <= area["x"] + area["w"] and view["y"] + view["h"] <= area["y"] + area["h"]
            mapped = Image.open(_capture(driver, f"pin-{format}-minimap.png")).convert("RGB")
            gray = mapped.getpixel((area["x"] + 1, area["y"] + area["h"] // 2))
            light = mapped.getpixel((view["x"] + view["w"] // 2, view["y"] + view["h"] // 2))
            assert gray[0] == gray[1] == gray[2] and gray[0] < light[0]
            # Hold-drag pans live: each event applies only its delta, before release.
            held = _ref(driver, "gesture", target="body", gesture="hold")["drawer"]["image_view"]
            step = _ref(driver, "gesture", target="body", gesture="hold_pan", relative={"x": 10, "y": 10})["drawer"]
            moved = _ref(driver, "gesture", target="body", gesture="hold_pan", relative={"x": 20, "y": 20})["drawer"]
            assert step["image_view"] != held and step["pin_index"] == magnified["drawer"]["pin_index"]
            for axis in ("x", "y"):
                assert moved["image_view"][axis] - held[axis] == 2 * (step["image_view"][axis] - held[axis])
            released = _ref(driver, "gesture", target="body", gesture="hold_release")["drawer"]
            assert released["image_view"] == moved["image_view"]
            # A quick drag lifted as a swipe keeps its live position instead of paging or jumping.
            _ref(driver, "gesture", target="body", gesture="pan", relative={"x": -10, "y": -10})
            swiped = _ref(driver, "gesture", target="body", gesture="swipe", direction="west", distance=500)["drawer"]
            assert swiped["image_view"] == step["image_view"] and swiped["pin_index"] == magnified["drawer"]["pin_index"]
            _ref(driver, "gesture", target="body", gesture="pan", relative={"x": 100000, "y": 100000})
            corner = _ref(driver, "gesture", target="body", gesture="pan_release")["drawer"]["minimap"]
            assert (corner["view"]["x"], corner["view"]["y"]) == (corner["dimen"]["x"], corner["dimen"]["y"])
            # Dragging on the minimap moves its viewport box, panning the image the same way, scaled up.
            origin = _ref(driver, "gesture", target="minimap", gesture="hold")["drawer"]["image_view"]
            dragged = _ref(driver, "gesture", target="minimap", gesture="hold_pan", relative={"x": 3, "y": 3})["drawer"]
            for axis in ("x", "y"):
                assert dragged["image_view"][axis] - origin[axis] == pytest.approx(3 / corner["ratio"], abs=1)
            done = _ref(driver, "gesture", target="body", gesture="hold_release")["drawer"]
            assert done["image_view"] == dragged["image_view"] and done["minimap"]["view"]["x"] > corner["view"]["x"]
            # Drags released outside the drawer still settle.
            assert _ref(driver, "gesture", target="body", gesture="pan", relative={"x": 15, "y": 15})["drawer"]["panning"]
            assert not _ref(driver, "gesture", target="outside", gesture="pan_release")["drawer"]["panning"]
            reduced = _ref(driver, "pin_control", target="zoom_out")
            assert reduced["drawer"]["full_image"] and reduced["drawer"]["scale"] < magnified["drawer"]["scale"]
            fitted = _ref(driver, "pin_control", target="zoom")
            assert not fitted["drawer"]["full_image"]
            assert not fitted["drawer"].get("zoom_in") and not fitted["drawer"].get("zoom_out")
            assert not fitted["drawer"].get("control_radius") and not fitted["drawer"].get("dots_background")
            assert fitted["drawer"]["content"] == opened["drawer"]["content"]
            assert fitted["drawer"]["center"] == {"x": 0.5, "y": 0.5}
            _ref(driver, "close")
            restored = _ref(driver, "open_pin")["drawer"]
            assert not restored["full_image"] and restored["scale"] == pytest.approx(fitted["drawer"]["scale"])
            assert _ref(driver, "gesture", target="body")["image_viewer"]
            _ref(driver, "tap_image")
            fit = opened["drawer"]["scale"]
            spread = _ref(driver, "gesture", target="body", gesture="spread")
            assert spread["drawer"]["scale"] > fit
            pinched = _ref(driver, "gesture", target="body", gesture="pinch")
            assert pinched["drawer"]["scale"] < spread["drawer"]["scale"]
            zoomed = _ref(driver, "zoom", factor=4)
            _ref(driver, "close")
            restored = _ref(driver, "open_pin")["drawer"]
            assert not restored["full_image"] and restored["scale"] == pytest.approx(zoomed["drawer"]["scale"])
            before = Image.open(_capture(driver, f"pin-{format}-before-pan.png")).convert("RGB")
            _ref(driver, "gesture", target="body", gesture="pan", relative={"x": -40, "y": -60})
            moved = _ref(driver, "gesture", target="outside", gesture="pan_release")
            assert moved["drawer"]["center"]["x"] > zoomed["drawer"]["center"]["x"]
            assert moved["drawer"]["center"]["y"] > zoomed["drawer"]["center"]["y"]
            after = Image.open(_capture(driver, f"pin-{format}-after-pan.png")).convert("RGB")
            bounds = moved["drawer"]["content"]
            crop = (bounds["x"], bounds["y"], bounds["x"] + bounds["w"], bounds["y"] + bounds["h"])
            assert ImageChops.difference(before.crop(crop), after.crop(crop)).getbbox()
            _ref(driver, "close")
            restored = _ref(driver, "open_pin")["drawer"]
            assert restored["center"] == pytest.approx(moved["drawer"]["center"])
            _ref(driver, "pin_control", target="next")
            restored = _ref(driver, "pin_control", target="previous")["drawer"]
            assert restored["center"] == pytest.approx(moved["drawer"]["center"])
            swiped = _ref(driver, "gesture", target="body", gesture="swipe", direction="west", distance=35)
            assert swiped["drawer"]["pin_index"] == opened["drawer"]["pin_index"]
            assert swiped["drawer"]["center"]["x"] > moved["drawer"]["center"]["x"]
            assert swiped["page"] == original["page"] and swiped["history"] == original["history"]
            if format == "epub":
                assert swiped["location"] == original["location"]
            _ref(driver, "close")
            restored = _ref(driver, "open_pin")["drawer"]
            assert restored["center"] == pytest.approx(swiped["drawer"]["center"])
            _ref(driver, "pin_control", target="zoom")
            reset = _ref(driver, "pin_control", target="zoom")
            assert reset["drawer"]["scale"] == fit
            assert reset["drawer"]["center"] == {"x": 0.5, "y": 0.5}
            assert reset["double_tap_disabled"]
            next_pin = _ref(driver, "pin_control", target="next")
            assert next_pin["drawer"]["pin_index"] == 1  # Wraps to the newer page-3 pin on top.
            if format == "epub":
                assert not next_pin["drawer"]["image"]
                assert not next_pin["drawer"].get("zoom")
                assert not next_pin["drawer"].get("zoom_icon")
            else:
                assert next_pin["drawer"].get("zoom")
            _ref(driver, "pin_control", target="menu")
            actions = _ref(driver)["pin_popup_buttons"]
            assert actions == ["Remove pin", "Settings"]
            _ref(driver, "pin_popup_action", text="Settings")
            assert driver.command("settings_page_state")["settings"]["title"] == "Pinned page options"
            assert driver.command("settings_page_select", label="Position")["ok"]
            assert driver.command("settings_page_select", label="Left")["ok"]
            assert driver.command("close_settings_page")["ok"]
            left = _ref(driver, "open_pin", index=2)["drawer"]
            assert left["bounds"]["x"] < 0
            assert left["content"]["x"] == 0
            assert left["content"]["w"] == left["bounds"]["x"] + left["bounds"]["w"] - left["border"]
            left_full = _ref(driver, "pin_control", target="zoom")["drawer"]
            assert left_full["full_image"] and left_full["content"]["x"] == 0
            assert left_full["content"]["y"] == left_full["bounds"]["y"] + left_full["border"]
            left_zoomed = _ref(driver, "pin_control", target="zoom_in")["drawer"]
            _ref(driver, "gesture", target="body", gesture="pan", relative={"x": -40, "y": -60})
            left_panned = _ref(driver, "gesture", target="outside", gesture="pan_release")["drawer"]
            assert left_panned["center"]["x"] > left_zoomed["center"]["x"]
            assert left_panned["center"]["y"] > left_zoomed["center"]["y"]
            _capture(driver, f"pin-{format}-full-left.png")
            next_pin = _ref(driver, "pin_control", target="next")["drawer"]
            assert next_pin["pin_index"] == 1
            if format == "epub":
                assert not next_pin["full_image"]
                assert not next_pin.get("zoom_in") and not next_pin.get("zoom_out")
                assert not next_pin.get("control_radius") and not next_pin.get("dots_background")
            else:
                assert not next_pin["full_image"] and next_pin["scale"] == pytest.approx(fit)
            restored = _ref(driver, "pin_control", target="previous")["drawer"]
            assert restored["full_image"] and restored["scale"] == pytest.approx(left_zoomed["scale"])
            assert restored["center"] == pytest.approx(left_panned["center"])
            _ref(driver, "close_book")
            stop(process)
            process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library,
                             initialize_settings=False)
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            restored = _ref(driver, "open_pin")["drawer"]
            assert restored["full_image"] and restored["scale"] == pytest.approx(left_zoomed["scale"])
            assert restored["center"] == pytest.approx(left_panned["center"])
            if format == "epub":
                assert restored["original_image"] and restored["source_size"] == {"w": 600, "h": 800}
        finally:
            stop(process)


def test_pin_count_preserves_centered_footer_items_in_both_rotations():
    with tempfile.TemporaryDirectory(prefix="zen-pin-center-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "center.epub"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            for mode in (0, 1):
                _ref(driver, "resize", mode=mode)
                for preset in (4, 5):
                    _ref(driver, "pin_preset", index=preset)
                    before = _ref(driver, "paint")
                    _ref(driver, "pin", page=3)
                    after = _ref(driver, "paint")
                    _assert_pin_padding(after)
                    tolerance = 4 * min(after["screen"]["w"], after["screen"]["h"]) / 600
                    assert abs(after["footer_page_center"] - after["screen"]["w"] / 2) <= tolerance
                    assert abs(after["footer_page_center"] - before["footer_page_center"]) <= tolerance
                    if preset == 5:
                        right = after["footer_percentage"]
                        assert abs(right["x"] - before["footer_percentage"]["x"]) <= tolerance
                        gap = right["x"] - after["pin_footer"]["x"] - after["pin_footer"]["w"]
                        assert gap >= tolerance
                    _assert_pin_alignment(driver, after, f"pin-center-{mode}-{preset}.png")
                    _ref(driver, "remove")
                    removed = _ref(driver, "paint")
                    assert not removed.get("pin_footer")
                    assert abs(removed["footer_page_center"] - before["footer_page_center"]) <= tolerance
        finally:
            stop(process)


def test_pin_control_visibility_and_footer_space():
    with tempfile.TemporaryDirectory(prefix="zen-pin-visibility-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "pins.epub"
        _write_book(book)
        socket = root / "driver.sock"
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            empty = _ref(driver, "paint")
            assert empty["footer_visible"] and not empty.get("pin_footer")
            _ref(driver, "enabled", enabled=False)
            native = _ref(driver, "paint")
            assert native["footer_bar_width"] == empty["footer_bar_width"]
            assert native["footer_text"] == empty["footer_text"]
            _ref(driver, "enabled", enabled=True)
            _ref(driver, "pin", page=3)
            one = _ref(driver, "paint")
            _assert_pin_padding(one)
            assert one["pin_footer"] and one["footer_bar_width"] < empty["footer_bar_width"]
            image = Image.open(_capture(driver, "pin-count-outline.png")).convert("RGB")
            bounds = one["pin_footer"]
            scale = min(one["screen"].values()) / 600
            content_height = max(one["pin_icon_bounds"]["h"], one["pin_count_bounds"]["h"])
            assert bounds["h"] == content_height + 2 * math.ceil(3 * scale)
            assert bounds["h"] <= one["footer_bounds"]["h"]
            left, right = bounds["x"], bounds["x"] + bounds["w"]
            assert image.getpixel(((left + right) // 2, bounds["y"])) == (0, 0, 0)
            assert image.getpixel((right - 1, bounds["y"] + bounds["h"] // 2)) == (0, 0, 0)
            assert image.getpixel((left, bounds["y"])) != (0, 0, 0)
            for x_ratio, y_ratio in ((-0.09, 0.5), (1.09, 0.5), (0.5, -0.09)):
                opened = _ref(driver, "pin_control", target="footer", x_ratio=x_ratio, y_ratio=y_ratio)
                assert opened["drawer"], (x_ratio, y_ratio)
                _ref(driver, "close")
            for enabled in (False, True):
                assert driver.command("open_settings_page")["ok"]
                for label in ("Reader", "Appearance", "Bottom status bar", "Configure items", "Arrange items in status bar"):
                    if label not in driver.command("settings_page_state")["settings"]["labels"]:
                        continue
                    result = driver.command("settings_page_select", label=label)
                    assert result["ok"], (label, result)
                arranged = driver.command("arrange_page_state")["arrange"]
                assert arranged["labels"][0] == "Pinned pages"
                assert arranged["checked"][0] is not enabled
                assert not arranged["handle_visible"]
                assert driver.command("arrange_page_select", index=1, toggle=True)["ok"]
                assert driver.command("arrange_page_back")["ok"]
                assert driver.command("close_settings_page")["ok"]
                toggled = _ref(driver, "paint")
                assert toggled["footer_pinned_pages"] is enabled
                assert bool(toggled.get("pin_footer")) is enabled
            _ref(driver, "footer_enabled", enabled=False)
            hidden_one = _ref(driver, "paint")
            assert not hidden_one["footer_visible"] and not hidden_one.get("pin_footer")
            _ref(driver, "pin", page=6)
            for preset in range(1, 7):
                _ref(driver, "footer_enabled", enabled=True)
                _ref(driver, "pin_preset", index=preset)
                visible = _ref(driver, "paint")
                _ref(driver, "footer_enabled", enabled=False)
                hidden = _ref(driver, "paint")
                _assert_pin_padding(hidden)
                assert not hidden["footer_visible"]
                assert hidden["pin_footer"] == visible["pin_footer"], preset
                opened = _ref(driver, "pin_control", target="footer")
                assert opened["drawer"]
                _ref(driver, "close")
            _capture(driver, "pins-without-footer.png")
            _ref(driver, "resize", mode=1)
            rotated = _ref(driver, "paint")
            assert rotated["pin_footer"]["x"] > rotated["screen"]["w"] / 2
            assert rotated["pin_footer"]["y"] > rotated["screen"]["h"] / 2
            _ref(driver, "footer_enabled", enabled=True)
            visible = _ref(driver, "paint")
            assert visible["pin_footer"] == rotated["pin_footer"]
            _ref(driver, "footer_enabled", enabled=False)
            _ref(driver, "close_book")
            assert driver.open_book(book)["ok"]
            _wait_reader(driver)
            restored = _ref(driver, "paint")
            assert not restored["footer_visible"] and restored["pin_footer"]
            _ref(driver, "remove")
            assert not _ref(driver, "paint").get("pin_footer")
            _ref(driver, "footer_enabled", enabled=True)
            assert _ref(driver, "paint")["pin_footer"]
            _ref(driver, "remove")
            zero = _ref(driver, "paint")
            assert not zero.get("pin_footer")
            _ref(driver, "enabled", enabled=False)
            native = _ref(driver, "paint")
            assert native["footer_bar_width"] == zero["footer_bar_width"]
        finally:
            stop(process)
