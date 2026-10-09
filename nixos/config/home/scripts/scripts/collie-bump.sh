#!/usr/bin/env bash
# collie-bump — move the pinned Collie flake tag, and report what that tag
# actually delivers.
#
# WHY THIS EXISTS
#
# Collie is pinned by tag in nixos/flake.nix, deliberately, and the reasoning
# is recorded there: a branch would move under a plain `nix flake update` and
# swap the daemon a phone is talking to with no reviewable diff. Moving it is
# therefore meant to be an explicit, one-line, reviewable act. Editing that line
# by hand over SSH on a phone keyboard is the tedious part, not the risky part.
# This script is only the tedium.
#
# WHAT IT DOES NOT DO
#
# It never builds, never activates, never restarts anything, and never touches
# the running bridge. Activation is `ns-maint prepare` + `ns-maint activate` +
# `ns-maint confirm`, deliberately separate steps (docs/headless-server.md), and
# this script stops before all three. That separation is the point: a bump that
# also activated would collapse the 20-minute dead-man window into the same
# command that edits the file.
#
# THE PAYLOAD LAG — read this before assuming a tag gave you that version
#
# Upstream's packaging/nix/sources.json is written by the release workflow from
# the manifest of the PREVIOUS release, so it is one release behind at every
# tag. `url = github:AltanS/collie/v1.15.3` fetches the v1.15.0 tarball, and the
# binary genuinely reports 1.15.0. Asking for v1.18.1 fetches v1.17.2's tarball.
# So the tag you ask for and the version you get are different numbers, and this
# script prints BOTH: the tag it pinned, and the payload that tag's manifest
# names. Treat a large gap between them as the thing to notice, not a rounding
# error — that gap is upstream's release process, and only upstream can close it.
#
# USAGE
#
#   collie-bump 1.18.1        pin v1.18.1, lock, report the payload it resolves
#   collie-bump --check X.Y  resolve X.Y and print both versions, change nothing
#   collie-bump --current    print the current tag and payload, change nothing
#   collie-bump --latest     resolve the newest upstream tag, then pin it
#   collie-bump 1.18.1 --yes skip the confirmation prompt (for a phone over SSH)
set -euo pipefail

FLAKE_DIR="${COLLIE_FLAKE_DIR:-$HOME/.dotfiles/nixos}"
FLAKE_NIX="$FLAKE_DIR/flake.nix"
OWNER="AltanS"
REPO="collie"

# Only ever rewrite this exact substring. The flake pins herdr, pyroclear,
# bun2nix, rust-overlay and dozens of nixpkgs-derived inputs by URL; a looser
# pattern would eventually match one of those, and a bump that silently
# repoints an unrelated input is worse than no bump at all.
URL_RE='github:AltanS/collie/v[0-9][0-9.]*'

die() {
  printf 'collie-bump: %s\n' "$*" >&2
  exit 1
}

note() { printf 'collie-bump: %s\n' "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is not on PATH.
  It should be: curl and nix are in systemPackages, jq is in home.packages."
}

# The three tools this needs are split across two profiles: curl and nix are in
# environment.systemPackages (/run/current-system/sw/bin), while jq is in
# home.packages, which useUserPackages puts on the PER-USER profile
# (/etc/profiles/per-user/<user>/bin). An interactive login shell has both, but
# `ssh legion collie-bump 1.18.1` runs a non-login shell that may carry only the
# first — so jq would be missing on exactly the phone-over-SSH path this script
# exists for.
#
# Two candidates, both tried, neither required:
#
#   1. This script's own directory, from BASH_SOURCE rather than $0 — $0 is
#      whatever the caller typed, which may be a bare name resolved through PATH
#      and therefore useless as a directory. Invoked the normal way (as
#      `collie-bump` off the per-user profile) this resolves to the profile bin
#      directory, whose siblings include jq.
#   2. /etc/profiles/per-user/$(id -un)/bin, which is where useUserPackages puts
#      home.packages on every host in this repo. Needed for the other case:
#      running the store path directly, where the script's own directory
#      contains only itself and no jq.
self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" \
  || self_dir=""
per_user_bin="/etc/profiles/per-user/$(id -un 2>/dev/null)/bin"
for extra in "$self_dir" "$per_user_bin"; do
  [ -n "$extra" ] && [ -d "$extra" ] || continue
  case ":$PATH:" in
    *":$extra:"*) ;;
    *) PATH="$extra:$PATH" ;;
  esac
done
export PATH

# ── Resolve what a tag actually delivers ─────────────────────────────────────
#
# Read from the TAG, not from a revision we already have cached: the whole point
# is to learn what the tag resolves to BEFORE committing to it in flake.lock.
# Failure here means the tag does not exist, which is worth stopping for — a
# typo'd tag would otherwise land in flake.lock as a broken input.
#
# Print "<payload version>" on success. Everything else is a refusal.
resolve_payload() {
  local tag="$1" version
  version="$(curl -fsSL --max-time 30 \
    "https://raw.githubusercontent.com/${OWNER}/${REPO}/${tag}/packaging/nix/sources.json" 2>/dev/null \
    | jq -er '.version' 2>/dev/null)" \
    || die "cannot read packaging/nix/sources.json at ${tag}.
  Check the tag exists and that the file is still there:
    https://github.com/${OWNER}/${REPO}/releases/tag/${tag}"
  [[ -n "$version" ]] || die "sources.json at ${tag} has no version."
  printf '%s' "$version"
}

newest_tag() {
  local tag
  tag="$(curl -fsSL --max-time 30 \
    "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" 2>/dev/null \
    | jq -er '.tag_name' 2>/dev/null)" \
    || die "cannot reach the GitHub releases API for ${OWNER}/${REPO}."
  printf '%s' "$tag"
}

current_tag() {
  local tag
  tag="$(grep -oE "$URL_RE" "$FLAKE_NIX" | head -1)" || true
  [[ -n "$tag" ]] || die "no '${OWNER}/${REPO}/v…' input URL in ${FLAKE_NIX}.
  Is this still the shape of the collie input?"
  printf '%s' "${tag##*/}"
}

# The tag is written back as the bare vX.Y.Z; the input URL keeps its prefix.
pin_tag() {
  local tag="$1"
  # -i so a tag like v1.18.1 cannot become v1.18.1v1.18.1 on a re-run.
  sed -i.bak -E "s|(${OWNER}/${REPO}/)v[0-9][0-9.]*|\1${tag}|g" "$FLAKE_NIX" \
    || die "could not rewrite ${FLAKE_NIX}"
  rm -f "${FLAKE_NIX}.bak"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
#
# Normalised to a bare vX.Y.Z. Accepting 1.18.1, v1.18.1 and --latest all end
# up here, so the rest of the script only handles one shape.
CHECK_ONLY=0
ASSUME_YES=0
REQUESTED=""

# --yes is stripped in its own pass, before anything else is interpreted. Left
# to the main loop it would collide with the "this flag takes no other
# arguments" checks on --current and --latest, so `collie-bump --latest --yes`
# — the exact shape of the phone-over-SSH call — would be rejected for carrying
# a flag that does not change what is being asked for.
args=()
for a in "$@"; do
  case "$a" in
    --yes | -y) ASSUME_YES=1 ;;
    -h | --help)
      sed -n '/^# USAGE$/,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;$d'
      exit 0
      ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --current)
      [[ $# -eq 1 ]] || die "--current takes no other arguments."
      REQUESTED="current"
      shift
      ;;
    --check)
      [[ $# -ge 2 ]] || die "--check needs a version, e.g. --check 1.18.1"
      CHECK_ONLY=1
      REQUESTED="${2#v}"
      shift 2
      ;;
    --latest)
      [[ $# -eq 1 ]] || die "--latest takes no other arguments."
      REQUESTED="latest"
      shift
      ;;
    -*)
      die "unknown option '$1'. Try --help."
      ;;
    *)
      [[ -z "$REQUESTED" ]] || die "one version at a time, got '$REQUESTED' and '$1'."
      REQUESTED="${1#v}"
      shift
      ;;
  esac
done

[[ -n "$REQUESTED" ]] || die "no version given. Try --help, or: collie-bump --current"

need curl
need jq
need nix

# A tag is three dotted numbers and nothing else. This is the check that stops
# an argument from being interpolated into the URL or into flake.nix at all.
if [[ "$REQUESTED" == "current" || "$REQUESTED" == "latest" ]]; then
  :
else
  [[ "$REQUESTED" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "'$REQUESTED' is not a version like 1.18.1 (or a tag like v1.18.1)."
fi

[[ -d "$FLAKE_DIR" ]] || die "no flake at ${FLAKE_DIR}.
Set COLLIE_FLAKE_DIR if your checkout is somewhere else."
[[ -f "$FLAKE_NIX" ]] || die "no ${FLAKE_NIX}."

if [[ "$REQUESTED" == "current" ]]; then
  tag="$(current_tag)"
  printf 'pinned tag    %s\n' "$tag"
  printf 'payload       %s   (from sources.json at that tag)\n' "$(resolve_payload "$tag")"
  printf '\nThe payload trails the tag by design: that file is written from the\n'
  printf 'previous release. Both numbers above are real.\n'
  exit 0
fi

if [[ "$REQUESTED" == "latest" ]]; then
  REQUESTED="$(newest_tag)"
  REQUESTED="${REQUESTED#v}"
  note "newest upstream tag is v${REQUESTED}"
fi

tag="v${REQUESTED}"

# Ask the network what this tag yields BEFORE touching the file, so a typo or a
# yanked tag costs nothing.
payload="$(resolve_payload "$tag")"
note "v${REQUESTED} wraps payload ${payload}"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  printf '\n--check: nothing was changed.\n'
  printf '  tag     %s\n' "$tag"
  printf '  payload %s\n' "$payload"
  exit 0
fi

old_tag="$(current_tag)"
if [[ "$old_tag" == "$tag" ]]; then
  note "already pinned at ${tag} (payload ${payload}). Nothing to do."
  exit 0
fi

printf '\n'
printf '  flake     %s\n' "$FLAKE_NIX"
printf '  tag       %s -> %s\n' "$old_tag" "$tag"
printf '  payload   %s\n' "$payload"
printf '\n'

if [[ "$ASSUME_YES" -eq 0 ]]; then
  [[ -t 0 ]] || die "not a terminal and no --yes. Re-run with --yes, or --check first.
  (Over SSH from a phone, --yes is the normal path.)"
  read -r -p "Rewrite the pin? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || {
    note "aborted; nothing changed."
    exit 1
  }
fi

pin_tag "$tag"

# `nix flake lock` and not `nix flake update collie`: the former re-resolves only
# inputs whose declared URL changed, which is exactly this one. A bare
# `nix flake update` would drag nixpkgs along and move a great deal more than
# the operator asked for.
(cd "$FLAKE_DIR" && nix flake lock) || {
  pin_tag "$old_tag"
  die "nix flake lock failed; the pin was put back to ${old_tag}."
}

# Read the payload back out of the LOCKED revision, not out of the tag. That is
# the number the build will actually use, and it is the one worth having.
locked_rev="$(cd "$FLAKE_DIR" && nix flake metadata --json 2>/dev/null \
  | jq -er '.locks.nodes.collie.locked.rev')" \
  || die "cannot read the locked collie revision from ${FLAKE_DIR}/flake.lock."

locked_payload="$(resolve_payload "$locked_rev")" || locked_payload="(unreadable)"

printf '\n'
printf '  locked rev  %s\n' "$locked_rev"
printf '  payload     %s\n' "$locked_payload"
printf '\n'

if [[ "$locked_payload" != "$payload" ]]; then
  note "WARNING: the locked revision reports payload ${locked_payload},"
  note "         but ${tag} advertised ${payload}. Upstream moved under you."
  note "         Re-run 'collie-bump --current' before trusting either number."
fi

printf 'Pinned. NOTHING has been built or activated.\n'
printf '\n'
printf 'Next, as separate deliberate steps:\n'
printf '  ns-maint prepare      # build; arms nothing\n'
printf '  ns-maint activate     # arms the 20-min deadline, then applies\n'
printf '  ...verify from a SECOND connection (the phone over 443)...\n'
printf '  sudo ns-maint confirm <txid>\n'
printf '\n'
printf 'A collie bump changes ExecStart, so activation restarts the bridge.\n'
printf "The phone's websocket reconnects on its own. sshd is not restarted,\n"
printf 'and port 22 and 2222 remain your way back in either way.\n'
printf 'Rolling back: sudo nixos-rebuild switch-generation -\n'