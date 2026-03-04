#!/bin/bash
# Copy built assets from the parent NetHack-Factorio project into web-ui/public/
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEB_UI="$(dirname "$SCRIPT_DIR")"
PROJECT="$(dirname "$WEB_UI")"

echo "Copying assets from $PROJECT to $WEB_UI/public/"

# WASM binary
cp "$PROJECT/build/nethack.wasm" "$WEB_UI/public/nethack.wasm"
echo "  nethack.wasm"

# Sprite sheets
mkdir -p "$WEB_UI/public/sheets"
cp "$PROJECT/graphics/sheets/"*.png "$WEB_UI/public/sheets/"
echo "  sprite sheets"

# Ground tiles
mkdir -p "$WEB_UI/public/tiles"
cp "$PROJECT/graphics/tiles/"*.png "$WEB_UI/public/tiles/"
echo "  ground tiles"

# Generate nethack-data.json from data directories
python3 "$PROJECT/build/embed_data.py" "$WEB_UI/public/nethack-data.json" \
  "$PROJECT/NetHack/dat" "$PROJECT/build/datout/"
echo "  nethack-data.json"

# Generate tile-config.json (via convert_tiles.py --web-json)
python3 "$PROJECT/build/convert_tiles.py" "$PROJECT/NetHack" \
  --web-json "$WEB_UI/public/tile-config.json"
echo "  tile-config.json"

echo "Done."
