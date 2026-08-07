#!/usr/bin/env bun
import { existsSync, mkdirSync } from "fs";
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

const now = new Date();
const todayStr = `${now.getFullYear()}_${String(now.getMonth() + 1).padStart(2, "0")}_${String(now.getDate()).padStart(2, "0")}`;
const EVENTS_FILE = join(CACHE_DIR, `events_${todayStr}.json`);

if (!existsSync(CACHE_DIR)) {
  mkdirSync(CACHE_DIR, { recursive: true });
}

const args = process.argv.slice(2);

// ── Background Worker Handlers ─────────────────────────────────────
const fetchQuotes = async (): Promise<void> => {
  try {
    const res = await fetch("https://zenquotes.io/api/quotes");
    const data = (await res.json()) as ZenQuote[];
    if (Array.isArray(data) && data.length > 0) {
      await Bun.write(QUOTES_FILE, JSON.stringify(data));
      await Bun.write(INDEX_FILE, "0");
    }
  } catch {}
  process.exit(0);
};

const fetchEvents = async (): Promise<void> => {
  try {
    const m = now.getMonth() + 1;
    const d = now.getDate();
    const res = await fetch(`https://today.zenquotes.io/api/${m}/${d}`);
    const data = (await res.json()) as ZenEventsResponse;
    if (data?.data?.Events) {
      await Bun.write(EVENTS_FILE, JSON.stringify(data.data.Events));
    }
  } catch {}
  process.exit(0);
};

const spawnBackground = (flag: string): void => {
  Bun.spawn(["bun", import.meta.path, flag], {
    stdout: "ignore",
    stderr: "ignore",
    unref: true,
  });
};

// ── Main Processing Function ────────────────────────────────────────
const main = async (): Promise<void> => {
  if (args[0] === "--fetch-quotes") {
    await fetchQuotes();
  }

  if (args[0] === "--fetch-events") {
    await fetchEvents();
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

  if (needQuotesFetch) {
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
  } else {
    spawnBackground("--fetch-events");
  }

  // Print full untruncated output
  console.log(quoteText);
  console.log(quoteAuthor);
  console.log(eventText);
};

main();
