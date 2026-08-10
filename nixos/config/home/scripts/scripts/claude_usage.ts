#!/usr/bin/env bun
import { existsSync, readFileSync } from "fs";
import { join } from "path";

const HOME = process.env.HOME || "/home/sonny";
const CREDENTIALS_FILE = join(HOME, ".claude", ".credentials.json");
const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";

// ── Tokyo Night Palette (truecolor, matches fish_greeting.fish) ─────────
const rgb = (r: number, g: number, b: number) => `\x1b[38;2;${r};${g};${b}m`;
const c = {
  blue: rgb(0x7a, 0xa2, 0xf7),
  purple: rgb(0xbb, 0x9a, 0xf7),
  cyan: rgb(0x7d, 0xcf, 0xff),
  green: rgb(0x9e, 0xce, 0x6a),
  yellow: rgb(0xe0, 0xaf, 0x68),
  red: rgb(0xf7, 0x76, 0x8e),
  dim: rgb(0x56, 0x5f, 0x89),
  bold: "\x1b[1m",
  reset: "\x1b[0m",
};

interface ClaudeOauthCredentials {
  accessToken: string;
  expiresAt: number;
  subscriptionType?: string;
  rateLimitTier?: string;
}

interface LimitEntry {
  kind: string;
  group: string;
  percent: number;
  severity: "normal" | "warning" | "critical" | string;
  resets_at: string | null;
  scope: string | null;
  is_active: boolean;
}

interface UsageResponse {
  limits: LimitEntry[];
  extra_usage?: {
    is_enabled: boolean;
    used_credits: number | null;
    monthly_limit: number | null;
    utilization: number | null;
  } | null;
  spend?: {
    enabled: boolean;
    used: { amount_minor: number; currency: string; exponent: number };
    percent: number;
  } | null;
}

// ── Credentials ───────────────────────────────────────────────────────

function readCredentials(): ClaudeOauthCredentials {
  if (!existsSync(CREDENTIALS_FILE)) {
    console.error(
      `${c.red}No Claude credentials found at ${CREDENTIALS_FILE}${c.reset}\n` +
        `Run ${c.cyan}claude${c.reset} once to log in with your subscription.`,
    );
    process.exit(1);
  }

  let parsed: { claudeAiOauth?: ClaudeOauthCredentials };
  try {
    parsed = JSON.parse(readFileSync(CREDENTIALS_FILE, "utf-8"));
  } catch {
    console.error(`${c.red}Could not parse ${CREDENTIALS_FILE}${c.reset}`);
    process.exit(1);
  }

  const oauth = parsed.claudeAiOauth;
  if (!oauth?.accessToken) {
    console.error(
      `${c.red}No OAuth access token in credentials.${c.reset}\n` +
        `This tool reads the same subscription session Claude Code uses — no separate API key needed.\n` +
        `Run ${c.cyan}claude${c.reset} once to log in.`,
    );
    process.exit(1);
  }

  return oauth;
}

// ── Fetch ─────────────────────────────────────────────────────────────

async function fetchUsage(accessToken: string): Promise<UsageResponse> {
  let res: Response;
  try {
    res = await fetch(USAGE_URL, {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "anthropic-version": "2023-06-01",
      },
      signal: AbortSignal.timeout(8000),
    });
  } catch (err) {
    console.error(`${c.red}Could not reach ${USAGE_URL}${c.reset} (${(err as Error).message})`);
    process.exit(1);
  }

  if (res.status === 401) {
    console.error(
      `${c.red}Access token expired or invalid (401).${c.reset}\n` +
        `Run ${c.cyan}claude${c.reset} once — it refreshes the token automatically — then retry.`,
    );
    process.exit(1);
  }
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    console.error(`${c.red}Usage request failed: HTTP ${res.status}${c.reset}\n${body.slice(0, 300)}`);
    process.exit(1);
  }

  return (await res.json()) as UsageResponse;
}

// ── Rendering helpers ───────────────────────────────────────────────────

function colorForPercent(percent: number): string {
  if (percent >= 90) return c.red;
  if (percent >= 70) return c.yellow;
  return c.green;
}

function bar(percent: number, width = 24): string {
  const clamped = Math.max(0, Math.min(100, percent));
  const filled = Math.round((clamped / 100) * width);
  const empty = width - filled;
  const color = colorForPercent(clamped);
  return `${c.dim}[${color}${"█".repeat(filled)}${c.dim}${"░".repeat(empty)}${c.dim}]${c.reset}`;
}

function formatResetsAt(resetsAt: string | null): string {
  if (!resetsAt) return "n/a";
  const resetDate = new Date(resetsAt);
  const diffMs = resetDate.getTime() - Date.now();
  if (diffMs <= 0) return "now";
  const totalMin = Math.round(diffMs / 60_000);
  const hours = Math.floor(totalMin / 60);
  const mins = totalMin % 60;
  if (hours > 0) return `resets in ${hours}h ${mins}m`;
  return `resets in ${mins}m`;
}

const KIND_LABELS: Record<string, string> = {
  session: "SESSION (5h)",
  weekly_all: "WEEKLY (7d)",
};

function labelForKind(kind: string): string {
  return (
    KIND_LABELS[kind] ??
    kind
      .split("_")
      .map((w) => w[0]?.toUpperCase() + w.slice(1))
      .join(" ")
  );
}

function padRight(text: string, width: number): string {
  // Pad based on visible length (strip ANSI codes for measurement).
  // biome-ignore lint/suspicious/noControlCharactersInRegex: measuring ANSI escape width
  const visible = text.replace(/\x1b\[[0-9;]*m/g, "");
  const pad = Math.max(0, width - visible.length);
  return text + " ".repeat(pad);
}

// ── Main ──────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const jsonMode = process.argv.includes("--json");
  const creds = readCredentials();
  const data = await fetchUsage(creds.accessToken);

  if (jsonMode) {
    console.log(JSON.stringify(data, null, 2));
    return;
  }

  const hr = "─".repeat(52);
  // Only render limits that are actually enforced (e.g. weekly limits with
  // no reset are not active — showing them is noise).
  const activeLimits = data.limits.filter((l) => l.kind && l.group && l.is_active);

  console.log();
  console.log(`  ${c.purple}╭── ${c.blue}${c.bold}⚡ CLAUDE USAGE${c.reset} ${c.dim}${hr}${c.reset}`);

  if (activeLimits.length === 0) {
    console.log(`  ${c.purple}│  ${c.dim}No usage data returned.${c.reset}`);
  }

  for (const limit of activeLimits) {
    const label = padRight(labelForKind(limit.kind), 14);
    const pct = padRight(`${Math.round(limit.percent)}%`, 4);
    const status = formatResetsAt(limit.resets_at);
    console.log(
      `  ${c.purple}│ ${c.cyan}${label}${c.dim}:: ${c.reset}${bar(limit.percent)} ${colorForPercent(
        limit.percent,
      )}${pct}${c.reset} ${c.dim}· ${status}${c.reset}`,
    );
  }

  if (data.extra_usage?.is_enabled) {
    const util = data.extra_usage.utilization ?? 0;
    console.log(
      `  ${c.purple}│ ${c.cyan}${padRight("EXTRA USAGE", 14)}${c.dim}:: ${c.reset}${bar(util)} ${colorForPercent(
        util,
      )}${padRight(`${Math.round(util)}%`, 4)}${c.reset}`,
    );
  }

  console.log(`  ${c.purple}├─── ${c.yellow}${c.bold}PLAN${c.reset} ${c.dim}${hr}${c.reset}`);
  console.log(
    `  ${c.purple}│ ${c.cyan}${padRight("SUBSCRIPTION", 14)}${c.dim}:: ${c.reset}${
      creds.subscriptionType ?? "unknown"
    } ${c.dim}(tier: ${creds.rateLimitTier ?? "unknown"})${c.reset}`,
  );
  console.log(`  ${c.purple}╰${c.dim}${hr}───────${c.reset}`);
  console.log();
}

main().catch((err) => {
  console.error(`${c.red}Unexpected error:${c.reset} ${(err as Error).message}`);
  process.exit(1);
});
