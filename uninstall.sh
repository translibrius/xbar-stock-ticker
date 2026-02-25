#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$HOME/Library/Application Support/xbar/plugins"

echo "Uninstalling Stock Ticker for xbar..."

# Remove symlink (check both old and new filenames)
for LINK in "$PLUGIN_DIR/stock_ticker.500ms.sh" "$PLUGIN_DIR/stock_ticker.1s.sh"; do
    if [ -L "$LINK" ]; then
        rm "$LINK"
        echo "  Removed plugin symlink: $(basename "$LINK")"
    elif [ -f "$LINK" ]; then
        echo "  Warning: $(basename "$LINK") is a regular file (not installed via install.sh)"
        read -p "  Delete it anyway? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && rm "$LINK" && echo "  Removed" || echo "  Skipped"
    fi
done

# Remove compiled binary
if [ -f "$PLUGIN_DIR/.pill_render" ]; then
    rm "$PLUGIN_DIR/.pill_render"
    echo "  Removed pill renderer binary"
fi

# Remove generated config/state files
removed=0
for pattern in ".ticker_prefs.json" ".*_state.json" ".*_cache.json" ".*_auth.json"; do
    for f in "$PLUGIN_DIR"/$pattern; do
        [ -f "$f" ] && rm "$f" && removed=$((removed + 1))
    done
done
[ "$removed" -gt 0 ] && echo "  Removed $removed state/cache files"

echo ""
echo "Done! Refresh xbar to apply."
echo "You can delete this repo folder too if you like."
