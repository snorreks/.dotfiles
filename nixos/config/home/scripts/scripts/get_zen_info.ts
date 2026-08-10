#!/usr/bin/env bun
import { existsSync, mkdirSync, openSync, readFileSync, unlinkSync, writeSync, closeSync } from "fs";
import { join } from "path";

interface ZenQuote {
  q: string;
  a: string;
  h?: string;
  c?: string;
}

interface ZenEvent {
  text: string;
  [key: string]: unknown;
}

interface ZenEventsResponse {
  data?: {
    Events?: ZenEvent[];
  };
}

const HOME = process.env.HOME || "/home/sonny";
const CACHE_DIR = join(HOME, ".cache", "zenquotes");
const QUOTES_FILE = join(CACHE_DIR, "quotes.json");
const INDEX_FILE = join(CACHE_DIR, "index");
// Shared with get_zen_quote.ts so the two scripts never double-fetch.
const QUOTES_LOCK_FILE = join(CACHE_DIR, "fetching.lock");

const now = new Date();
const todayStr = `${now.getFullYear()}_${String(now.getMonth() + 1).padStart(2, "0")}_${String(now.getDate()).padStart(2, "0")}`;
const EVENTS_FILE = join(CACHE_DIR, `events_${todayStr}.json`);
const EVENTS_LOCK_FILE = join(CACHE_DIR, "events.fetching.lock");

// Background fetches must never hang forever: abort after 10s so an
// offline/slow network fails fast and we retry on the next session.
const FETCH_TIMEOUT_MS = 10_000;
// Locks older than this are considered stale (a previous worker died hard)
// and can be taken over.
const LOCK_STALE_MS = 60_000;

if (!existsSync(CACHE_DIR)) {
  mkdirSync(CACHE_DIR, { recursive: true });
}

const args = process.argv.slice(2);

// ── Lock helpers (prevent fetcher pile-up while offline) ───────────────
const tryAcquireLock = (lockFile: string): boolean => {
  const acquire = (): boolean => {
    try {
      const fd = openSync(lockFile, "wx"); // atomic create-exclusive
      writeSync(fd, String(Date.now()));
      closeSync(fd);
      return true;
    } catch {
      return false;
    }
  };

  if (acquire()) return true;

  // Lock exists — take it over if it's stale (dead worker from a previous
  // session, e.g. after a hard kill or power loss).
  try {
    const ts = parseInt(readFileSync(lockFile, "utf8").trim(), 10) || 0;
    if (Date.now() - ts > LOCK_STALE_MS) {
      unlinkSync(lockFile);
      return acquire();
    }
  } catch {}
  return false;
};

const releaseLock = (lockFile: string): void => {
  try {
    unlinkSync(lockFile);
  } catch {}
};

// ── Background Worker Handlers ─────────────────────────────────────
const fetchQuotes = async (): Promise<void> => {
  // A fetcher is already running (possibly from get_zen_quote) — skip.
  if (!tryAcquireLock(QUOTES_LOCK_FILE)) return;

  try {
    const res = await fetch("https://zenquotes.io/api/quotes", {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    const data = (await res.json()) as ZenQuote[];
    if (Array.isArray(data) && data.length > 0) {
      await Bun.write(QUOTES_FILE, JSON.stringify(data));
      await Bun.write(INDEX_FILE, "0");
    }
  } catch {
    // Offline / timeout: keep whatever cache we had; retry next session.
  } finally {
    releaseLock(QUOTES_LOCK_FILE);
  }
};

const fetchEvents = async (): Promise<void> => {
  if (!tryAcquireLock(EVENTS_LOCK_FILE)) return;

  try {
    const m = now.getMonth() + 1;
    const d = now.getDate();
    const res = await fetch(`https://today.zenquotes.io/api/${m}/${d}`, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    const data = (await res.json()) as ZenEventsResponse;
    if (data?.data?.Events) {
      await Bun.write(EVENTS_FILE, JSON.stringify(data.data.Events));
    }
  } catch {
    // Offline / timeout: keep whatever cache we had; retry next session.
  } finally {
    releaseLock(EVENTS_LOCK_FILE);
  }
};

const spawnBackground = (flag: string): void => {
  // Double-fork: the intermediate `sh` exits immediately, so whoever called
  // us never waits on the fetcher. Bun.spawn's `unref`/`detached` do NOT
  // prevent waiting on children in bun 1.3.x, so we can't rely on them.
  // setsid + nohup fully detach the worker from the terminal.
  Bun.spawn(
    ["sh", "-c", `setsid nohup bun "$0" ${flag} >/dev/null 2>&1 &`, import.meta.path],
    { stdout: "ignore", stderr: "ignore" },
  );
};

// ── Main Processing Function ────────────────────────────────────────
const main = async (): Promise<void> => {
  if (args[0] === "--fetch-quotes") {
    await fetchQuotes();
    process.exit(0); // never fall through into the display path
  }

  if (args[0] === "--fetch-events") {
    await fetchEvents();
    process.exit(0);
  }

  let quoteText = "Action is the foundational key to all success.";
  let quoteAuthor = "Pablo Picasso";
  let needQuotesFetch = false;

  // 1. Quotes Processing (Sequential 50 Pool)
  if (existsSync(QUOTES_FILE)) {
    try {
      const quotes = (await Bun.file(QUOTES_FILE).json()) as ZenQuote[];
      let idx = 0;

      if (existsSync(INDEX_FILE)) {
        const idxText = await Bun.file(INDEX_FILE).text();
        idx = parseInt(idxText.trim(), 10) || 0;
      }

      if (idx < quotes.length) {
        quoteText = quotes[idx].q || quoteText;
        quoteAuthor = quotes[idx].a || quoteAuthor;

        let newIdx = idx + 1;
        if (newIdx >= quotes.length) {
          needQuotesFetch = true;
          newIdx = 0;
        }
        await Bun.write(INDEX_FILE, String(newIdx));
      } else {
        needQuotesFetch = true;
      }
    } catch {
      needQuotesFetch = true;
    }
  } else {
    needQuotesFetch = true;
  }

  // Only kick off a refill if none is in flight.
  if (needQuotesFetch && !isLockActive(QUOTES_LOCK_FILE)) {
    spawnBackground("--fetch-quotes");
  }

  // 2. On This Day Processing
  let eventText = "Historical event data initializing...";

  if (existsSync(EVENTS_FILE)) {
    try {
      const events = (await Bun.file(EVENTS_FILE).json()) as ZenEvent[];
      if (Array.isArray(events) && events.length > 0) {
        const selected = events[Math.floor(Math.random() * events.length)];
        const rawText = selected.text || "";
        eventText = rawText.replace(/\[\d+\]/g, "").trim();
      }
    } catch {}
  } else if (!isLockActive(EVENTS_LOCK_FILE)) {
    spawnBackground("--fetch-events");
  }

  // Print full untruncated output
  console.log(quoteText);
  console.log(quoteAuthor);
  console.log(eventText);
};

// Stale locks don't block spawning — the new worker will take them over.
const isLockActive = (lockFile: string): boolean => {
  if (!existsSync(lockFile)) return false;
  try {
    const ts = parseInt(readFileSync(lockFile, "utf8").trim(), 10) || 0;
    return Date.now() - ts <= LOCK_STALE_MS;
  } catch {
    return false;
  }
};

main();
