#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${ZEN_UI_DOCKER_PLATFORM:-linux/amd64}"
SUITE="${ZEN_UI_SUITE:-smoke}"
CACHE_VOLUME="zen-ui-koreader-cache-${PLATFORM//\//-}"

docker volume create "$CACHE_VOLUME" >/dev/null

docker run --rm \
    --platform "$PLATFORM" \
    --mount "type=bind,src=$ROOT,dst=/src,readonly" \
    --mount "type=volume,src=$CACHE_VOLUME,dst=/cache" \
    -w /work \
    ubuntu:24.04 \
    bash -lc 'set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    build-essential gettext git lua5.1 luarocks meson nasm ninja-build pkg-config xvfb \
    libsdl2-dev libfreetype6-dev libfontconfig1-dev libharfbuzz-dev libxtst-dev \
    libfribidi-dev libpng-dev libjpeg-dev libsqlite3-dev \
    python3 python3-pip python3-venv rsync curl ca-certificates
cp -a /src/. /work/
luarocks --tree=/work/.luarocks install luacheck
ZEN_UI_KOREADER_CACHE=/cache ZEN_UI_RUN_EMULATOR=1 \
    xvfb-run -s "-screen 0 800x600x24" ./spec/run "'"$SUITE"'"'
