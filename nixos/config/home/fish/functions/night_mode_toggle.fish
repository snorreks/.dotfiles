function night_mode_toggle
    if pgrep -x wlsunset > /dev/null
        # Gracefully stop via systemd (falls back to pkill if not running as a unit)
        systemctl --user stop wlsunset.service 2>/dev/null; or pkill -x wlsunset
    else
        # Start via systemd to pull settings from eye-protection.nix
        systemctl --user start wlsunset.service 2>/dev/null; or wlsunset -l 59.91 -L 10.75 -t 3500 -T 6500 &
    end
end
