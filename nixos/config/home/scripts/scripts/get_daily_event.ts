#!/usr/bin/env bun
import { existsSync, mkdirSync } from "fs";
import { join } from "path";

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

const now = new Date();
const todayStr = `${now.getFullYear()}_${String(now.getMonth() + 1).padStart(2, "0")}_${String(now.getDate()).padStart(2, "0")}`;
const EVENTS_FILE = join(CACHE_DIR, `events_${todayStr}.json`);

if (!existsSync(CACHE_DIR)) {
  mkdirSync(CACHE_DIR, { recursive: true });
}

const args = process.argv.slice(2);

// ── Background Worker: Fetch today's historical events ─────────────────
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

// ── Main ───────────────────────────────────────────────────────────────
const main = async (): Promise<void> => {
  if (args[0] === "--fetch-events") {
    await fetchEvents();
  }

  let eventText = "System active.";

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

  console.log(eventText);
};

main();
