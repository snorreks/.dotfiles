function fish_greeting
    # Skip greeting in popup/floating terminals
    if set -q FISH_NO_GREETING
        return
    end

    # ── Tokyo Night Palette & Styles ───────────────────────────────────
    set -l c_blue   (set_color 7aa2f7)
    set -l c_purple (set_color bb9af7)
    set -l c_cyan   (set_color 7dcfff)
    set -l c_green  (set_color 9ece6a)
    set -l c_yellow (set_color e0af68)
    set -l c_red    (set_color f7768e)
    set -l c_dim    (set_color 565f89)
    set -l c_ital   (set_color --italics)
    set -l reset    (set_color normal)

    # ── Foot Hyperlink Helper (OSC 8) ───────────────────────────────────
    function __link -d "Create OSC 8 hyperlink for Foot"
        echo -ne "\e]8;;$argv[1]\e\\$argv[2]\e]8;;\e\\"
    end

    # ── Uptime Calculation ──────────────────────────────────────────────
    set -l uptime_str "ready"
    if test -f /proc/uptime
        set -l total_sec (math "floor("(cat /proc/uptime | awk '{print $1}')")")
        set -l days (math "floor($total_sec / 86400)")
        set -l hours (math "floor(($total_sec % 86400) / 3600)")
        set -l mins (math "floor(($total_sec % 3600) / 60)")

        set -l parts
        test $days -gt 0; and set -a parts "$days"d
        test $hours -gt 0; and set -a parts "$hours"h
        set -a parts "$mins"m
        set uptime_str (string join " " $parts)
    end

    # ── System Info & Memory Block Bar Gauge ────────────────────────────
    set -l kernel (uname -r | cut -d'-' -f1)
    set -l ram_str "N/A"
    if test -f /proc/meminfo
        set -l total_kb (awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
        set -l avail_kb (awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)

        if test -n "$total_kb"; and test -n "$avail_kb"
            set -l used_kb (math "$total_kb - $avail_kb")
            set -l ram_used_gb (math -s1 "$used_kb / 1048576")
            set -l ram_total_gb (math -s1 "$total_kb / 1048576")
            set -l ram_pct (math "floor(($used_kb / $total_kb) * 100)")

            # 5-stage progress bar
            set -l filled (math "floor($ram_pct / 20)")
            set -l empty (math "5 - $filled")
            set -l bar ""
            test $filled -gt 0; and set bar "$bar"(string repeat -n $filled "█")
            test $empty -gt 0; and set bar "$bar"(string repeat -n $empty "░")

            set ram_str (string join "" $ram_used_gb "/" $ram_total_gb "GB " $c_dim "[" $c_green $bar $c_dim "] " $ram_pct "%" $reset)
        end
    end

    # Time-based Status Msg
    set -l hour (date +%H)
    set -l sys_status "ONLINE"
    if test $hour -lt 12
        set sys_status "MORNING PROTOCOL"
    else if test $hour -lt 18
        set sys_status "SYSTEM NOMINAL"
    else
        set sys_status "NETRUNNER // NIGHT SHIFT"
    end

    # Dynamic Foot Window Title (OSC 2)
    echo -ne "\e]2;⚡ $USER@$hostname — $sys_status\a"

    # Hyperlinks for Foot terminal
    set -l nix_link (__link "https://search.nixos.org/packages" "NixOS")
    set -l bun_link (__link "https://bun.sh" "🧅 Bun")
    set -l nix_stack_link (__link "https://nixos.org" "󰏗 Nix")

    # ── Fetch Zen Quote ─────────────────────────────────────────────────
    set -l zen_data (get_zen_quote 2>/dev/null)
    set -l quote_text   "Action is the foundational key to all success."
    set -l quote_author "Pablo Picasso"

    if test (count $zen_data) -ge 2
        set quote_text   $zen_data[1]
        set quote_author $zen_data[2]
    end

    # ── Cyber HUD Box Render ───────────────────────────────────────────
    # Standardized horizontal rule line length
    set -l hr (string repeat -n 52 "─")

    echo
    echo "  $c_purple╭── $c_blue⚡ $sys_status $c_dim$hr$reset"
    echo "  $c_purple│ $c_cyan  OS       $c_dim::$reset $nix_link $c_dim(Linux $kernel)$reset"
    echo "  $c_purple│ $c_green󰅐  UPTIME   $c_dim::$reset $uptime_str $c_dim│$reset RAM: $ram_str"
    echo "  $c_purple│ $c_yellow󰟶  NODE     $c_dim::$reset $USER@$hostname $c_dim(Fish $FISH_VERSION)$reset"
    echo "  $c_purple│ $c_red⚡ STACK    $c_dim::$reset $c_yellow$bun_link $c_green🥧 Pi $c_blue🐑 Herdr $c_purple🌙 Moon $c_cyan$nix_stack_link$reset"
    echo "  $c_purple├─── $c_cyan💬 QUOTE $c_dim$hr$reset"

    # Multi-Line Quote (Wrapped cleanly with matching indents)
    set -l q_wrapped (echo "$quote_text" | fold -s -w 56)
    for line in $q_wrapped
        echo "  $c_purple│  $reset$c_ital$line$reset"
    end
    echo "  $c_purple│  $reset$c_dim— $c_yellow$quote_author$reset"
    echo "  $c_purple╰$c_dim$hr───────$reset"
    echo
end
