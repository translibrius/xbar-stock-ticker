#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$HOME/Library/Application Support/xbar/plugins"

echo "Installing Stock Ticker for xbar..."

# Ensure xbar plugins directory exists
if [ ! -d "$PLUGIN_DIR" ]; then
    echo "Error: xbar plugins directory not found at:"
    echo "  $PLUGIN_DIR"
    echo "Install xbar first: https://xbarapp.com"
    exit 1
fi

# Symlink the plugin script
LINK="$PLUGIN_DIR/stock_ticker.1s.sh"
if [ -L "$LINK" ]; then
    rm "$LINK"
elif [ -f "$LINK" ]; then
    echo "Warning: replacing existing stock_ticker.1s.sh (was a regular file)"
    rm "$LINK"
fi
ln -s "$REPO_DIR/stock_ticker.1s.sh" "$LINK"
echo "  Linked stock_ticker.1s.sh → plugins/"

# Build the pill renderer (optional — text mode works without it)
SWIFT_SRC="$REPO_DIR/.pill_render.swift"
PILL_BIN="$PLUGIN_DIR/.pill_render"
if command -v swiftc &>/dev/null && [ -f "$SWIFT_SRC" ]; then
    echo "  Compiling pill renderer..."
    swiftc -O -o "$PILL_BIN" "$SWIFT_SRC" -framework Cocoa 2>/dev/null && \
        echo "  Built .pill_render (pill badge mode enabled)" || \
        echo "  Skipped pill renderer (compile failed — text mode will be used)"
else
    echo "  Skipped pill renderer (swiftc not found — text mode will be used)"
fi

echo ""
echo "Done! Refresh xbar to see your stock ticker."
echo "Click the ticker → Settings to change symbol or display mode."
