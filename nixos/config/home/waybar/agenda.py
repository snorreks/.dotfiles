"""waybar-agenda — Google Calendar (private ICS) → waybar JSON stream.

Long-lived process, same contract as the sys-daemon streams: waybar's custom
module reads one JSON line per update ("if no interval or signal is defined,
it is assumed that the out script loops itself"), and we only print when the
rendered state actually changed.

    fetch    every 15 min   (or on SIGUSR1 / `waybar-agenda --refresh`)
    render   every 30 s     (countdowns: "in 12m", "24m left")

The source is Google Calendar's *secret address in iCal format*
(Calendar settings → Integrate calendar → Secret address in iCal format) for
snorristrand@gmail.com — the same calendar Thunderbird subscribes to over
CalDAV, but readable without OAuth and without Thunderbird running. It is
stored encrypted as GOOGLE_CALENDAR_ICS_URL (`add_env_secret`), so the URL
never lands in the nix store.

Debugging:
    GOOGLE_CALENDAR_ICS_URL=/path/to/some.ics waybar-agenda --once
"""

import calendar as calmod
import dataclasses
import html
import json
import os
import signal
import sys
import time
import urllib.request
from datetime import datetime, time as dtime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import icalendar
import recurring_ical_events

SECRET_NAME = "GOOGLE_CALENDAR_ICS_URL"
SECRETS_ENV = Path.home() / ".config/sops/secrets-env"

FETCH_INTERVAL = 15 * 60  # ICS re-download
RETRY_INTERVAL = 60       # after a failed download
RENDER_INTERVAL = 30      # countdown refresh
LOOKAHEAD_DAYS = 8        # window we expand recurrences over
SOON_MINUTES = 15         # "in 12m" + .soon class
SHOW_WITHIN_HOURS = 18    # further out than this → bar text stays empty
MAX_TOOLTIP_EVENTS = 14
TITLE_MAX = 28            # bar text
TOOLTIP_TITLE_MAX = 42
ICON = "󰃭"
HTTP_TIMEOUT = 20
USER_AGENT = "waybar-agenda/1.0"

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "waybar-agenda"
CACHE_FILE = CACHE_DIR / "calendar.ics"
PID_FILE = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "waybar-agenda.pid"


class Refresh(Exception):
    """Raised out of SIGUSR1 to cut a sleep short."""


@dataclasses.dataclass
class Event:
    start: datetime
    end: datetime
    title: str
    location: str
    allday: bool


# ── environment ────────────────────────────────────────────────────────────

def local_tz():
    """Real zone (not a fixed offset), so DST inside the window is correct."""
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
    """env → sops secrets-env. waybar can start before sops-import-environment
    has run, so the file is the reliable path, not the inherited environment."""
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

def download(source):
    if source.startswith(("http://", "https://")):
        req = urllib.request.Request(source, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.read()
    return Path(source).expanduser().read_bytes()


def cache_store(raw):
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = CACHE_FILE.with_suffix(".tmp")
        tmp.write_bytes(raw)
        tmp.replace(CACHE_FILE)
    except OSError:
        pass


def cache_load():
    try:
        return CACHE_FILE.read_bytes(), datetime.fromtimestamp(CACHE_FILE.stat().st_mtime)
    except OSError:
        return None, None


# ── parsing ────────────────────────────────────────────────────────────────

def to_dt(value, tz, end_of_allday=False):
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=tz)
        return value.astimezone(tz)
    return datetime.combine(value, dtime.min, tzinfo=tz)


def collect(raw, tz, now):
    """Expand recurrences over the whole visible month plus the lookahead.

    The month is needed on top of the agenda window because the tooltip marks
    every day of the month that has something on it — with only an 8-day
    window the rest of the month would render as misleadingly empty.
    """
    cal = icalendar.Calendar.from_ical(raw)
    today = now.date()
    month_start = today.replace(day=1)
    next_month = (month_start + timedelta(days=32)).replace(day=1)
    window_start = datetime.combine(min(month_start, today), dtime.min, tzinfo=tz)
    window_end = datetime.combine(
        max(next_month, today + timedelta(days=LOOKAHEAD_DAYS)), dtime.min, tzinfo=tz)

    events = []
    for comp in recurring_ical_events.of(cal, components=["VEVENT"]).between(window_start, window_end):
        if str(comp.get("STATUS", "")).upper() == "CANCELLED":
            continue
        raw_start = comp["DTSTART"].dt
        allday = not isinstance(raw_start, datetime)
        raw_end = comp["DTEND"].dt if comp.get("DTEND") is not None else None
        if raw_end is None:
            raw_end = raw_start + (timedelta(days=1) if allday else timedelta(hours=1))
        start = to_dt(raw_start, tz)
        end = to_dt(raw_end, tz)
        if end <= start:
            end = start + timedelta(minutes=30)
        events.append(Event(
            start=start,
            end=end,
            title=str(comp.get("SUMMARY", "") or "(no title)").strip(),
            location=str(comp.get("LOCATION", "") or "").strip(),
            allday=allday,
        ))
    events.sort(key=lambda e: (e.start, 0 if e.allday else 1, e.title))
    return events


# ── rendering ──────────────────────────────────────────────────────────────

def clip(text, limit):
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def human_minutes(minutes):
    if minutes < 60:
        return f"{minutes}m"
    hours, rest = divmod(minutes, 60)
    return f"{hours}h" if rest == 0 else f"{hours}h{rest:02d}"


def bar_text(events, now):
    """(text, class) for the bar itself."""
    timed = [e for e in events if not e.allday]
    allday_today = [e for e in events if e.allday and e.start.date() <= now.date() < e.end.date()]

    running = [e for e in timed if e.start <= now < e.end]
    if running:
        event = min(running, key=lambda e: e.end)
        left = int((event.end - now).total_seconds() // 60)
        return f"{ICON} {clip(event.title, TITLE_MAX)} · {human_minutes(left)} left", "now"

    upcoming = [e for e in timed if e.start > now]
    if upcoming:
        event = upcoming[0]
        ahead = int((event.start - now).total_seconds() // 60)
        if ahead <= SOON_MINUTES:
            return f"{ICON} {clip(event.title, TITLE_MAX)} · in {human_minutes(ahead)}", "soon"
        if ahead <= SHOW_WITHIN_HOURS * 60:
            when = f"{event.start:%H:%M}" if event.start.date() == now.date() \
                else f"{event.start:%a} {event.start:%H:%M}"
            return f"{ICON} {when}  {clip(event.title, TITLE_MAX)}", "upcoming"

    if allday_today:
        return f"{ICON} {clip(allday_today[0].title, TITLE_MAX)}", "allday"
    return "", "free"


def month_grid(today, event_days):
    """Current month, monospace, with event days bold and today underlined."""
    rows = [f"<b>{today:%B %Y}</b>", "<tt>wk │ Mo Tu We Th Fr Sa Su</tt>"]
    for week in calmod.Calendar(firstweekday=0).monthdatescalendar(today.year, today.month):
        cells = []
        for day in week:
            label = f"{day.day:2d}"
            if day.month != today.month:
                cells.append(f"<span alpha='30%'>{label}</span>")
            elif day == today:
                cells.append(f"<b><u>{label}</u></b>")
            elif day in event_days:
                cells.append(f"<b>{label}</b>")
            else:
                cells.append(label)
        rows.append(f"<tt>{week[0].isocalendar()[1]:2d} │ {' '.join(cells)}</tt>")
    return "\n".join(rows)


def day_label(day, today):
    if day == today:
        return "Today"
    if day == today + timedelta(days=1):
        return "Tomorrow"
    return f"{day:%A %-d %B}"


def agenda_lines(events, now):
    """Upcoming events grouped by day, dropping what already ended today."""
    today = now.date()
    horizon = now + timedelta(days=LOOKAHEAD_DAYS)
    remaining = [e for e in events if e.end > now and e.start < horizon]
    lines, count, current_day = [], 0, None
    for event in remaining:
        if count >= MAX_TOOLTIP_EVENTS:
            lines.append(f"<span alpha='55%'>… {len(remaining) - count} more</span>")
            break
        day = max(event.start.date(), today)
        if day != current_day:
            lines.append(("" if current_day is None else "\n") + f"<b>{day_label(day, today)}</b>")
            current_day = day
        when = "all-day" if event.allday else f"{event.start:%H:%M}–{event.end:%H:%M}"
        title = html.escape(clip(event.title, TOOLTIP_TITLE_MAX))
        marker = "▸ " if event.start <= now < event.end else "  "
        line = f"<tt>{when:<11}</tt>{marker}{title}"
        if event.location:
            line += f"  <span alpha='45%'>{html.escape(clip(event.location, 24))}</span>"
        lines.append(line)
        count += 1
    if not lines:
        lines.append(f"<span alpha='55%'>Nothing in the next {LOOKAHEAD_DAYS} days</span>")
    return "\n".join(lines)


def tooltip(events, now, synced, error):
    today = now.date()
    event_days = {
        day
        for event in events
        for day in (event.start.date() + timedelta(days=n)
                    for n in range((event.end.date() - event.start.date()).days + 1))
        if day.month == today.month and day.year == today.year
    }
    footer = []
    if synced:
        footer.append(f"synced {synced:%H:%M}")
    if error:
        footer.append(f"⚠ {html.escape(clip(error, 60))}")
    footer.append("click → Thunderbird · right-click → refresh")
    return "\n".join([
        month_grid(today, event_days),
        "",
        agenda_lines(events, now),
        "",
        f"<span alpha='50%'>{' · '.join(footer)}</span>",
    ])


def setup_tooltip():
    return (
        f"<b>{ICON} Calendar not configured</b>\n\n"
        f"Add your Google Calendar secret iCal URL:\n"
        f"<tt>  add_env_secret {SECRET_NAME}</tt>\n\n"
        "<span alpha='60%'>Google Calendar → Settings → the calendar →\n"
        "Integrate calendar → Secret address in iCal format</span>"
    )


# ── main loop ──────────────────────────────────────────────────────────────

def emit(state, last):
    line = json.dumps(state, ensure_ascii=False)
    if line != last:
        print(line, flush=True)
    return line


def sleep_until(deadline):
    remaining = deadline - time.monotonic()
    if remaining > 0:
        time.sleep(remaining)


def run(once=False):
    tz = local_tz()
    source = secret(SECRET_NAME)
    if not source:
        emit({"text": f"{ICON} setup", "tooltip": setup_tooltip(), "class": "setup"}, None)
        if once:
            return 0
        # Nothing to poll for; waybar's restart-interval retries after we exit.
        time.sleep(FETCH_INTERVAL)
        return 0

    raw, synced = cache_load()
    events, error, last, next_fetch = [], None, None, 0.0
    fresh = True

    while True:
        try:
            now = datetime.now(tz)
            if time.monotonic() >= next_fetch:
                try:
                    raw = download(source)
                    synced, error, fresh = datetime.now(), None, True
                    cache_store(raw)
                    next_fetch = time.monotonic() + FETCH_INTERVAL
                except Exception as exc:  # network, HTTP, unreadable file
                    error = f"{type(exc).__name__}: {exc}"
                    next_fetch = time.monotonic() + RETRY_INTERVAL
                    fresh = raw is not None
            if fresh and raw is not None:
                try:
                    events = collect(raw, tz, now)
                    fresh = False
                except Exception as exc:
                    error, events = f"parse failed: {exc}", []
                    fresh = False

            text, css = bar_text(events, now)
            if error and not events:
                text, css = f"{ICON} ⚠", "error"
            last = emit({"text": text, "tooltip": tooltip(events, now, synced, error), "class": css}, last)
            if once:
                return 0
            sleep_until(time.monotonic() + RENDER_INTERVAL)
        except Refresh:
            next_fetch = 0.0


def on_sigusr1(_signum, _frame):
    raise Refresh()


def send_refresh():
    try:
        pid = int(PID_FILE.read_text().strip())
        os.kill(pid, signal.SIGUSR1)
        return 0
    except (OSError, ValueError):
        print("waybar-agenda: no running instance to refresh", file=sys.stderr)
        return 1


def main(argv):
    if "--refresh" in argv:
        return send_refresh()
    signal.signal(signal.SIGUSR1, on_sigusr1)
    once = "--once" in argv
    if not once:
        try:
            PID_FILE.write_text(f"{os.getpid()}\n")
        except OSError:
            pass
    return run(once=once)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
