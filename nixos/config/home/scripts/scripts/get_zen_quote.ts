#!/usr/bin/env bun
import { existsSync, mkdirSync, openSync, readFileSync, unlinkSync, writeSync, closeSync } from "fs";
import { join } from "path";

interface ZenQuote {
  q: string;
  a: string;
  h?: string;
  c?: string;
}

const HOME = process.env.HOME || "/home/sonny";
const CACHE_DIR = join(HOME, ".cache", "zenquotes");
const QUOTES_FILE = join(CACHE_DIR, "quotes.json");
const INDEX_FILE = join(CACHE_DIR, "index");
const LOCK_FILE = join(CACHE_DIR, "fetching.lock");

// The background fetcher must never hang forever: abort after 10s so an
// offline/slow network fails fast and we simply retry on the next session.
const FETCH_TIMEOUT_MS = 10_000;
// Locks older than this are considered stale (a previous worker died hard)
// and can be taken over.
const LOCK_STALE_MS = 60_000;

if (!existsSync(CACHE_DIR)) {
  mkdirSync(CACHE_DIR, { recursive: true });
}

const args = process.argv.slice(2);

// ── Lock helpers (prevent fetcher pile-up while offline) ───────────────
const tryAcquireLock = (): boolean => {
  const acquire = (): boolean => {
    try {
      const fd = openSync(LOCK_FILE, "wx"); // atomic create-exclusive
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
    const ts = parseInt(readFileSync(LOCK_FILE, "utf8").trim(), 10) || 0;
    if (Date.now() - ts > LOCK_STALE_MS) {
      unlinkSync(LOCK_FILE);
      return acquire();
    }
  } catch {}
  return false;
};

const releaseLock = (): void => {
  try {
    unlinkSync(LOCK_FILE);
  } catch {}
};

// ── Background Worker: Fetch fresh quote batch ─────────────────────────
const fetchQuotes = async (): Promise<void> => {
  // A fetcher is already running (possibly from another session) — skip.
  if (!tryAcquireLock()) return;

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
    releaseLock();
  }
};

const spawnBackground = (): void => {
  // Double-fork: the intermediate `sh` exits immediately, so whoever called
  // us (fish greeting / command substitution) never waits on the fetcher.
  // Bun.spawn's `unref`/`detached` do NOT prevent waiting on children in
  // bun 1.3.x, so we can't rely on them. setsid + nohup fully detach the
  // worker from the terminal so it survives shell/terminal exit.
  Bun.spawn(
    ["sh", "-c", 'setsid nohup bun "$0" --fetch-quotes >/dev/null 2>&1 &', import.meta.path],
    { stdout: "ignore", stderr: "ignore" },
  );
};

// ── Main ───────────────────────────────────────────────────────────────
const main = async (): Promise<void> => {
  if (args[0] === "--fetch-quotes") {
    await fetchQuotes();
    process.exit(0); // never fall through into the display path
  }

  let quoteText = "Action is the foundational key to all success.";
  let quoteAuthor = "Pablo Picasso";
  let needQuotesFetch = false;

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

  // Only kick off a refill if none is in flight (a fresh lock file means
  // another session's worker is already on it).
  if (needQuotesFetch && !isLockActive()) {
    spawnBackground();
  }

  console.log(quoteText);
  console.log(quoteAuthor);
};

// Stale locks don't block spawning — the new worker will take them over.
const isLockActive = (): boolean => {
  if (!existsSync(LOCK_FILE)) return false;
  try {
    const ts = parseInt(readFileSync(LOCK_FILE, "utf8").trim(), 10) || 0;
    return Date.now() - ts <= LOCK_STALE_MS;
  } catch {
    return false;
  }
};

main();
