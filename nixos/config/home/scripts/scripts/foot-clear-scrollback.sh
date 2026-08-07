#!/usr/bin/env sh
# Clear the scrollback buffer of the focused foot terminal window.
# Works even when a foreground process (dev server, etc.) is running,
# because we write the escape sequence directly to the PTY, not via stdin.
#
# Like kitty's ctrl+shift+delete / clear_terminal action.

INFO=$(mmsg get focusing-client 2>/dev/null)
APPID=$(echo "$INFO" | jq -r '.appid // empty')

# Only act on foot windows — do nothing silently for other windows
if [ "$APPID" != "foot" ]; then
  exit 0
fi

FOOT_PID=$(echo "$INFO" | jq -r '.pid // empty')
if [ -z "$FOOT_PID" ]; then
  exit 1
fi

# Find the PTY by walking foot's child process tree.
# The direct child of foot (fish or foreground process) owns the PTY slave.
find_tty() {
  local parent=$1
  for cpid in $(pgrep -P "$parent" 2>/dev/null); do
    local tty
    tty=$(ps -o tty= -p "$cpid" 2>/dev/null | tr -d ' ')
    if [ -n "$tty" ] && [ "$tty" != "?" ]; then
      echo "$tty"
      return 0
    fi
    # Recurse into grandchildren (e.g. fish → dev server)
    find_tty "$cpid" && return 0
  done
  return 1
}

TTY=$(find_tty "$FOOT_PID")
if [ -n "$TTY" ]; then
  # \033[H  — cursor to home
  # \033[2J — clear visible screen
  # \033[3J — clear scrollback buffer
  printf '\033[H\033[2J\033[3J' > "/dev/$TTY"
fi
