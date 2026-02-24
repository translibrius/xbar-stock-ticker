#!/bin/bash
# <xbar.title>Stock Ticker</xbar.title>
# <xbar.version>v3.0</xbar.version>
# <xbar.author>translibrius</xbar.author>
# <xbar.desc>Real-time US stock price in your menu bar. Set SYMBOL below or via XBAR_STOCK_SYMBOL env var.</xbar.desc>
# <xbar.dependencies>bash,python3,curl</xbar.dependencies>

set -euo pipefail

# ──── CONFIGURATION ────────────────────────────────────────────────
SYMBOL="${XBAR_STOCK_SYMBOL:-WIX}"   # Change this to your ticker (e.g. AAPL, TSLA, GOOG)
# ───────────────────────────────────────────────────────────────────

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="${PLUGIN_DIR}/.${SYMBOL}_state.json"

exec python3 - "$STATE_FILE" "$SYMBOL" "$@" <<'PY'
import sys, json, os, math, csv, io, time, subprocess, struct, zlib, base64
from datetime import datetime

state_path, default_symbol = sys.argv[1], sys.argv[2]
simulate_mode = "--simulate" in sys.argv
plugin_dir = os.path.dirname(os.path.abspath(state_path))
# User preferences
prefs_path = os.path.join(plugin_dir, ".ticker_prefs.json")

# Symbol can be overridden via prefs file (set from dropdown UI)
_prefs_early = {}
try:
    with open(prefs_path) as f: _prefs_early = json.load(f)
except Exception: pass
symbol = _prefs_early.get("symbol", default_symbol).strip().upper() or default_symbol

stooq_sym = f"{symbol.lower()}.us"
# Per-symbol file paths
state_path = os.path.join(plugin_dir, f".{symbol}_state.json")
auth_path = os.path.join(plugin_dir, f".{symbol}_auth.json")
cache_path = os.path.join(plugin_dir, f".{symbol}_cache.json")

UA = "Mozilla/5.0"
AUTH_MAX_AGE = 86400   # Cache cookie+crumb for 24 hours
FETCH_INTERVAL = 10    # Fetch from Yahoo at most every 10 seconds
DISPLAY_PILL = "pill"
DISPLAY_TEXT = "text"

# ---- Handle settings commands (called via xbar shell= actions) ----
if "--set-display" in sys.argv:
    idx = sys.argv.index("--set-display")
    mode = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else DISPLAY_PILL
    try:
        p = {}
        try:
            with open(prefs_path) as f: p = json.load(f)
        except Exception: pass
        p["display"] = mode
        with open(prefs_path, "w") as f: json.dump(p, f)
    except Exception: pass
    sys.exit(0)

if "--set-symbol" in sys.argv:
    idx = sys.argv.index("--set-symbol")
    new_sym = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else ""
    new_sym = new_sym.strip().upper()
    if new_sym:
        try:
            p = {}
            try:
                with open(prefs_path) as f: p = json.load(f)
            except Exception: pass
            p["symbol"] = new_sym
            with open(prefs_path, "w") as f: json.dump(p, f)
        except Exception: pass
    sys.exit(0)

if "--prompt-symbol" in sys.argv:
    # Show a native macOS input dialog for custom ticker symbol
    import subprocess as _sp
    current = _prefs_early.get("symbol", default_symbol)
    script = (
        f'set t to text returned of (display dialog "Enter a US stock ticker symbol:" '
        f'default answer "{current}" with title "Stock Ticker" '
        f'buttons {{"Cancel", "OK"}} default button "OK")\n'
        f'return t'
    )
    try:
        r = _sp.run(["osascript", "-e", script], capture_output=True, text=True, timeout=60)
        new_sym = (r.stdout or "").strip().upper()
        if r.returncode == 0 and new_sym:
            p = {}
            try:
                with open(prefs_path) as f: p = json.load(f)
            except Exception: pass
            p["symbol"] = new_sym
            with open(prefs_path, "w") as f: json.dump(p, f)
    except Exception:
        pass
    sys.exit(0)

# ---- utility functions ----

def now_str():
    return datetime.now().strftime("%H:%M:%S")

def fmt_num(x, nd=2):
    if x is None or (isinstance(x, float) and (math.isnan(x) or math.isinf(x))):
        return "—"
    try:
        return f"{x:,.{nd}f}"
    except Exception:
        return "—"

def fmt_int(x):
    if x is None:
        return "—"
    try:
        return f"{int(x):,d}"
    except Exception:
        return "—"

def fmt_big(n):
    if n is None:
        return "—"
    try:
        n = float(n)
    except Exception:
        return "—"
    units = [("", 1), ("K", 1e3), ("M", 1e6), ("B", 1e9), ("T", 1e12)]
    sign = "-" if n < 0 else ""
    n = abs(n)
    for suf, scale in reversed(units):
        if n >= scale:
            return f"{sign}{n/scale:.2f}{suf}"
    return f"{sign}{n:.0f}"

def load_json(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return {}

def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)

def color_for_pct(pct):
    if pct is None:
        return "#9AA0A6"
    if pct > 0:
        return "#34C759"
    if pct < 0:
        return "#FF3B30"
    return "#9AA0A6"

# Flash sequence on price change — fades from bright highlight to normal over 3s
FLASH_UP   = ["#FFFFFF", "#7AFF9B", "#34C759"]   # white → bright green → green
FLASH_DOWN = ["#FFFFFF", "#FF7B73", "#FF3B30"]   # white → bright red   → red
FLASH_DURATION = 3  # seconds

def flash_color(pct, direction, secs_since_change):
    """Return a flash color if within FLASH_DURATION of a price change, else normal."""
    if secs_since_change is None or secs_since_change >= FLASH_DURATION:
        return color_for_pct(pct)
    idx = int(secs_since_change)  # 0, 1, 2
    if direction == "up":
        return FLASH_UP[min(idx, len(FLASH_UP) - 1)]
    elif direction == "down":
        return FLASH_DOWN[min(idx, len(FLASH_DOWN) - 1)]
    return color_for_pct(pct)

def arrow_for_dir(d):
    return {"up": "▲", "down": "▼", "flat": "▶"}.get(d, "▶")

# ---- Pill renderer: native macOS font via compiled Swift helper ----

_pill_render_bin = os.path.join(plugin_dir, ".pill_render")
_pill_render_ok = os.path.isfile(_pill_render_bin) and os.access(_pill_render_bin, os.X_OK)

def render_pill_b64(text, bg_hex, fg_hex="#FFFFFF"):
    """Render pill badge via Swift helper (system font). Returns base64 PNG string."""
    if not _pill_render_ok:
        return None
    bg = bg_hex.lstrip("#")
    fg = fg_hex.lstrip("#")
    try:
        r = subprocess.run(
            [_pill_render_bin, text, bg, fg, "11", "8", "3"],
            capture_output=True, text=True, timeout=2
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return None

# Flash pill colors: (bg, fg) pairs per frame
PILL_FLASH_UP = [
    ("#FFFFFF", "#000000"),  # frame 0: white pill, black text
    ("#7AFF9B", "#FFFFFF"),  # frame 1: bright green
    ("#34C759", "#FFFFFF"),  # frame 2: normal green
]
PILL_FLASH_DOWN = [
    ("#FFFFFF", "#000000"),
    ("#FF7B73", "#FFFFFF"),
    ("#FF3B30", "#FFFFFF"),
]
PILL_NORMAL_UP   = ("#34C759", "#FFFFFF")
PILL_NORMAL_DOWN = ("#FF3B30", "#FFFFFF")
PILL_NEUTRAL     = ("#555555", "#CCCCCC")

def pill_colors(pct, direction, secs_since):
    """Return (bg_hex, fg_hex) for the pill, with flash animation."""
    seq = None
    if secs_since is not None and secs_since < FLASH_DURATION:
        idx = min(int(secs_since), 2)
        if direction == "up":
            return PILL_FLASH_UP[idx]
        elif direction == "down":
            return PILL_FLASH_DOWN[idx]
    # Steady state
    if pct is not None and pct > 0:
        return PILL_NORMAL_UP
    if pct is not None and pct < 0:
        return PILL_NORMAL_DOWN
    return PILL_NEUTRAL

def safe_float(v):
    try:
        if v is None:
            return None
        return float(v)
    except Exception:
        return None

def http_get(url, cookie=None, timeout=6):
    """GET via curl (bypasses Yahoo TLS fingerprinting that blocks urllib).
    Returns (body_str, http_code) or (None, 0) on error."""
    cmd = ["curl", "-sS", "-L", "--connect-timeout", "3", "--max-time", str(timeout),
           "-A", UA, "-o", "-", "-w", "%{stderr}%{http_code}"]
    if cookie:
        cmd += ["-b", cookie]
    cmd.append(url)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 2)
        body = r.stdout or ""
        try:
            code = int((r.stderr or "").strip())
        except ValueError:
            code = 0
        if r.returncode != 0 and code == 0:
            return None, 0
        return body, code
    except Exception:
        return None, 0

# ---- Yahoo cookie+crumb auth ----

def fetch_yahoo_auth():
    """Get a fresh Yahoo A3 cookie and crumb via curl (more reliable than urllib).
    Returns (cookie_str, crumb) or (None, None)."""
    import subprocess, tempfile
    try:
        cookie_jar = tempfile.mktemp(suffix=".txt")
        # Step 1: hit fc.yahoo.com to get the A3 cookie (404 is expected)
        subprocess.run(
            ["curl", "-sS", "-c", cookie_jar, "-A", UA, "https://fc.yahoo.com", "-o", "/dev/null"],
            timeout=8, capture_output=True
        )
        # Read cookie jar to find A3
        cookie_str = None
        try:
            with open(cookie_jar, "r") as f:
                for line in f:
                    if "A3" in line and "yahoo.com" in line:
                        parts = line.strip().split("\t")
                        if len(parts) >= 7:
                            cookie_str = f"A3={parts[6]}"
                            break
        except Exception:
            pass
        if not cookie_str:
            try:
                os.unlink(cookie_jar)
            except Exception:
                pass
            return None, None
        # Step 2: get crumb
        result = subprocess.run(
            ["curl", "-sS", "-b", cookie_jar, "-A", UA,
             "https://query2.finance.yahoo.com/v1/test/getcrumb"],
            timeout=8, capture_output=True, text=True
        )
        crumb = (result.stdout or "").strip()
        try:
            os.unlink(cookie_jar)
        except Exception:
            pass
        if not crumb or "Too Many" in crumb or "Request" in crumb:
            return None, None
        return cookie_str, crumb
    except Exception:
        return None, None

def get_yahoo_auth():
    """Return cached (cookie, crumb) or fetch new ones. Cache for 24h."""
    auth = load_json(auth_path)
    cookie = auth.get("cookie")
    crumb = auth.get("crumb")
    ts = auth.get("ts", 0)
    if cookie and crumb and (time.time() - ts) < AUTH_MAX_AGE:
        return cookie, crumb
    # Fetch fresh
    cookie, crumb = fetch_yahoo_auth()
    if cookie and crumb:
        save_json(auth_path, {"cookie": cookie, "crumb": crumb, "ts": time.time()})
        return cookie, crumb
    # If fetch failed but we have old cached values, try them anyway
    if auth.get("cookie") and auth.get("crumb"):
        return auth["cookie"], auth["crumb"]
    return None, None

# ---- market hours check (ET — works for all US stocks) ----
import zoneinfo
from datetime import timedelta

et = zoneinfo.ZoneInfo("America/New_York")
now_et = datetime.now(et)
weekday = now_et.weekday()  # 0=Mon .. 6=Sun
hour_min = now_et.hour * 100 + now_et.minute

# Pre-market 4:00 ET — post-market close 20:00 ET, weekdays only
market_open = weekday < 5 and 400 <= hour_min < 2000

def next_market_open_et():
    """Compute next pre-market open (4:00 ET, next weekday)."""
    d = now_et.replace(hour=4, minute=0, second=0, microsecond=0)
    if weekday < 5 and hour_min < 400:
        return d  # later today
    d += timedelta(days=1)
    while d.weekday() >= 5:
        d += timedelta(days=1)
    return d

def fmt_countdown(delta):
    s = int(delta.total_seconds())
    if s <= 0:
        return "soon"
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h > 0:
        return f"{h}h {m:02d}m"
    return f"{m}m {sec:02d}s"

# ---- Load user preferences ----
prefs = load_json(prefs_path)
display_mode = prefs.get("display", DISPLAY_PILL)
script_path = os.path.join(plugin_dir, "stock_ticker.1s.sh")

def render_menubar(text, bg_hex, fg_hex, pct=None):
    """Render menu bar item in the user's chosen display mode."""
    if display_mode == DISPLAY_PILL:
        img = render_pill_b64(text, bg_hex, fg_hex)
        if img:
            return f"| image={img}"
    # Text fallback (or explicit text mode)
    color = fg_hex if display_mode == DISPLAY_TEXT else color_for_pct(pct)
    return f"{text} | color={color}"

if not market_open and not simulate_mode:
    st = load_json(state_path)
    last_price = st.get("last_price")
    last_dir = st.get("last_dir", "flat")
    last_change_time = st.get("last_change_time", "—")
    opens_at = next_market_open_et()
    countdown = fmt_countdown(opens_at - now_et)
    pill_text = f"{symbol} ${fmt_num(last_price)}"
    print(render_menubar(pill_text, "#555555", "#9AA0A6"))
    print("---")
    print(f"Market closed ({now_et.strftime('%a %H:%M ET')}) | color=#9AA0A6")
    print(f"Opens in {countdown} ({opens_at.strftime('%a %H:%M ET')})")
    print(f"Last known price: ${fmt_num(last_price)}")
    print("---")
    print(f"Open Yahoo Finance | href=https://finance.yahoo.com/quote/{symbol}")
    print("Refresh now | refresh=true")
    sys.exit(0)

# ---- quote cache layer (fetch every FETCH_INTERVAL, serve from cache otherwise) ----

def fetch_quote():
    """Fetch fresh quote from providers. Returns dict with quote fields or None."""
    provider = None
    q_data = {}
    yahoo_429 = False

    # Provider 1: Yahoo v7/quote with cookie+crumb
    cookie, crumb = get_yahoo_auth()
    if cookie and crumb:
        try:
            url = f"https://query2.finance.yahoo.com/v7/finance/quote?symbols={symbol}&crumb={crumb}"
            raw, code = http_get(url, cookie=cookie)
            if code == 401 or code == 403:
                cookie, crumb = fetch_yahoo_auth()
                if cookie and crumb:
                    save_json(auth_path, {"cookie": cookie, "crumb": crumb, "ts": time.time()})
                    raw, code = http_get(
                        f"https://query2.finance.yahoo.com/v7/finance/quote?symbols={symbol}&crumb={crumb}",
                        cookie=cookie
                    )
            if code == 429:
                yahoo_429 = True
            if raw and code == 200:
                data = json.loads(raw)
                results = data.get("quoteResponse", {}).get("result") or []
                if results:
                    q = results[0]
                    p = safe_float(q.get("regularMarketPrice"))
                    if p is not None:
                        q_data = {
                            "provider": "Yahoo/quote", "price": p,
                            "pct": safe_float(q.get("regularMarketChangePercent")),
                            "chg": safe_float(q.get("regularMarketChange")),
                            "currency": q.get("currency") or "USD",
                            "prev_close": safe_float(q.get("regularMarketPreviousClose")),
                            "open": safe_float(q.get("regularMarketOpen")),
                            "day_low": safe_float(q.get("regularMarketDayLow")),
                            "day_high": safe_float(q.get("regularMarketDayHigh")),
                            "wk52_low": safe_float(q.get("fiftyTwoWeekLow")),
                            "wk52_high": safe_float(q.get("fiftyTwoWeekHigh")),
                            "volume": q.get("regularMarketVolume"),
                            "mcap": q.get("marketCap"),
                            "exch": q.get("fullExchangeName") or q.get("exchange") or "—",
                            "mkt_time": q.get("regularMarketTime"),
                            "ts": time.time(),
                        }
                        return q_data
        except Exception:
            pass

    # Provider 2: Yahoo v8/chart (skip if Yahoo 429'd)
    if not yahoo_429:
        try:
            raw, code = http_get(f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}")
            if code == 429:
                yahoo_429 = True
            if raw and code == 200:
                data = json.loads(raw)
                meta = data["chart"]["result"][0]["meta"]
                p = safe_float(meta.get("regularMarketPrice"))
                if p is not None:
                    pc = safe_float(meta.get("chartPreviousClose") or meta.get("previousClose"))
                    chg = pct = None
                    if pc and pc != 0:
                        chg = p - pc
                        pct = (chg / pc) * 100.0
                    q_data = {
                        "provider": "Yahoo/chart", "price": p,
                        "pct": pct, "chg": chg,
                        "currency": meta.get("currency") or "USD",
                        "prev_close": pc,
                        "open": None,
                        "day_low": safe_float(meta.get("regularMarketDayLow")),
                        "day_high": safe_float(meta.get("regularMarketDayHigh")),
                        "wk52_low": safe_float(meta.get("fiftyTwoWeekLow")),
                        "wk52_high": safe_float(meta.get("fiftyTwoWeekHigh")),
                        "volume": meta.get("regularMarketVolume"),
                        "mcap": None,
                        "exch": meta.get("exchangeName") or "—",
                        "mkt_time": meta.get("regularMarketTime"),
                        "ts": time.time(),
                    }
                    return q_data
        except Exception:
            pass

    # Provider 3: Stooq (only if Yahoo is genuinely down)
    if not yahoo_429:
        try:
            last_csv, _ = http_get(f"https://stooq.com/q/l/?s={stooq_sym}&f=sd2t2ohlcv&h&e=csv")
            if last_csv and "Exceeded" not in last_csv:
                rows = list(csv.DictReader(io.StringIO(last_csv)))
                if rows:
                    r = rows[0]
                    p = safe_float(r.get("Close"))
                    vol = None
                    try:
                        vol = int(float(r.get("Volume"))) if r.get("Volume") else None
                    except Exception:
                        pass
                    d = (r.get("Date") or "").strip()
                    t = (r.get("Time") or "").strip()
                    mts = f"{d} {t}" if d and t and t != "00:00:00" else d
                    pc = None
                    daily_csv, _ = http_get(f"https://stooq.com/q/d/l/?s={stooq_sym}&i=d")
                    if daily_csv and "Exceeded" not in daily_csv:
                        drows = list(csv.DictReader(io.StringIO(daily_csv)))
                        if len(drows) >= 2:
                            pc = safe_float(drows[-2].get("Close"))
                            if p is None:
                                p = safe_float(drows[-1].get("Close"))
                    chg = pct = None
                    if p is not None and pc is not None and pc != 0:
                        chg = p - pc
                        pct = (chg / pc) * 100.0
                    if p is not None:
                        q_data = {
                            "provider": "Stooq", "price": p,
                            "pct": pct, "chg": chg, "currency": "USD",
                            "prev_close": pc,
                            "open": safe_float(r.get("Open")),
                            "day_low": safe_float(r.get("Low")),
                            "day_high": safe_float(r.get("High")),
                            "wk52_low": None, "wk52_high": None,
                            "volume": vol, "mcap": None, "exch": "—",
                            "mkt_time": mts, "ts": time.time(),
                        }
                        return q_data
        except Exception:
            pass

    # Mark 429 in a special return so caller knows
    if yahoo_429:
        return {"_429": True}
    return None

# Check quote cache — only fetch if stale
cached = load_json(cache_path)
cache_age = time.time() - cached.get("ts", 0)

if cache_age < FETCH_INTERVAL and cached.get("price") is not None:
    # Serve from cache — no network call
    qd = cached
else:
    # Cache is stale — fetch fresh
    result = fetch_quote()
    if result and result.get("price") is not None:
        qd = result
        save_json(cache_path, result)
    elif result and result.get("_429"):
        # Rate limited — use stale cache if available, otherwise state
        qd = cached if cached.get("price") is not None else None
    else:
        qd = cached if cached.get("price") is not None else None

# ---- State: tick tracking ----
st = load_json(state_path)
last_price = st.get("last_price")
last_dir = st.get("last_dir", "flat")
last_change_time = st.get("last_change_time", "—")

if qd is None or qd.get("price") is None:
    color = "#9AA0A6"
    top = f"{symbol} ${fmt_num(last_price)} — {arrow_for_dir(last_dir)} {last_change_time} | color={color}"
    print(top)
    print("---")
    print(f"{symbol} quote fetch failed | color=#FF3B30")
    print("Tried: Yahoo cookie+crumb, v8/chart, Stooq")
    print("---")
    print("Refresh now | refresh=true")
    sys.exit(0)

price = qd["price"]
pct = qd.get("pct")
chg = qd.get("chg")
provider = qd.get("provider", "cache")
currency = qd.get("currency", "USD")
prev_close = qd.get("prev_close")
open_ = qd.get("open")
day_low = qd.get("day_low")
day_high = qd.get("day_high")
wk52_low = qd.get("wk52_low")
wk52_high = qd.get("wk52_high")
volume = qd.get("volume")
mcap = qd.get("mcap")
exch = qd.get("exch", "—")
mt = qd.get("mkt_time")
if isinstance(mt, (int, float)):
    mkt_time_str = datetime.fromtimestamp(mt).strftime("%Y-%m-%d %H:%M:%S")
elif isinstance(mt, str):
    mkt_time_str = mt
else:
    mkt_time_str = "—"

# Update tick direction/time only when price changes
this_dir = "flat"
if isinstance(price, (int, float)) and isinstance(last_price, (int, float)):
    if price > last_price:
        this_dir = "up"
    elif price < last_price:
        this_dir = "down"
    else:
        this_dir = st.get("last_dir", "flat")

last_change_epoch = st.get("last_change_epoch")

if isinstance(price, (int, float)):
    if last_price is None or (isinstance(last_price, (int, float)) and price != last_price):
        last_change_time = now_str()
        last_change_epoch = time.time()
        last_dir = this_dir
        st["last_change_time"] = last_change_time
        st["last_change_epoch"] = last_change_epoch
        st["last_dir"] = last_dir
    st["last_price"] = price
    save_json(state_path, st)

# ---- Render ----
secs_since = (time.time() - last_change_epoch) if last_change_epoch else None
color = flash_color(pct, last_dir, secs_since)
arrow = arrow_for_dir(last_dir)

pct_str = "—" if pct is None else f"{pct:+.2f}%"
price_str = "—" if price is None else f"{price:.2f}"

# Menu bar line
pill_bg, pill_fg = pill_colors(pct, last_dir, secs_since)
pill_text = f"{symbol} ${price_str} {pct_str}"
print(render_menubar(pill_text, pill_bg, pill_fg, pct))

print("---")
src = provider if cache_age >= FETCH_INTERVAL else f"{provider} (cached)"
print(f"{symbol} — via {src} | color={color}")
print(f"Price: ${fmt_num(price)} {currency} | color={color}")
if chg is not None and pct is not None:
    print(f"Day change: {chg:+.2f} ({pct:+.2f}%) | color={color}")
else:
    print(f"Day change: — | color={color}")

print(f"Last tick: {arrow} (last change recorded at {last_change_time}) | color={color}")
print(f"Market time: {mkt_time_str}")

print("---")
print(f"Prev close: ${fmt_num(prev_close)}")
print(f"Open: ${fmt_num(open_)}")
print(f"Day range: ${fmt_num(day_low)} – ${fmt_num(day_high)}")
if wk52_low is not None or wk52_high is not None:
    print(f"52w range: ${fmt_num(wk52_low)} – ${fmt_num(wk52_high)}")
print(f"Volume: {fmt_int(volume)}")
if mcap is not None:
    print(f"Market cap: {fmt_big(mcap)}")
if exch != "—":
    print(f"Exchange: {exch}")

print("---")
print(f"Open Yahoo Finance | href=https://finance.yahoo.com/quote/{symbol}")
print(f"Open Stooq | href=https://stooq.com/q/?s={stooq_sym}")
print("Refresh now | refresh=true")

# ---- Settings submenu ----
sp = f'"{script_path}"'  # quote for paths with spaces
print("---")
pill_mark = "✓ " if display_mode == DISPLAY_PILL else "  "
text_mark = "✓ " if display_mode == DISPLAY_TEXT else "  "
print("Settings")
print(f"--Display Mode")
print(f"----{pill_mark}Pill Badge | shell={sp} param1=--set-display param2=pill terminal=false refresh=true")
print(f"----{text_mark}Plain Text | shell={sp} param1=--set-display param2=text terminal=false refresh=true")
print(f"--Change Symbol (current: {symbol})")
for s in ["AAPL", "GOOG", "MSFT", "TSLA", "AMZN", "NVDA", "META", "WIX"]:
    mark = "✓ " if s == symbol else "  "
    print(f"----{mark}{s} | shell={sp} param1=--set-symbol param2={s} terminal=false refresh=true")
print(f"----Custom Symbol… | shell={sp} param1=--prompt-symbol terminal=false refresh=true")

# ---- Simulation mode: fake price ticks to preview flash animation ----
if simulate_mode:
    import random
    base = price if price else 220.0
    sim_state_path = state_path.replace("_state.json", "_sim_state.json")
    sim_st = load_json(sim_state_path)
    sim_step = sim_st.get("step", 0)
    # Cycle: tick up for 6s, hold 4s, tick down for 6s, hold 4s = 20s loop
    phase = sim_step % 20
    if phase < 6:
        fake_price = base + (phase + 1) * 0.15
        fake_dir = "up"
    elif phase < 10:
        fake_price = base + 6 * 0.15
        fake_dir = "up"
    elif phase < 16:
        fake_price = base + 6 * 0.15 - (phase - 9) * 0.12
        fake_dir = "down"
    else:
        fake_price = base + 6 * 0.15 - 6 * 0.12
        fake_dir = "down"

    sim_last_price = sim_st.get("price")
    sim_last_epoch = sim_st.get("epoch")
    changed = sim_last_price is None or abs(fake_price - sim_last_price) > 0.001
    if changed:
        sim_last_epoch = time.time()
    sim_st = {"step": sim_step + 1, "price": fake_price, "epoch": sim_last_epoch}
    save_json(sim_state_path, sim_st)

    secs = (time.time() - sim_last_epoch) if sim_last_epoch else 99
    sim_bg, sim_fg = pill_colors(1.0 if fake_dir == "up" else -1.0, fake_dir, secs)
    sim_text = f"{symbol} ${fake_price:.2f} SIM"
    # Write each frame to /tmp for preview
    frame_path = f"/tmp/xbar_sim_frame.png"
    import base64 as b64mod
    png_b64 = render_pill_b64(sim_text, sim_bg, sim_fg)
    with open(frame_path, "wb") as ff:
        ff.write(b64mod.b64decode(png_b64))
    print(f"---")
    print(f"SIMULATION: step {sim_step}, phase {phase}, dir {fake_dir}, secs_since {secs:.1f}")
    print(f"Frame saved: {frame_path}")
PY
