#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
CANONICAL_PLUGIN_DIR_NAME="zenos.koplugin"
COMPAT_PLUGIN_DIR_NAME="zen_ui.koplugin"
DEV_MODE=false

case "${1:-}" in
  --dev)
    DEV_MODE=true
    shift
    ;;
  "")
    ;;
  *)
    echo "Usage: $0 [--dev]" >&2
    exit 1
    ;;
esac

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--dev]" >&2
  exit 1
fi

if [[ "$DEV_MODE" == true ]]; then
  ENV_FILE="$REPO_ROOT/.env"
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: missing development configuration: $ENV_FILE" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$ENV_FILE"
  if [[ -z "${KOREADER_DIR:-}" || ! -d "$KOREADER_DIR" ]]; then
    echo "Error: KOREADER_DIR must point to a KOReader checkout" >&2
    exit 1
  fi
  if [[ ! -x "$KOREADER_DIR/kodev" ]]; then
    echo "Error: KOReader development command not found: $KOREADER_DIR/kodev" >&2
    exit 1
  fi

  DEV_PLUGIN_DIR="$KOREADER_DIR/plugins/$CANONICAL_PLUGIN_DIR_NAME"
fi

for cmd in rsync zip mktemp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

if ! command -v pyftsubset >/dev/null 2>&1; then
  echo "Error: pyftsubset is required to subset SymbolsNerdFont-Regular.ttf (install fonttools)" >&2
  exit 1
fi

DIST_DIR="$REPO_ROOT/dist"
CANONICAL_OUT_ZIP="$DIST_DIR/${CANONICAL_PLUGIN_DIR_NAME}.zip"
COMPAT_OUT_ZIP="$DIST_DIR/${COMPAT_PLUGIN_DIR_NAME}.zip"
STAGE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/koplugin-build.XXXXXX")"
PAYLOAD_DIR="$STAGE_PARENT/payload"
INLINE_ICON_MAP="$REPO_ROOT/common/inline_icon_map.lua"
NERD_FONT_NAME="SymbolsNerdFont-Regular.ttf"
NERD_FONT_SRC="$REPO_ROOT/fonts/$NERD_FONT_NAME"
NERD_FONT_STAGE="$PAYLOAD_DIR/fonts/$NERD_FONT_NAME"

cleanup() {
  rm -rf "$STAGE_PARENT"
}
trap cleanup EXIT

# Start each build from a clean output directory.
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$PAYLOAD_DIR"

# Stage only distributable plugin files.
rsync -a \
  --exclude '.git/' \
  --exclude '.github/' \
  --exclude '.vscode/' \
  --exclude 'dist/' \
  --exclude 'spec/' \
  --exclude 'docs/' \
  --exclude 'icon-packs/' \
  --exclude '.DS_Store' \
  --exclude '.gitignore' \
  --exclude '*.zip' \
  --exclude '*.sh' \
  --include 'LICENSE.md' \
  --include '/modules/filebrowser/metadata/LICENSES.md' \
  --exclude '*.md' \
  --exclude '*_includes/' \
  --exclude '_config.yml' \
  --exclude '*.yml/' \
  --include '/images/' \
  --include '/images/ornate-cover-frame.svg' \
  --exclude '/images/***' \
  --exclude '.venv/' \
  --exclude '*.py' \
  --exclude '*.luarocks' \
  --exclude '*.luacheckrc' \
  --exclude '__pycache__' \
  --exclude '.*' \
  "$REPO_ROOT/" "$PAYLOAD_DIR/"

UNICODE_LIST="$(mktemp "$STAGE_PARENT/nerd-font-unicodes.XXXXXX")"
unicode_escape_re='\\u\{([0-9A-Fa-f]+)\}'
while IFS= read -r line; do
  rest="$line"
  while [[ "$rest" =~ $unicode_escape_re ]]; do
    printf 'U+%s\n' "${BASH_REMATCH[1]}" >> "$UNICODE_LIST"
    rest="${rest#*${BASH_REMATCH[0]}}"
  done
done < "$INLINE_ICON_MAP"

if [[ ! -s "$UNICODE_LIST" ]]; then
  echo "Error: no inline icon codepoints found in $INLINE_ICON_MAP" >&2
  exit 1
fi

pyftsubset "$NERD_FONT_SRC" \
  --unicodes-file="$UNICODE_LIST" \
  --output-file="$NERD_FONT_STAGE" \
  --drop-tables+=PfEd \
  --name-IDs='*' \
  --name-languages='*'

create_archive() {
  local plugin_name="$1"
  local output_zip="$2"
  local stage_dir="$STAGE_PARENT/$plugin_name"

  mkdir -p "$stage_dir"
  rsync -a "$PAYLOAD_DIR/" "$stage_dir/"
  rm -f "$output_zip"
  (
    cd "$STAGE_PARENT"
    zip -rq "$output_zip" "$plugin_name"
  )
  rm -rf "$stage_dir"
}

create_archive "$CANONICAL_PLUGIN_DIR_NAME" "$CANONICAL_OUT_ZIP"
create_archive "$COMPAT_PLUGIN_DIR_NAME" "$COMPAT_OUT_ZIP"

echo "Created KOReader plugin zips:"
echo "  $CANONICAL_OUT_ZIP"
echo "  $COMPAT_OUT_ZIP"

if [[ "$DEV_MODE" == true ]]; then
  if [[ -e "$KOREADER_DIR/plugins/$COMPAT_PLUGIN_DIR_NAME" ]]; then
    echo "Error: legacy development plugin still exists: $KOREADER_DIR/plugins/$COMPAT_PLUGIN_DIR_NAME" >&2
    echo "Start KOReader once to migrate it, or remove it before deploying $CANONICAL_PLUGIN_DIR_NAME." >&2
    exit 1
  fi
  mkdir -p "$DEV_PLUGIN_DIR"
  rsync -a --delete "$PAYLOAD_DIR/" "$DEV_PLUGIN_DIR/"
  echo "Deployed plugin to: $DEV_PLUGIN_DIR"

  find_luajit_child() {
    local parent_pid="$1"
    local child_pid
    local command
    local result
    for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
      command="$(ps -p "$child_pid" -o comm= 2>/dev/null || true)"
      if [[ "$command" == *luajit* ]]; then
        printf '%s\n' "$child_pid"
        return
      fi
      result="$(find_luajit_child "$child_pid")"
      if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return
      fi
    done
  }

  focus_koreader() {
    local kodev_pid="$1"
    local reader_pid
    local attempt
    [[ "$(uname)" == Darwin ]] || return

    for attempt in {1..120}; do
      reader_pid="$(find_luajit_child "$kodev_pid")"
      if [[ -n "$reader_pid" ]]; then
        osascript \
          -e "tell application \"System Events\"" \
          -e "tell (first process whose unix id is $reader_pid)" \
          -e 'if not (exists window 1) then error "KOReader window not ready"' \
          -e 'set visible to true' \
          -e 'repeat 3 times' \
          -e 'set frontmost to true' \
          -e 'perform action "AXRaise" of window 1' \
          -e 'try' \
          -e 'set value of attribute "AXMain" of window 1 to true' \
          -e 'set value of attribute "AXFocused" of window 1 to true' \
          -e 'end try' \
          -e 'delay 0.25' \
          -e 'end repeat' \
          -e 'end tell' \
          -e 'end tell' \
          >/dev/null 2>&1 && return
      fi
      sleep 0.5
    done
  }

  terminate_process_tree() {
    local pid="$1"
    local child_pid
    for child_pid in $(pgrep -P "$pid" 2>/dev/null || true); do
      terminate_process_tree "$child_pid"
    done
    kill "$pid" 2>/dev/null || true
  }

  if [[ -f "$REPO_ROOT/.dev-kodev.pid" ]]; then
    kodev_pid="$(<"$REPO_ROOT/.dev-kodev.pid")"
    if [[ "$kodev_pid" =~ ^[0-9]+$ ]] && kill -0 "$kodev_pid" 2>/dev/null; then
      terminate_process_tree "$kodev_pid"
    fi
  fi

  (
    cd "$KOREADER_DIR"
    printf '%s\n' "$BASHPID" > "$REPO_ROOT/.dev-kodev.pid"
    focus_koreader "$BASHPID" &
    exec "$KOREADER_DIR/kodev" run
  )
fi
