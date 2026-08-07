#!/usr/bin/env bash
# vpn-connect.sh
# Proton VPN WireGuard manager with latency ranking, country filtering, & direct server targeting.

set -euo pipefail

CONFIG_DIR="${VPN_CONFIG_DIR:-$HOME/.vpn/configs}"
TARGET="/etc/nixos/proton-wg.conf"
MAX_RETRIES="${VPN_MAX_RETRIES:-5}"
HEALTH_CHECK_HOST="${VPN_HEALTH_CHECK_HOST:-1.1.1.1}"
FAILED_MARKER_DIR="${XDG_RUNTIME_DIR:-/tmp}/vpn-failed-servers"
SERVER_STATUS_FILE="${XDG_RUNTIME_DIR:-/tmp}/current-vpn-server"
MARKER_TTL_MINS=30

notify() {
    notify-send -t 3000 "VPN" "$1" 2>/dev/null || true
}

update_waybar() {
    pkill -RTMIN+8 waybar 2>/dev/null || true
}

mark_failed() {
    mkdir -p "$FAILED_MARKER_DIR"
    touch "$FAILED_MARKER_DIR/$1"
}

get_server_label() {
    grep -oP '^# \K.*' "$1" 2>/dev/null | head -n 1 || echo ""
}

usage() {
    cat << EOF
Usage: vpn-connect [OPTIONS] [SERVER_OR_COUNTRY]

Options:
  -l, --list                  List available servers with measured latency
  -c, --country, --region     Filter servers by country code (e.g. nl, us, jp, ca)
  -s, --server                Connect directly to a specific server (e.g. nl-free-30)
  -h, --help                  Show this help message

Examples:
  vpn-connect                 # Connect/rotate to fastest server globally
  vpn-connect --list          # Print table of all servers and latencies
  vpn-connect --country nl    # Connect to the lowest-latency Dutch server
  vpn-connect us              # Short syntax to connect to best US server
  vpn-connect nl-free-30      # Direct connect to specific server
EOF
    exit 0
}

# --- Argument Parsing ---
ACTION="connect"
FILTER_QUERY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--list)
            ACTION="list"
            shift
            ;;
        -c|--country|--region)
            FILTER_QUERY="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        -s|--server)
            FILTER_QUERY="$(echo "$2" | tr '[:upper:]' '[:lower:]' | tr -d '#')"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            FILTER_QUERY="$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '#')"
            shift
            ;;
    esac
done

# 1. Purge failure markers older than 30 minutes
mkdir -p "$FAILED_MARKER_DIR"
find "$FAILED_MARKER_DIR" -type f -mmin +"$MARKER_TTL_MINS" -delete 2>/dev/null || true

# 2. Gather available configs
mapfile -t all_configs < <(find -L "$CONFIG_DIR" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | sort)

if [ "${#all_configs[@]}" -eq 0 ]; then
    notify "No valid WireGuard configs found in $CONFIG_DIR"
    exit 1
fi

# 3. Filter candidates by Country or Server Name
matched_configs=()
if [ -n "$FILTER_QUERY" ]; then
    for cfg in "${all_configs[@]}"; do
        [ -f "$cfg" ] || continue
        cfg_name="$(basename "$cfg" .conf)"
        label=$(get_server_label "$cfg" | tr '[:upper:]' '[:lower:]' | tr -d '#')

        # Match filename or server label against search query
        if [[ "$cfg_name" == *"$FILTER_QUERY"* || "$label" == *"$FILTER_QUERY"* ]]; then
            matched_configs+=("$cfg")
        fi
    done

    if [ "${#matched_configs[@]}" -eq 0 ]; then
        echo "[VPN] Error: No server configs matched '$FILTER_QUERY'"
        notify "No VPN servers matched '$FILTER_QUERY'"
        exit 1
    fi
else
    matched_configs=("${all_configs[@]}")
fi

# 4. Action: LIST SERVERS
if [ "$ACTION" = "list" ]; then
    echo "=========================================================================="
    printf "%-18s %-15s %-22s %-10s\n" "CONFIG NAME" "LABEL" "ENDPOINT" "LATENCY"
    echo "--------------------------------------------------------------------------"

    for cfg in "${matched_configs[@]}"; do
        [ -f "$cfg" ] || continue
        cfg_name="$(basename "$cfg" .conf)"
        label=$(get_server_label "$cfg")
        endpoint=$(sed -n -E 's/^\s*Endpoint\s*=\s*([^:]+):.*/\1/p' "$cfg" 2>/dev/null || true)

        rtt="TIMEOUT"
        if [ -n "$endpoint" ]; then
            ping_res=$(ping -c 1 -W 1 "$endpoint" 2>/dev/null | sed -n -E 's/.*time=([0-9.]+).*/\1/p' || true)
            if [ -n "$ping_res" ]; then
                rtt="${ping_res} ms"
            fi
        fi

        printf "%-18s %-15s %-22s %-10s\n" "$cfg_name" "${label:-$cfg_name}" "${endpoint:-N/A}" "$rtt"
    done
    echo "=========================================================================="
    exit 0
fi

# 5. Filter out failed markers (unless explicit filter was requested)
candidates=()
for cfg in "${matched_configs[@]}"; do
    [ -f "$cfg" ] || continue
    cfg_name="$(basename "$cfg" .conf)"
    if [ ! -f "$FAILED_MARKER_DIR/$cfg_name" ] || [ -n "$FILTER_QUERY" ]; then
        candidates+=("$cfg")
    fi
done

if [ "${#candidates[@]}" -eq 0 ]; then
    rm -f "$FAILED_MARKER_DIR"/*
    candidates=("${matched_configs[@]}")
    notify "Resetting failed server pool"
fi

# 6. Measure Latency & Rank
if systemctl is-active --quiet wg-quick-wg0.service 2>/dev/null; then
    notify "Switching server..."
else
    notify "Connecting..."
fi

echo "[VPN] Testing responsiveness of ${#candidates[@]} candidate servers..."
ranked_candidates=()

for cfg in "${candidates[@]}"; do
    [ -f "$cfg" ] || continue
    endpoint=$(sed -n -E 's/^\s*Endpoint\s*=\s*([^:]+):.*/\1/p' "$cfg" 2>/dev/null || true)

    if [ -n "$endpoint" ]; then
        rtt=$(ping -c 1 -W 1 "$endpoint" 2>/dev/null | sed -n -E 's/.*time=([0-9.]+).*/\1/p' || true)
        if [ -n "$rtt" ]; then
            formatted_rtt=$(printf "%08.2f" "$rtt")
            ranked_candidates+=("$formatted_rtt $cfg")
        fi
    fi
done

if [ "${#ranked_candidates[@]}" -gt 0 ]; then
    mapfile -t sorted_candidates < <(printf "%s\n" "${ranked_candidates[@]}" | sort -n | awk '{print $2}')
else
    sorted_candidates=("${candidates[@]}")
fi

total_candidates=${#sorted_candidates[@]}
if [ "$MAX_RETRIES" -gt "$total_candidates" ]; then
    MAX_RETRIES="$total_candidates"
fi

# 7. Attempt Connection Loop
retry=0
while [ "$retry" -lt "$MAX_RETRIES" ]; do
    chosen="${sorted_candidates[$retry]}"
    [ -f "$chosen" ] || { retry=$((retry + 1)); continue; }

    server_name="$(basename "$chosen" .conf)"
    echo "[VPN] Attempt $((retry + 1))/$MAX_RETRIES — trying $server_name ..."

    if ! sudo /run/current-system/sw/bin/cp "$chosen" "$TARGET"; then
        notify "Failed to copy config for $server_name"
        retry=$((retry + 1))
        continue
    fi

    sudo /run/current-system/sw/bin/systemctl stop wg-quick-wg0.service 2>/dev/null || true

    if ! sudo /run/current-system/sw/bin/systemctl start wg-quick-wg0.service; then
        notify "Failed to start VPN with $server_name"
        mark_failed "$server_name"
        retry=$((retry + 1))
        continue
    fi

    ping -c 1 -W 2 "$HEALTH_CHECK_HOST" >/dev/null 2>&1 || true
    sleep 2

    HANDSHAKE_TIME=$(sudo /run/current-system/sw/bin/wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")
    if [[ -z "$HANDSHAKE_TIME" || ! "$HANDSHAKE_TIME" =~ ^[0-9]+$ || "$HANDSHAKE_TIME" -eq 0 ]]; then
        echo "[VPN] WireGuard handshake not established for $server_name"
        notify "Handshake failed for $server_name"
        sudo /run/current-system/sw/bin/systemctl stop wg-quick-wg0.service 2>/dev/null || true
        mark_failed "$server_name"
        retry=$((retry + 1))
        continue
    fi

    if ping -c 2 -W 3 "$HEALTH_CHECK_HOST" >/dev/null 2>&1; then
        echo "[VPN] Connected successfully to $server_name"
        SERVER_LABEL=$(get_server_label "$chosen")
        echo "${SERVER_LABEL:-$server_name}" > "$SERVER_STATUS_FILE"
        notify "Connected to ${SERVER_LABEL:-$server_name}"
        update_waybar
        exit 0
    fi

    echo "[VPN] Health check failed for $server_name"
    notify "Health check failed for $server_name — trying next..."
    sudo /run/current-system/sw/bin/systemctl stop wg-quick-wg0.service 2>/dev/null || true
    mark_failed "$server_name"
    retry=$((retry + 1))
done

sudo /run/current-system/sw/bin/systemctl stop wg-quick-wg0.service 2>/dev/null || true
rm -f "$SERVER_STATUS_FILE"
notify "VPN connection failed after $MAX_RETRIES attempts"
update_waybar
exit 1
