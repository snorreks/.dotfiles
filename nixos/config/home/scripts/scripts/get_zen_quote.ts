#!/usr/bin/env bun
import { existsSync, mkdirSync } from "fs";
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

if (!existsSync(CACHE_DIR)) {
  mkdirSync(CACHE_DIR, { recursive: true });
}

const args = process.argv.slice(2);

// ── Background Worker: Fetch fresh quote batch ─────────────────────────
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

const spawnBackground = (flag: string): void => {
  Bun.spawn(["bun", import.meta.path, flag], {
    stdout: "ignore",
    stderr: "ignore",
    unref: true,
  });
};

// ── Main ───────────────────────────────────────────────────────────────
const main = async (): Promise<void> => {
  if (args[0] === "--fetch-quotes") {
    await fetchQuotes();
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

  if (needQuotesFetch) {
    spawnBackground("--fetch-quotes");
  }

  console.log(quoteText);
  console.log(quoteAuthor);
};

main();
