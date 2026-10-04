#!/usr/bin/env bash
# nixos/config/system/media/scripts/jellyfin-accel-check.sh
#
# Decide whether hardware transcoding is actually available on THIS machine, and
# say which codecs, rather than assuming it from the fact that the machine has
# an Intel GPU.
#
# ── Why this exists as a check rather than a setting ────────────────────────
# "Intel QSV/VAAPI" is a claim about a driver, a render node, a codec build and
# a firmware GuC/HuC blob, all of which can each be present or absent
# independently. Enabling Jellyfin's hardware transcoding without checking
# produces a server that appears configured and falls back to software on every
# stream, quietly consuming the CPU — and, worse, that looks identical to a
# working setup in the logs.
#
# So the rule in the Nix module is: hardware acceleration is off by default and
# its ENABLING requires either a passing check or an explicit acknowledgement
# that the operator is overriding one. Both states are visible.
#
# ── What counts as a pass ───────────────────────────────────────────────────
# Not "an Intel GPU exists". All three of:
#
#   1. a VAAPI render node (/dev/dri/renderD*);
#   2. the intel-media-driver userspace, which is what actually creates the
#      VAAPI entrypoints;
#   3. at least one QSV or VAAPI codec entrypoint.
#
# NVIDIA is deliberately NOT in this check and is deliberately NOT configured
# for Jellyfin anywhere in this repository. The discrete GPU is for inference;
# giving the transcoder the same device is how inference stops having memory
# when someone starts a stream. Absence of NVIDIA here is the intended design,
# not a gap in coverage.
set -uo pipefail

VAINFO="${MEDI_VAINFO:-vainfo}"
REQUIRE_CODECS="${MEDI_REQUIRE_CODECS:-h264_vaapi hevc_vaapi}"
BUS="${MEDI_INTEL_BUS_ID:-}"

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
  failures=$((failures + 1))
  printf '  FAIL %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
}

printf '=== Jellyfin hardware capability check ===\n'
printf 'vainfo: %s\n' "$(command -v "$VAINFO" || echo '<not found>')"

# ── 1. Render node ──────────────────────────────────────────────────────────
render_node=""
for node in /dev/dri/renderD*; do
  [[ -e "$node" ]] || continue
  render_node="$node"
  break
done

if [[ -n "$render_node" ]]; then
  pass "VAAPI render node present: $render_node"
else
  fail "no /dev/dri/renderD* node" "the user must be in the 'video' or 'render' group for it to be usable"
fi

# ── 2. intel-media-driver ───────────────────────────────────────────────────
if command -v "$VAINFO" >/dev/null 2>&1; then
  pass "intel-media-driver userspace present ($VAINFO)"
else
  fail "vainfo not found" "install intel-media-driver; without it there are no VAAPI entrypoints to check"
fi

# ── 3. Codec entrypoints ────────────────────────────────────────────────────
# Enumerated, not assumed: the driver exposes a different set depending on the
# generation, and the ones this machine lacks are exactly the ones that would
# silently fall back to software.
available=""
if command -v "$VAINFO" >/dev/null 2>&1; then
  raw="$("$VAINFO" 2>/dev/null || true)"
  available="$(
    printf '%s\n' "$raw" |
      grep -oE 'VAProfile[A-Za-z0-9]+EntryPoint|VAProfile[A-Za-z0-9]+' |
      sed -E 's/^VAProfile//; s/EntryPoint$//' |
      tr '[:upper:]' '[:lower:]' |
      sort -u
  )"
fi

missing=""
for codec in $REQUIRE_CODECS; do
  if printf '%s\n' "$available" | grep -qx "$codec"; then
    pass "codec available: $codec"
  else
    missing="$missing $codec"
  fi
done

if [[ -n "$missing" ]]; then
  fail "required codec(s) absent:$missing" "streams in these will fall back to software transcoding"
fi

# ── 4. Report, and state the fallback plainly ───────────────────────────────
printf '\n--- detected VAAPI profiles ---\n'
if [[ -n "$available" ]]; then
  printf '%s\n' "$available" | sed 's/^/  /'
else
  printf '  (none enumerated)\n'
fi

printf '\n--- bus id ---\n'
if [[ -n "$BUS" ]]; then
  printf '  configured: %s\n' "$BUS"
  if command -v lspci >/dev/null 2>&1; then
    if lspci -s "$BUS" 2>/dev/null | grep -qiE 'vga|display|3d'; then
      pass "a display device is present at $BUS"
    else
      printf '  WARNING: no display device at %s — check the bus id.\n' "$BUS" >&2
      printf '           The Legion and the GS65 have DIFFERENT bus ids; a copy-pasted\n' >&2
      printf '           value from the other host is a silent misconfiguration.\n' >&2
    fi
  fi
else
  printf '  (unset)\n'
fi

printf '\n=== verdict ===\n'
if ((failures == 0)); then
  printf 'Hardware transcoding is available.\n'
  printf 'Enable it with: opts.media.jellyfin.hardwareAcceleration.enable = true\n'
  printf 'Software transcoding remains available as the explicit fallback and\n'
  printf 'is unaffected by this check.\n'
  exit 0
fi

cat >&2 <<'EOF'
Hardware transcoding is NOT available on this machine as configured.

Leave opts.media.jellyfin.hardwareAcceleration.enable = false. Jellyfin will
transcode in software, which is slower but correct, and which keeps the discrete
NVIDIA GPU entirely available for inference.

Enabling acceleration anyway is possible and is an explicit override:

    opts.media.jellyfin.hardwareAcceleration.enable = true;
    opts.media.jellyfin.hardwareAcceleration.acknowledgeMissing = true;

The second line exists so that a machine with no working acceleration has to
say so in the diff rather than inherit it silently.
EOF
exit 1