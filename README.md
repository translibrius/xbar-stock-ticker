<p align="center">
  <img src="https://img.shields.io/badge/macOS-Menu_Bar-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS"/>
  <img src="https://img.shields.io/badge/xbar-Plugin-34C759?style=for-the-badge" alt="xbar"/>
  <img src="https://img.shields.io/badge/Zero-API_Keys-FF9500?style=for-the-badge" alt="No API Keys"/>
  <img src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge" alt="MIT"/>
</p>

<h1 align="center">Stock Ticker for xbar</h1>

<p align="center">
  <strong>Real-time US stock prices in your macOS menu bar.</strong><br/>
  No API keys. No accounts. No rate limit headaches. Just works.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/AAPL_%24266.18_%2B0.60%25-34C759?style=for-the-badge&labelColor=34C759&color=34C759" alt="pill green"/>
  <img src="https://img.shields.io/badge/TSLA_%24318.42_--1.20%25-FF3B30?style=for-the-badge&labelColor=FF3B30&color=FF3B30" alt="pill red"/>
  <img src="https://img.shields.io/badge/WIX_%24220.50-555555?style=for-the-badge&labelColor=555555&color=555555" alt="pill closed"/>
</p>

---

## Why This Exists

Every stock ticker app wants your email, an API key, a $9/mo subscription, or all three. This one is a single shell script that sits in your menu bar and shows you the price. That's it.

## Features

- **Pill-shaped badge** — colored, rounded menu bar item rendered with macOS system font
- **Smooth flash animation** — intensity-scaled color fade on price ticks (bigger moves = brighter flash)
- **Sub-second display refresh** — runs every 500ms, smart cache prevents API abuse
- **Zero configuration** — no API keys, no tokens, no accounts to create
- **Triple-redundant data** — automatic failover across 3 independent providers
- **Market-aware** — detects market hours, shows countdown to next open when closed
- **Rate limit resilient** — gracefully degrades to cached data on 429s
- **In-app settings** — switch symbols and display modes from the dropdown menu

## Display Modes

### Pill Badge (default)

A colored pill-shaped badge rendered with the macOS system font. Green for up, red for down, gray when closed. Smoothly highlights on price changes — intensity scales with the size of the move.

### Plain Text

Classic transparent text mode for a minimal look. Toggle between modes from **Settings > Display Mode** in the dropdown.

## Quick Start

**Prerequisites:** macOS, [xbar](https://xbarapp.com), Python 3.9+, curl

```bash
# Clone anywhere you like
git clone https://github.com/translibrius/xbar-stock-ticker.git
cd xbar-stock-ticker

# Run the installer (symlinks plugin + builds pill renderer)
./install.sh

# Refresh xbar — done.
```

The installer symlinks the plugin into your xbar plugins directory and compiles the pill badge renderer. No files are copied — updates are a `git pull` away.

**Manual install** (text-only mode — no build step):

```bash
ln -s "$(pwd)/stock_ticker.500ms.sh" "$HOME/Library/Application Support/xbar/plugins/"
```

## Configuration

**From the dropdown menu** (recommended): Click the ticker in your menu bar, then go to **Settings > Change Symbol** and pick from the list — or choose **Custom Symbol…** to type any US ticker.

**From the command line:**

```bash
# Set symbol via environment variable
export XBAR_STOCK_SYMBOL=TSLA
```

**Edit the script** (line 11):

```bash
SYMBOL="${XBAR_STOCK_SYMBOL:-WIX}"   # Change WIX to any US ticker
```

Works with any US-listed stock — `AAPL`, `GOOG`, `MSFT`, `TSLA`, `AMZN`, `NVDA`, `META`, etc.

## Architecture

```
xbar (500ms interval)
  |
  |-- Cache hit (<10s old)?
  |     \-- Yes -> render instantly (no network)
  |
  \-- No -> fetch quote
        |
        |-- Provider 1: Yahoo v7/quote (cookie+crumb auth, richest data)
        |-- Provider 2: Yahoo v8/chart (no auth, good fallback)
        \-- Provider 3: Stooq CSV (last resort, always available)
        |
        \-- Cache result -> render
```

**Cache layer**: The script is called every 500ms by xbar for smooth animations, but only hits the network every 10 seconds. In between, it serves from a local JSON cache.

**Pill renderer**: A compiled Swift helper (`.pill_render`) renders text onto a pill-shaped PNG using the macOS system font. The binary is ~70KB and runs in ~50ms. If not present, the plugin falls back to plain text mode.

**Flash animation**: When the price ticks, the pill smoothly fades from a bright highlight back to its steady color over 4 seconds using eased interpolation. The flash intensity scales with the size of the price move — tiny ticks are barely visible, while large swings get a full highlight.

## Files

| File | Purpose |
|------|---------|
| `stock_ticker.500ms.sh` | The plugin |
| `.pill_render.swift` | Source for the pill badge renderer |
| `install.sh` | One-command installer (symlink + compile) |
| `uninstall.sh` | Clean removal of plugin and all generated files |
| `.pill_render` | Compiled Swift binary (lives in plugins dir, gitignored) |
| `.ticker_prefs.json` | User preferences — display mode, symbol (auto-generated) |
| `.*_state.json` | Tracks last price + tick direction (auto-generated) |
| `.*_auth.json` | Yahoo cookie+crumb cache (auto-generated) |
| `.*_cache.json` | Quote data cache (auto-generated) |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Nothing in menu bar | Make sure xbar is running and the script is `chmod +x` |
| Shows `---` for price | Check your internet connection, try "Refresh now" from dropdown |
| No pill badge | Build `.pill_render` with `swiftc` (see Quick Start) |
| Stale price | Click "Refresh now" — if persistent, delete `.*_cache.json` files |
| Wrong symbol | Use Settings > Change Symbol in the dropdown |

## Uninstall

```bash
cd xbar-stock-ticker
./uninstall.sh
```

Removes the symlink, compiled binary, and all generated state/cache files. Then delete this folder if you like.

## License

MIT — do whatever you want with it.
