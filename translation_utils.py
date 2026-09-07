#!/usr/bin/env python3
"""
Extract translatable strings from all Lua source files and compare against .po files.

Usage:
    python3 translation_utils.py --sync [--locale LOCALE]

Flags:
    --sync          Remove dead strings, add and translate missing strings, then alphabetize
    --update-po     Write missing msgids into all (or specified) locale .po files
    --remove-dead   Remove msgids from .po files not found in any Lua source
    --alphabetize   Sort all entries in .po files alphabetically by msgid
    --list-missing      Print msgids absent from .po files entirely and exit
    --list-untranslated Print msgids present in .po but with empty msgstr and exit
    --locale LOCALE Only process one locale (e.g. zh_CN)
    --show-dead     Show msgids in .po files not found in any Lua source
"""

import argparse
import ast
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

# Directories relative to this script
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCALES_DIR = os.path.join(SCRIPT_DIR, "locales")

# Lua directories to scan (skip test/build artefacts)
LUA_DIRS = [
    SCRIPT_DIR,
]
LUA_EXCLUDE_DIRS = {"node_modules", ".git", "dist", "spec"}
LUA_EXCLUDE_FILES = {"extract_translatable_strings.py"}

GOOGLE_TRANSLATE_URL = "https://translation.googleapis.com/language/translate/v2"
GOOGLE_TRANSLATE_BATCH_SIZE = 128
GOOGLE_LOCALES = {
    "pt_BR": "pt",
    "pt_PT": "pt-PT",
    "zh_CN": "zh-CN",
    "zh_HK": "zh-TW",
    "zh_MO": "zh-TW",
    "zh_TW": "zh-TW",
}

# ---------------------------------------------------------------------------
# Patterns for extractable string calls
# ---------------------------------------------------------------------------
# _("..."), __("..."), and gettext("...")
_GETTEXT_CALL = r"(?<![\w_])(?:_|__|gettext)"
_RE_GETTEXT_DQ = re.compile(_GETTEXT_CALL + r'\(\s*"((?:[^"\\]|\\.)*)"\s*\)', re.DOTALL)
_RE_GETTEXT_SQ = re.compile(_GETTEXT_CALL + r"\(\s*'((?:[^'\\]|\\.)*)'\s*\)", re.DOTALL)

# C_("context", "string") — context-aware gettext; we extract the string part
_RE_CGETTEXT_DQ = re.compile(r'(?<![\w_])C_\(\s*"[^"]*"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)', re.DOTALL)
_RE_CGETTEXT_SQ = re.compile(r"(?<![\w_])C_\(\s*'[^']*'\s*,\s*'((?:[^'\\]|\\.)*)'\s*\)", re.DOTALL)

# Multiline Lua long strings inside _([[...]]) — uncommon but possible
_RE_GETTEXT_LS = re.compile(_GETTEXT_CALL + r'\(\s*\[\[(.*?)\]\]\s*\)', re.DOTALL)

ALL_PATTERNS = [
    _RE_GETTEXT_DQ,
    _RE_GETTEXT_SQ,
    _RE_CGETTEXT_DQ,
    _RE_CGETTEXT_SQ,
    _RE_GETTEXT_LS,
]


def unescape_lua(s: str) -> str:
    """Convert Lua escape sequences to the canonical form used in .po files."""
    # Only handle common escapes; Lua and Python share most of them
    return (
        s.replace("\\n", "\n")
         .replace("\\t", "\t")
         .replace('\\"', '"')
         .replace("\\'", "'")
         .replace("\\\\", "\\")
    )


def blank_lua_comments(src: str) -> str:
    """Blank Lua comments while preserving offsets and line numbers."""
    chars = list(src)
    i = 0
    while i < len(src):
        if src[i] in "\"'":
            quote = src[i]
            i += 1
            while i < len(src) and src[i] != quote:
                i += 2 if src[i] == "\\" else 1
            i += 1
            continue

        long_string = re.match(r"\[(=*)\[", src[i:])
        if long_string:
            end = src.find("]" + long_string.group(1) + "]", i + len(long_string.group(0)))
            i = len(src) if end < 0 else end + len(long_string.group(0))
            continue

        if not src.startswith("--", i):
            i += 1
            continue

        comment_start = i
        long_comment = re.match(r"--\[(=*)\[", src[i:])
        if long_comment:
            end_marker = "]" + long_comment.group(1) + "]"
            end = src.find(end_marker, i + len(long_comment.group(0)))
            i = len(src) if end < 0 else end + len(end_marker)
        else:
            end = src.find("\n", i)
            i = len(src) if end < 0 else end
        for index in range(comment_start, i):
            if chars[index] != "\n":
                chars[index] = " "
    return "".join(chars)


def extract_from_file(path: str) -> list[tuple[str, int, str]]:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            src = f.read()
    except OSError:
        return []

    matches = []
    scan_src = blank_lua_comments(src)
    for pat in ALL_PATTERNS:
        for m in pat.finditer(scan_src):
            matches.append((m.start(), m.end(), unescape_lua(m.group(1))))

    found = []
    lines = src.splitlines()
    line = 1
    cursor = 0
    for start, end, msgid in sorted(matches):
        line += src.count("\n", cursor, start)
        end_line = line + src.count("\n", start, end)
        context = " ".join(
            part.strip()
            for part in lines[max(0, line - 2):min(len(lines), end_line + 1)]
            if part.strip()
        )
        context = re.sub(r"\s+", " ", context)
        if len(context) > 240:
            context = context[:237].rstrip() + "..."
        found.append((msgid, line, context))
        cursor = start
    return found


def collect_lua_strings() -> dict[str, list[tuple[str, int, str]]]:
    """Return source locations and nearby code for every translatable string."""
    result: dict[str, list[tuple[str, int, str]]] = {}

    for root, dirs, files in os.walk(SCRIPT_DIR):
        # Prune excluded directories in-place
        dirs[:] = sorted(d for d in dirs if d not in LUA_EXCLUDE_DIRS)
        for fname in sorted(files):
            if not fname.endswith(".lua"):
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, SCRIPT_DIR)
            for msgid, line, context in extract_from_file(fpath):
                result.setdefault(msgid, []).append((rel, line, context))

    return result


# ---------------------------------------------------------------------------
# .po file helpers
# ---------------------------------------------------------------------------

def po_header(po_path: str) -> str:
    """Return the raw header block (everything before the first non-empty msgid)."""
    with open(po_path, encoding="utf-8") as f:
        content = f.read()
    return re.split(r"\n\n+", content.rstrip("\n"), maxsplit=1)[0]


def parse_po_text(content: str) -> dict[str, str]:
    """Return {msgid: msgstr} from single- or multiline PO entries."""
    entries: dict[str, str] = {}
    msgid = msgstr = None
    field = None

    def flush() -> None:
        nonlocal msgid, msgstr, field
        if msgid and msgstr is not None:
            entries[msgid] = msgstr
        msgid = msgstr = None
        field = None

    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line:
            flush()
        elif line.startswith("msgid "):
            if msgid is not None:
                flush()
            msgid = ast.literal_eval(line[6:].strip())
            field = "msgid"
        elif line.startswith("msgstr "):
            msgstr = ast.literal_eval(line[7:].strip())
            field = "msgstr"
        elif line.startswith('"') and field:
            value = ast.literal_eval(line)
            if field == "msgid":
                msgid += value
            else:
                msgstr += value
    flush()
    return entries


def parse_po(po_path: str) -> dict[str, str]:
    """Return {msgid: msgstr} for all entries in a .po file."""
    try:
        with open(po_path, encoding="utf-8") as f:
            return parse_po_text(f.read())
    except OSError:
        return {}


def msgid_to_po_line(s: str) -> str:
    """Encode a string as a .po-compatible quoted value."""
    escaped = (s.replace("\\", "\\\\")
                .replace('"', '\\"')
                .replace("\n", "\\n")
                .replace("\t", "\\t")
                .replace("\r", "\\r"))
    return escaped


def format_entry(msgid: str, msgstr: str = "", sources: list[tuple[str, int, str]] | None = None) -> str:
    lines = []
    if sources:
        lines.append(f"#. Context: {sources[0][2]}")
        refs = dict.fromkeys(f"{os.path.basename(path)}:{line}" for path, line, _context in sources)
        lines.append("#: " + " ".join(refs))
    lines.extend((
        f'msgid "{msgid_to_po_line(msgid)}"',
        f'msgstr "{msgid_to_po_line(msgstr)}"',
    ))
    return "\n".join(lines) + "\n"


def rewrite_po(po_path: str, existing: dict[str, str], lua_strings: dict[str, list[tuple[str, int, str]]], to_add: list[str], remove_dead: bool, alphabetize: bool = False) -> tuple[int, int]:
    """Rewrite a .po file, removing dead entries and/or appending new ones. Returns (removed, added)."""
    header = po_header(po_path)
    parts = [header.rstrip("\n")]
    removed = 0

    kept = {}
    for msgid, msgstr in existing.items():
        if remove_dead and msgid not in lua_strings:
            removed += 1
            continue
        kept[msgid] = msgstr

    for msgid in sorted(to_add):
        kept[msgid] = ""

    entry_iter = sorted(kept.items(), key=lambda kv: kv[0].lower()) if alphabetize else list(kept.items())
    for msgid, msgstr in entry_iter:
        parts.append(format_entry(msgid, msgstr, lua_strings.get(msgid)).rstrip("\n"))

    added = len(to_add)

    with open(po_path, "w", encoding="utf-8") as f:
        f.write("\n\n".join(parts) + "\n")

    return removed, added


def write_updated_po(po_path: str, existing: dict[str, str], to_add: list[str], lua_strings: dict[str, list[tuple[str, int, str]]]) -> None:
    """Append missing msgids (with empty msgstr) to a .po file."""
    with open(po_path, encoding="utf-8", errors="replace") as f:
        content = f.read()

    if not content.endswith("\n\n"):
        content = content.rstrip("\n") + "\n\n"

    additions = []
    for msgid in sorted(to_add):
        additions.append(format_entry(msgid, sources=lua_strings.get(msgid)))

    with open(po_path, "w", encoding="utf-8") as f:
        f.write(content + "\n".join(additions))

    print(f"  -> wrote {len(additions)} new entries to {os.path.relpath(po_path, SCRIPT_DIR)}")


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def get_missing_per_locale(locale: str | None = None) -> dict[str, list[str]]:
    """Return {locale: [msgid, ...]} for msgids present in Lua but absent from the .po file entirely."""
    lua_strings = collect_lua_strings()
    po_files = sorted(f for f in os.listdir(LOCALES_DIR) if f.endswith(".po"))
    if locale:
        po_files = [f for f in po_files if f == f"{locale}.po"]

    result: dict[str, list[str]] = {}
    for po_file in po_files:
        loc = po_file[:-3]
        existing = parse_po(os.path.join(LOCALES_DIR, po_file))
        result[loc] = sorted(s for s in lua_strings if s not in existing)
    return result


def get_untranslated_per_locale(locale: str | None = None) -> dict[str, list[str]]:
    """Return {locale: [msgid, ...]} for entries present in .po but with an empty msgstr."""
    po_files = sorted(f for f in os.listdir(LOCALES_DIR) if f.endswith(".po"))
    if locale:
        po_files = [f for f in po_files if f == f"{locale}.po"]

    result: dict[str, list[str]] = {}
    for po_file in po_files:
        loc = po_file[:-3]
        existing = parse_po(os.path.join(LOCALES_DIR, po_file))
        result[loc] = sorted(msgid for msgid, msgstr in existing.items() if not msgstr)
    return result


def apply_translations(locale: str, translations: dict[str, str]) -> int:
    """Write a {msgid: msgstr} dict into the given locale's .po file. Returns number of entries updated."""
    po_path = os.path.join(LOCALES_DIR, f"{locale}.po")
    existing = parse_po(po_path)
    existing.update({k: v for k, v in translations.items() if v})
    lua_strings = collect_lua_strings()
    rewrite_po(po_path, existing, lua_strings, [], remove_dead=False, alphabetize=True)
    return sum(1 for v in translations.values() if v)


_FORMAT_TOKEN_RE = re.compile(r"%\d+(?=[hm]\b)|%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[A-Za-z%]|%\d+")


def _protect_format_tokens(text: str) -> tuple[str, list[str]]:
    """Replace format placeholders with markers that translation services preserve."""
    tokens: list[str] = []

    def replace(match: re.Match) -> str:
        tokens.append(match.group(0))
        return f"⟪ZENFMT{len(tokens) - 1}⟫"

    return _FORMAT_TOKEN_RE.sub(replace, text), tokens


def _restore_format_tokens(text: str, tokens: list[str]) -> str:
    """Restore protected format placeholders after translation."""
    for index, token in enumerate(tokens):
        marker = f"⟪ZENFMT{index}⟫"
        if text.count(marker) != 1:
            raise ValueError("translation changed a format placeholder marker")
        text = text.replace(marker, token)
    return text


def google_api_key() -> str | None:
    """Return the API key from the environment or the ignored project .env file."""
    if key := os.environ.get("GOOGLE_TRANSLATE_API_KEY"):
        return key
    try:
        with open(os.path.join(SCRIPT_DIR, ".env"), encoding="utf-8") as env_file:
            for line in env_file:
                name, separator, value = line.partition("=")
                if separator and name.strip() == "GOOGLE_TRANSLATE_API_KEY":
                    value = value.strip()
                    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                        value = value[1:-1]
                    return value or None
    except OSError:
        pass
    return None


def google_translate_batch(texts: list[str], locale: str, api_key: str, timeout: int = 30) -> list[str]:
    """Translate up to 128 English strings with Google Cloud Translation Basic."""
    protected = [_protect_format_tokens(text) for text in texts]
    body = json.dumps({
        "q": [text for text, _tokens in protected],
        "source": "en",
        "target": GOOGLE_LOCALES.get(locale, locale),
        "format": "text",
    }).encode("utf-8")
    request = urllib.request.Request(
        GOOGLE_TRANSLATE_URL,
        data=body,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "X-goog-api-key": api_key,
        },
        method="POST",
    )
    last_error = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                data = json.load(response)
            translations = data["data"]["translations"]
            if len(translations) != len(texts):
                raise ValueError("Google returned the wrong number of translations")
            if any(not item.get("translatedText") for item in translations):
                raise ValueError("Google returned an empty translation")
            return [
                _restore_format_tokens(item["translatedText"], tokens)
                for item, (_text, tokens) in zip(translations, protected)
            ]
        except (OSError, ValueError, KeyError, IndexError, TypeError, urllib.error.URLError) as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(5 * 2 ** attempt)
    raise RuntimeError(f"Google translation failed for {locale}: {last_error}")


def google_translate(text: str, locale: str, timeout: int = 30) -> str:
    """Translate one string with Google Cloud Translation Basic."""
    if locale == "en":
        return text
    api_key = google_api_key()
    if not api_key:
        raise RuntimeError("set GOOGLE_TRANSLATE_API_KEY in .env to use --sync translation")
    return google_translate_batch([text], locale, api_key, timeout)[0]


def translate_strings(locale: str, msgids: list[str]) -> dict[str, str]:
    """Translate msgids in Cloud Translation's maximum batch size."""
    if locale == "en":
        return {msgid: msgid for msgid in msgids}
    api_key = google_api_key()
    if not api_key:
        raise RuntimeError("set GOOGLE_TRANSLATE_API_KEY in .env to use --sync translation")
    translated = []
    for start in range(0, len(msgids), GOOGLE_TRANSLATE_BATCH_SIZE):
        translated.extend(google_translate_batch(
            msgids[start:start + GOOGLE_TRANSLATE_BATCH_SIZE], locale, api_key,
        ))
    return dict(zip(msgids, translated))


def sync_catalogs(po_files: list[str], lua_strings: dict[str, list[tuple[str, int, str]]]) -> None:
    """Fully synchronize catalogs, keeping each catalog atomic."""
    msgids = set(lua_strings)
    translation_error = None
    for po_file in sorted(po_files, key=lambda name: (name != "en.po", name)):
        locale = po_file[:-3]
        po_path = os.path.join(LOCALES_DIR, po_file)
        existing = parse_po(po_path)
        missing = sorted(msgids - set(existing))
        dead = sorted(set(existing) - msgids)
        synced = {msgid: existing.get(msgid, "") for msgid in msgids}
        untranslated = sorted(msgid for msgid, msgstr in synced.items() if not msgstr)

        print(
            f"[{locale}]  missing={len(missing)}  dead={len(dead)}  "
            f"untranslated={len(untranslated)}"
        )
        if untranslated:
            if translation_error is None:
                print(f"  -> translating {len(untranslated)} entries")
                try:
                    synced.update(translate_strings(locale, untranslated))
                except RuntimeError as exc:
                    translation_error = exc
                    print(f"  -> translation stopped; leaving empty entries", file=sys.stderr)
            else:
                print(f"  -> translation skipped after earlier failure")
        rewrite_po(po_path, synced, lua_strings, [], remove_dead=False, alphabetize=True)
        print(
            f"  -> {po_file}: removed={len(dead)} added={len(missing)} "
            f"untranslated={sum(not value for value in synced.values())} alphabetized=yes"
        )
    if translation_error:
        raise RuntimeError(
            f"catalogs were synchronized, but translation failed; rerun --sync. {translation_error}"
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sync", action="store_true", help="Remove dead entries, add and translate missing entries, and alphabetize")
    parser.add_argument("--update-po", action="store_true", help="Append missing msgids to .po files")
    parser.add_argument("--remove-dead", action="store_true", help="Remove msgids from .po files that no longer exist in Lua source")
    parser.add_argument("--alphabetize", action="store_true", help="Sort all entries in .po files alphabetically by msgid")
    parser.add_argument("--list-missing", action="store_true", help="Print msgids absent from .po files entirely and exit")
    parser.add_argument("--list-untranslated", action="store_true", help="Print msgids present in .po but with empty msgstr and exit")
    parser.add_argument("--locale", metavar="LOCALE", help="Only process this locale (e.g. zh_CN)")
    parser.add_argument("--show-dead", action="store_true", help="Show msgids in .po but not in Lua source")
    args = parser.parse_args()

    if args.sync and any((
        args.update_po,
        args.remove_dead,
        args.alphabetize,
        args.list_missing,
        args.list_untranslated,
        args.show_dead,
    )):
        parser.error("--sync cannot be combined with other action flags")

    if args.list_missing:
        for loc, msgids in get_missing_per_locale(args.locale).items():
            print(f"[{loc}]  {len(msgids)} missing")
            for s in msgids:
                print(f"  {repr(s)}")
        return

    if args.list_untranslated:
        for loc, msgids in get_untranslated_per_locale(args.locale).items():
            print(f"[{loc}]  {len(msgids)} untranslated")
            for s in msgids:
                print(f"  {repr(s)}")
        return

    print("Scanning Lua source files...")
    lua_strings = collect_lua_strings()
    print(f"  Found {len(lua_strings)} unique translatable strings\n")

    # Determine which .po files to process
    po_files = sorted(f for f in os.listdir(LOCALES_DIR) if f.endswith(".po"))
    if args.locale:
        target = f"{args.locale}.po"
        if target not in po_files:
            print(f"Error: {target} not found in {LOCALES_DIR}", file=sys.stderr)
            sys.exit(1)
        po_files = [target]

    if args.sync:
        try:
            sync_catalogs(po_files, lua_strings)
        except RuntimeError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            sys.exit(1)
        return

    for po_file in po_files:
        locale = po_file[:-3]
        po_path = os.path.join(LOCALES_DIR, po_file)
        existing = parse_po(po_path)

        missing = sorted(s for s in lua_strings if s not in existing)
        show_dead = args.show_dead or args.remove_dead
        dead = sorted(s for s in existing if s not in lua_strings) if show_dead else []

        print(f"[{locale}]  missing={len(missing)}  dead={len(dead) if show_dead else '?'}")

        if missing:
            print("  MISSING (in Lua, not in .po):")
            for s in missing:
                preview = repr(s)
                locations = [f"{path}:{line}" for path, line, _context in lua_strings[s]]
                print(f"    {preview}  <- {', '.join(locations[:2])}{'...' if len(locations) > 2 else ''}")

        if dead:
            print("  DEAD (in .po, not in Lua):")
            for s in dead:
                print(f"    {repr(s)}")

        need_write = (args.update_po and missing) or args.remove_dead or args.alphabetize
        if need_write:
            removed, added = rewrite_po(
                po_path, existing, lua_strings,
                missing if args.update_po else [],
                args.remove_dead,
                args.alphabetize,
            )
            if args.remove_dead and removed:
                print(f"  -> removed {removed} dead entries")
            if args.update_po and added:
                print(f"  -> added {added} new entries")
            if args.alphabetize:
                print(f"  -> alphabetized entries")

        print()


if __name__ == "__main__":
    main()
