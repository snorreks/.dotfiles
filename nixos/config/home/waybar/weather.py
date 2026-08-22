"""waybar-weather — OpenWeatherMap → waybar JSON stream.

Long-lived process (same contract as the sys-daemon streams): one JSON line
per change, nothing printed while the weather is unchanged.

    fetch    every 10 min  (or on SIGUSR1 / `waybar-weather --refresh`)
    render   every 60 s    ("updated Xm ago" and the hourly window rolling)

Free-tier endpoints only — /data/2.5/weather (now) and /data/2.5/forecast
(3-hourly, 5 days) — so a plain free API key works; no One Call subscription.
The key is stored encrypted as OPENWEATHER_API_KEY (`add_env_secret`) and the
coordinates come from nixos/options.nix via the nix wrapper.

Debugging:
    waybar-weather --sample ./testdata --once
"""

import dataclasses
import html
import json
import os
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

SECRET_NAME = "OPENWEATHER_API_KEY"
SECRETS_ENV = Path.home() / ".config/sops/secrets-env"
API = "https://api.openweathermap.org/data/2.5"

FETCH_INTERVAL = 10 * 60
RETRY_INTERVAL = 60
RENDER_INTERVAL = 60
HOURLY_STEPS = 5   # 3-hourly entries shown in the tooltip (≈15 h)
DAILY_DAYS = 4
HTTP_TIMEOUT = 15
USER_AGENT = "waybar-weather/1.0"

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "waybar-weather"
PID_FILE = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "waybar-weather.pid"

# nf-md weather glyphs, keyed by OWM's icon code (01d…50n).
ICONS = {
    "01d": "󰖙", "01n": "󰖔",   # clear
    "02d": "󰖕", "02n": "󰼱",   # few clouds
    "03d": "󰖐", "03n": "󰖐",   # scattered clouds
    "04d": "󰖐", "04n": "󰖐",   # overcast
    "09d": "󰖖", "09n": "󰖖",   # showers
    "10d": "󰖗", "10n": "󰖗",   # rain
    "11d": "󰖓", "11n": "󰖓",   # thunderstorm
    "13d": "󰖘", "13n": "󰖘",   # snow
    "50d": "󰖑", "50n": "󰖑",   # mist / fog
}
FALLBACK_ICON = "󰖐"
I_TEMP, I_WIND, I_HUMID, I_RAIN = "󰔏", "󰖝", "󰖎", "󰖗"
I_SUNRISE, I_SUNSET = "󰖜", "󰖛"

COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]


class Refresh(Exception):
    """Raised out of SIGUSR1 to cut a sleep short."""


@dataclasses.dataclass
class Slot:
    when: datetime
    temp: float
    icon: str
    pop: float
    rain: float


# ── environment ────────────────────────────────────────────────────────────

def local_tz():
    name = os.environ.get("TZ")
    if not name:
        try:
            parts = Path("/etc/localtime").resolve().parts
            if "zoneinfo" in parts:
                name = "/".join(parts[parts.index("zoneinfo") + 1:])
        except OSError:
            pass
    if name:
        try:
            return ZoneInfo(name)
        except Exception:
            pass
    return datetime.now().astimezone().tzinfo


def secret(name):
    """env → sops secrets-env (waybar can start before the env import ran)."""
    value = (os.environ.get(name) or "").strip()
    # home.sessionVariables exposes these as literal "$(cat /run/secrets/…)"
    # shell substitutions; an unexpanded one means we must read the file.
    if value and not value.startswith("$("):
        return value
    try:
        text = SECRETS_ENV.read_text()
    except OSError:
        return None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[len("export "):]
        key, sep, val = line.partition("=")
        if sep and key.strip() == name:
            return val.strip().strip('"').strip("'") or None
    return None


# ── fetching ───────────────────────────────────────────────────────────────

def get_json(endpoint, params):
    url = f"{API}/{endpoint}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch(key, lat, lon, units, lang):
    params = {"lat": lat, "lon": lon, "units": units, "lang": lang, "appid": key}
    current = get_json("weather", params)
    forecast = get_json("forecast", params)
    return current, forecast


def cache_store(current, forecast):
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        for name, payload in (("current.json", current), ("forecast.json", forecast)):
            tmp = CACHE_DIR / (name + ".tmp")
            tmp.write_text(json.dumps(payload))
            tmp.replace(CACHE_DIR / name)
    except OSError:
        pass


def load_dir(directory):
    current = json.loads((directory / "current.json").read_text())
    forecast = json.loads((directory / "forecast.json").read_text())
    stamp = datetime.fromtimestamp((directory / "current.json").stat().st_mtime)
    return current, forecast, stamp


# ── rendering ──────────────────────────────────────────────────────────────

def icon_for(code):
    return ICONS.get(code, FALLBACK_ICON)


def degree(units):
    return "F" if units == "imperial" else "C"


def speed_unit(units):
    return "mph" if units == "imperial" else "m/s"


def compass(deg):
    return COMPASS[int((deg % 360) / 45 + 0.5) % 8]


def slots(forecast, tz):
    out = []
    for entry in forecast.get("list", []):
        out.append(Slot(
            when=datetime.fromtimestamp(entry["dt"], tz),
            temp=entry["main"]["temp"],
            icon=(entry.get("weather") or [{}])[0].get("icon", ""),
            pop=entry.get("pop", 0.0) * 100,
            rain=(entry.get("rain") or {}).get("3h", 0.0) + (entry.get("snow") or {}).get("3h", 0.0),
        ))
    return out


def hourly_block(items, tz):
    now = datetime.now(tz)
    upcoming = [s for s in items if s.when > now][:HOURLY_STEPS]
    if not upcoming:
        return ""
    lines = ["<b>Next hours</b>"]
    for slot in upcoming:
        rain = f"{slot.rain:.1f} mm" if slot.rain >= 0.05 else ""
        pop = f"{slot.pop:3.0f}%" if slot.pop >= 5 else "    "
        row = f"{slot.when:%H:%M}  {icon_for(slot.icon)}  {slot.temp:3.0f}°  {pop}  {rain}"
        lines.append(f"<tt>{row.rstrip()}</tt>")
    return "\n".join(lines)


def daily_block(items, tz):
    days = {}
    for slot in items:
        days.setdefault(slot.when.date(), []).append(slot)
    today = datetime.now(tz).date()
    lines = ["<b>Next days</b>"]
    shown = 0
    for day in sorted(days):
        if day <= today:
            continue
        group = days[day]
        # Daytime icons describe the day better than a 03:00 one.
        daytime = [s.icon for s in group if 8 <= s.when.hour <= 18] or [s.icon for s in group]
        icon = icon_for(Counter(daytime).most_common(1)[0][0])
        low = min(s.temp for s in group)
        high = max(s.temp for s in group)
        pop = max(s.pop for s in group)
        rain = f"{pop:3.0f}%" if pop >= 5 else "    "
        row = f"{day:%a}  {icon}  {low:3.0f}°/{high:3.0f}°  {rain}"
        lines.append(f"<tt>{row.rstrip()}</tt>")
        shown += 1
        if shown >= DAILY_DAYS:
            break
    return "\n".join(lines) if shown else ""


def render(current, forecast, tz, units, synced, error):
    weather = (current.get("weather") or [{}])[0]
    icon = icon_for(weather.get("icon", ""))
    main = current.get("main", {})
    wind = current.get("wind", {})
    sysinfo = current.get("sys", {})
    temp = main.get("temp")
    place = current.get("name") or "Weather"
    description = (weather.get("description") or "").capitalize()

    text = f"{icon} {temp:.0f}°" if temp is not None else f"{icon} —"
    css = (weather.get("main") or "unknown").lower()

    head = [f"<b>{html.escape(place)} · {html.escape(description)}</b>"]
    if temp is not None:
        line = f"{I_TEMP} {temp:.0f}°{degree(units)}"
        feels = main.get("feels_like")
        if feels is not None and abs(feels - temp) >= 1:
            line += f"  <span alpha='60%'>feels {feels:.0f}°</span>"
        head.append(line)

    facts = []
    if wind.get("speed") is not None:
        gust = f" (gusts {wind['gust']:.0f})" if wind.get("gust") else ""
        facts.append(f"{I_WIND} {wind['speed']:.0f} {speed_unit(units)} {compass(wind.get('deg', 0))}{gust}")
    if main.get("humidity") is not None:
        facts.append(f"{I_HUMID} {main['humidity']:.0f}%")
    precip = (current.get("rain") or {}).get("1h") or (current.get("snow") or {}).get("1h")
    if precip:
        facts.append(f"{I_RAIN} {precip:.1f} mm/h")
    if facts:
        head.append("  ".join(facts))
    if sysinfo.get("sunrise") and sysinfo.get("sunset"):
        rise = datetime.fromtimestamp(sysinfo["sunrise"], tz)
        set_ = datetime.fromtimestamp(sysinfo["sunset"], tz)
        head.append(f"{I_SUNRISE} {rise:%H:%M}   {I_SUNSET} {set_:%H:%M}")

    items = slots(forecast, tz)
    sections = [s for s in ("\n".join(head), hourly_block(items, tz), daily_block(items, tz)) if s]

    footer = []
    if synced:
        age = int((datetime.now() - synced).total_seconds() // 60)
        footer.append("updated just now" if age < 1 else f"updated {age}m ago")
    if error:
        footer.append(f"⚠ {html.escape(error[:60])}")
    footer.append("click → forecast")
    sections.append(f"<span alpha='50%'>{' · '.join(footer)}</span>")
    return text, "\n\n".join(sections), css


def setup_tooltip(message=None):
    return (
        f"<b>{FALLBACK_ICON} Weather not configured</b>\n\n"
        + (f"{html.escape(message)}\n\n" if message else "")
        + "Add an OpenWeatherMap API key:\n"
        f"<tt>  add_env_secret {SECRET_NAME}</tt>\n\n"
        "<span alpha='60%'>Free key: openweathermap.org/api\n"
        "(new keys take a little while to activate)</span>"
    )


# ── main loop ──────────────────────────────────────────────────────────────

def emit(state, last):
    line = json.dumps(state, ensure_ascii=False)
    if line != last:
        print(line, flush=True)
    return line


def on_sigusr1(_signum, _frame):
    raise Refresh()


def send_refresh():
    try:
        pid = int(PID_FILE.read_text().strip())
        os.kill(pid, signal.SIGUSR1)
        return 0
    except (OSError, ValueError):
        print("waybar-weather: no running instance to refresh", file=sys.stderr)
        return 1


def city_url(current):
    city_id = current.get("id")
    return f"https://openweathermap.org/city/{city_id}" if city_id else "https://openweathermap.org"


def run(once=False, sample=None):
    tz = local_tz()
    units = os.environ.get("WAYBAR_WEATHER_UNITS", "metric")
    lang = os.environ.get("WAYBAR_WEATHER_LANG", "en")
    lat = os.environ.get("WAYBAR_WEATHER_LAT", "59.91")
    lon = os.environ.get("WAYBAR_WEATHER_LON", "10.75")
    key = None if sample else secret(SECRET_NAME)

    if not sample and not key:
        emit({"text": f"{FALLBACK_ICON} setup", "tooltip": setup_tooltip(), "class": "setup"}, None)
        if once:
            return 0
        time.sleep(FETCH_INTERVAL)
        return 0

    current, forecast, synced = None, None, None
    if sample:
        current, forecast, synced = load_dir(sample)
    else:
        try:
            current, forecast, synced = load_dir(CACHE_DIR)
        except (OSError, ValueError, KeyError):
            pass

    last, error, next_fetch = None, None, 0.0
    while True:
        try:
            if not sample and time.monotonic() >= next_fetch:
                try:
                    current, forecast = fetch(key, lat, lon, units, lang)
                    synced, error = datetime.now(), None
                    cache_store(current, forecast)
                    next_fetch = time.monotonic() + FETCH_INTERVAL
                except Exception as exc:
                    error = f"{type(exc).__name__}: {exc}"
                    next_fetch = time.monotonic() + RETRY_INTERVAL

            if current:
                text, tip, css = render(current, forecast or {}, tz, units, synced, error)
            elif error and "401" in error:
                text, tip, css = f"{FALLBACK_ICON} setup", setup_tooltip("The API key was rejected (401)."), "setup"
            else:
                text, tip, css = f"{FALLBACK_ICON} ⚠", f"<b>Weather unavailable</b>\n{html.escape(error or '')}", "error"

            last = emit({"text": text, "tooltip": tip, "class": css}, last)
            if once:
                return 0
            time.sleep(RENDER_INTERVAL)
        except Refresh:
            next_fetch = 0.0


def open_forecast():
    """Open the OWM page for the city the last fetch resolved to."""
    url = "https://openweathermap.org"
    try:
        url = city_url(json.loads((CACHE_DIR / "current.json").read_text()))
    except (OSError, ValueError, AttributeError):
        pass
    subprocess.Popen(["xdg-open", url], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


def main(argv):
    if "--refresh" in argv:
        return send_refresh()
    if "--open" in argv:
        return open_forecast()
    sample = None
    if "--sample" in argv:
        sample = Path(argv[argv.index("--sample") + 1]).expanduser()
    signal.signal(signal.SIGUSR1, on_sigusr1)
    once = "--once" in argv
    if not once:
        try:
            PID_FILE.write_text(f"{os.getpid()}\n")
        except OSError:
            pass
    return run(once=once, sample=sample)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
