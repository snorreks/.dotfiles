// nixos/config/home/dashboard/qml/Sys.qml
//
// Every non-notification data source the panel reads, in one place.
//
// Two rules, in this order:
//   1. Never poll for something that has a push source.
//   2. Never run ANYTHING for a view that is not on screen.
//
// Rule 2 is why every helper process below is gated on a view flag. With the
// drawer closed this shell owns zero subprocesses — only D-Bus subscriptions,
// which cost nothing while idle. That matters because this process is now the
// notification daemon and therefore runs for the whole session.
//
//   power   : Quickshell.Services.UPower → power-profiles-daemon. Live D-Bus
//             property, read and write. No process.
//   audio   : Quickshell.Services.Pipewire. Live binding. No process.
//   light   : `sys-daemon waybar light`  — brightness AND the eye-protection
//   vpn     : `sys-daemon waybar vpn`      state in one stream. Both are read
//             only by HomeView, so both run only while HomeView is up. A
//             freshly started stream emits current state immediately, so
//             gating them costs nothing but a spawn per open.
//   weather : the `--once` binaries waybar already uses. Fetched on open, not
//   agenda  : on a background timer — waybar's own modules already keep these
//             live for the bar, so a closed panel has no reason to hit the
//             network. Re-fetch is suppressed for 5 minutes after the last one.
//   stats   : dashboard-stats, 3s, ONLY while SystemView is up.
//   fan     : dashboard-fan, on the same 3s tick as stats — sysfs reads off
//             the msi-ec platform device, so it rides the tick that already
//             exists rather than owning one.
//   kbd     : dashboard-kbd, once per SystemView open and after each write.
//             Nothing else on this machine touches the keyboard lighting, so
//             there is nothing to poll for.
//   toggles : dashboard-toggles, 5s, ONLY while HomeView is up —
//             wifi/bluetooth/airplane have no push source, but one script
//             spawn beats the three swaync ran.
//   calendar: computed locally, refreshed hourly.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower

Singleton {
    id: root

    // Set by shell.qml so nothing polls, and no helper process runs, for a
    // view that is not on screen — or for a panel that is closed.
    property bool drawerActive: false
    property bool statsActive: false
    property bool togglesActive: false

    // ── Power profile ────────────────────────────────────────────────────
    // Quickshell.Services.UPower talks to power-profiles-daemon over D-Bus
    // directly: a live property, readable at startup and writable in place.
    //
    // This used to read `sys-daemon waybar power` instead. That was a
    // permanently-running subprocess whose first line only arrived once PPD
    // answered — which on this machine can take ten seconds — so the selector
    // rendered with nothing highlighted on open and did not visibly react to
    // its own clicks. Both symptoms are gone with the native binding, and the
    // process count drops by one. waybar keeps its own stream; both read the
    // same PPD property, so the bar and the panel cannot disagree.
    readonly property int powerProfile: PowerProfiles.profile

    function setPower(profile: int): void {
        PowerProfiles.profile = profile;
    }

    // ── Brightness + eye protection ──────────────────────────────────────
    // Both come out of one stream. `text` is "󱩍 90%" and `class` is one of
    // eye-off / eye-on / eye-forced, so the percentage and the wlsunset state
    // arrive together and neither needs a probe of its own.
    //
    // Writes go through change_brightness, NOT sysfs: on this machine the
    // brightness of record is /tmp/custom_brightness, which that script owns
    // along with the debounced ddcutil fan-out to the external displays.
    // Poking /sys/class/backlight directly (what swaync's backlight widget
    // did) moves the laptop panel only and then disagrees with the bar.
    property int brightness: 50
    property string eyeClass: "eye-off"
    readonly property bool eyeOn: eyeClass !== "eye-off"

    Process {
        command: ["sys-daemon", "waybar", "light"]
        running: root.togglesActive
        stdout: SplitParser {
            onRead: line => {
                try {
                    const j = JSON.parse(line);
                    const m = /(\d+)%/.exec(j.text ?? "");
                    if (m)
                        root.brightness = parseInt(m[1]);
                    root.eyeClass = j.class ?? "eye-off";
                } catch (e) {}
            }
        }
    }

    function setBrightness(pct: int): void {
        oneShot.exec(["change_brightness", String(Math.max(5, Math.min(100, Math.round(pct))))]);
    }

    // ── VPN ──────────────────────────────────────────────────────────────
    property string vpnClass: "vpn-off"
    readonly property bool vpnOn: vpnClass === "vpn-on"
    readonly property bool vpnBusy: vpnClass === "vpn-loading"

    Process {
        command: ["sys-daemon", "waybar", "vpn"]
        running: root.togglesActive
        stdout: SplitParser {
            onRead: line => {
                try {
                    root.vpnClass = (JSON.parse(line).class) ?? "vpn-off";
                } catch (e) {}
            }
        }
    }

    // ── Audio (Pipewire, live) ───────────────────────────────────────────
    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property real volume: sink?.audio?.volume ?? 0
    readonly property bool muted: sink?.audio?.muted ?? false

    // Without a tracker the node's audio properties are never bound and read
    // back as 0 — Pipewire objects are lazily subscribed.
    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    function setVolume(v: real): void {
        if (root.sink?.audio)
            root.sink.audio.volume = Math.max(0, Math.min(1, v));
    }

    function toggleMute(): void {
        if (root.sink?.audio)
            root.sink.audio.muted = !root.sink.audio.muted;
    }

    // ── Weather ──────────────────────────────────────────────────────────
    property string weatherText: ""
    property string weatherTooltip: ""

    // weather.py's render() joins its sections with "\n\n":
    //   [ head, "Next hours" block, "Next days" block, footer ]
    // and head is itself up to four lines: place·description / temperature /
    // wind+humidity+rain / sunrise+sunset.
    //
    // The panel showed that whole blob verbatim, which is a wall of text for
    // a glance-first tile. Split it here so the card can show the headline
    // plus one dim facts line, and keep the forecast behind a tap.
    readonly property var weatherParts: weatherTooltip.length > 0 ? weatherTooltip.split("\n\n") : []
    readonly property var weatherHeadLines: weatherParts.length > 0 ? weatherParts[0].split("\n") : []

    readonly property string weatherPlace: weatherHeadLines.length > 0 ? weatherHeadLines[0] : ""

    // Lines 2+ of the head — wind/humidity/rain and sunrise/sunset. The
    // temperature line (index 1) is dropped: `weatherText` already shows it.
    readonly property string weatherFacts: weatherHeadLines.length > 2 ? weatherHeadLines.slice(2).join("   ") : ""

    // Everything between head and footer: the hourly and daily blocks.
    readonly property string weatherForecast: weatherParts.length >= 3 ? weatherParts.slice(1, -1).join("\n\n") : ""

    Process {
        id: weatherProc
        command: ["waybar-weather", "--once"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const j = JSON.parse(text);
                    root.weatherText = j.text ?? "";
                    root.weatherTooltip = j.tooltip ?? "";
                } catch (e) {}
            }
        }
    }
    Timer {
        interval: 15 * 60 * 1000
        running: root.drawerActive
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetch(weatherProc, "weather")
    }

    // ── Agenda ───────────────────────────────────────────────────────────
    property string agendaTooltip: ""

    // The event-listing slice of the tooltip, with the embedded mini calendar
    // (this panel has its own calendar tile) and the "synced HH:MM · click →"
    // footer stripped. agenda.py's emit() joins
    // [month_grid, "", agenda_lines, "", footer] with "\n", so splitting on the
    // blank line isolates agenda_lines exactly, regardless of any blank lines
    // inside it.
    readonly property string agendaEvents: {
        const parts = agendaTooltip.split("\n\n");
        return parts.length >= 3 ? parts.slice(1, -1).join("\n\n") : agendaTooltip;
    }

    Process {
        id: agendaProc
        command: ["waybar-agenda", "--once"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.agendaTooltip = (JSON.parse(text).tooltip) ?? "";
                } catch (e) {}
            }
        }
    }
    Timer {
        interval: 15 * 60 * 1000
        running: root.drawerActive
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetch(agendaProc, "agenda")
    }

    // `triggeredOnStart` fires every time the drawer opens, so without this a
    // burst of opens would be a burst of network fetches. Nothing here changes
    // faster than the bar's own copy of these modules already tracks.
    property var fetchedAt: ({})

    function fetch(proc: Process, key: string): void {
        const now = Date.now();
        if (now - (fetchedAt[key] ?? 0) < 5 * 60 * 1000)
            return;
        fetchedAt[key] = now;
        proc.running = true;
    }

    // ── CPU / mem / temp / disk / uptime / top processes ──────────────────
    property real load: 0
    property int cores: 1
    property int memPct: 0
    property int memUsedKb: 0
    property int memTotalKb: 0
    property int swapPct: 0
    property int diskPct: 0
    property int diskUsedKb: 0
    property int diskTotalKb: 0
    property int uptimeS: 0
    property int tempC: 0
    property var topProcs: []

    readonly property real cpuFrac: Math.min(1, cores > 0 ? load / cores : 0)

    Process {
        id: statsProc
        command: ["dashboard-stats"]
        stdout: StdioCollector {
            onStreamFinished: {
                let j;
                try {
                    j = JSON.parse(text);
                } catch (e) {
                    return;
                }
                root.load = j.load ?? 0;
                root.cores = j.cores ?? 1;
                root.memPct = j.mem_pct ?? 0;
                root.memUsedKb = j.mem_used_kb ?? 0;
                root.memTotalKb = j.mem_total_kb ?? 0;
                root.swapPct = j.swap_pct ?? 0;
                root.diskPct = j.disk_pct ?? 0;
                root.diskUsedKb = j.disk_used_kb ?? 0;
                root.diskTotalKb = j.disk_total_kb ?? 0;
                root.uptimeS = j.uptime_s ?? 0;
                root.tempC = j.temp_c ?? 0;
                root.topProcs = j.top ?? [];
            }
        }
    }
    Timer {
        interval: 3000
        running: root.statsActive
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            statsProc.running = true;
            // Same tab, same tick, one more sysfs read — see "Fan / cooling"
            // below for why this doesn't get a timer of its own.
            fanProc.running = true;
        }
    }

    // The keyboard's lighting can only be changed by this panel, so unlike the
    // fan it has nothing to poll for — read it once each time the tab comes up
    // and then only after this shell's own writes (see kbdSettle).
    onStatsActiveChanged: if (statsActive)
        kbdProc.running = true

    // ── Quick toggles with no push source ────────────────────────────────
    property bool wifiOn: false
    property bool btOn: false
    property bool airplaneOn: false

    Process {
        id: togglesProc
        command: ["dashboard-toggles"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const j = JSON.parse(text);
                    root.wifiOn = j.wifi ?? false;
                    root.btOn = j.bluetooth ?? false;
                    root.airplaneOn = j.airplane ?? false;
                } catch (e) {}
            }
        }
    }
    Timer {
        id: togglesTimer
        interval: 5000
        running: root.togglesActive
        repeat: true
        triggeredOnStart: true
        onTriggered: togglesProc.running = true
    }

    // Toggle scripts are async (nmcli/rfkill take a moment to settle), so
    // re-probe shortly after the click instead of waiting out the 5s tick.
    function runToggle(cmd: string): void {
        oneShot.exec([cmd]);
        settle.restart();
    }
    Timer {
        id: settle
        interval: 700
        repeat: false
        onTriggered: togglesProc.running = true
    }

    // ── Calendar: native month grid, Monday-first, ISO week numbers ───────
    // (Not sourced from waybar-agenda's tooltip — that has its own compact
    // grid meant for a GTK tooltip. This mirrors waybar's own `clock` module
    // calendar config: iso8601 week numbers, Monday-first rows.)
    property var calRows: calGrid()
    property string calMonth: Qt.formatDate(new Date(), "MMMM yyyy")

    function isoWeek(d: date): int {
        const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
        const day = (t.getUTCDay() + 6) % 7; // Monday=0 .. Sunday=6
        t.setUTCDate(t.getUTCDate() - day + 3); // nearest Thursday
        const firstThursday = new Date(Date.UTC(t.getUTCFullYear(), 0, 4));
        const firstDay = (firstThursday.getUTCDay() + 6) % 7;
        firstThursday.setUTCDate(firstThursday.getUTCDate() - firstDay + 3);
        return 1 + Math.round((t - firstThursday) / (7 * 86400000));
    }

    // 6 rows x 8 cols (week-number column + 7 days), Monday-first.
    function calGrid(): var {
        const now = new Date();
        const first = new Date(now.getFullYear(), now.getMonth(), 1);
        const firstWeekday = (first.getDay() + 6) % 7; // Monday=0
        const start = new Date(first);
        start.setDate(first.getDate() - firstWeekday);

        const rows = [];
        for (let r = 0; r < 6; r++) {
            const days = [];
            for (let c = 0; c < 7; c++) {
                const d = new Date(start);
                d.setDate(start.getDate() + r * 7 + c);
                days.push({
                    day: d.getDate(),
                    otherMonth: d.getMonth() !== now.getMonth(),
                    today: d.toDateString() === now.toDateString()
                });
            }
            rows.push({
                week: isoWeek(new Date(start.getFullYear(), start.getMonth(), start.getDate() + r * 7)),
                days: days
            });
        }
        return rows;
    }

    Timer {
        // Midnight-ish granularity; cheap enough to poll hourly rather than
        // schedule an exact midnight timeout.
        interval: 60 * 60 * 1000
        running: true
        repeat: true
        onTriggered: {
            root.calRows = root.calGrid();
            root.calMonth = Qt.formatDate(new Date(), "MMMM yyyy");
        }
    }

    // ── Fan / cooling (msi-ec / legion-laptop) ────────────────────────────
    // Hardware-gated, not host-gated: `fanAvailable` is false wherever neither
    // backend is there — a GS65 whose EC firmware msi-ec declined to match,
    // or a Legion before hosts/legion/fan-control.nix's legion-laptop module
    // is loaded — and SystemView hides the card on that flag. No hostname
    // appears anywhere in this shell, so the same QML directory is correct on
    // both machines; see dashboard-fan.sh for which platform device backs it.
    //
    // Rides the same 3s tick as the stats above rather than owning a timer:
    // both are sysfs reads for the System tab, and one tick that spawns two
    // one-shots is the same cost as two ticks that spawn one each, minus a
    // timer.
    property bool fanAvailable: false
    property bool fanWritable: false
    property var fanModes: []
    property string fanMode: ""
    property bool coolerBoost: false

    Process {
        id: fanProc
        command: ["dashboard-fan", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                let j;
                try {
                    j = JSON.parse(text);
                } catch (e) {
                    return;
                }
                root.fanAvailable = j.available ?? false;
                root.fanWritable = j.writable ?? false;
                root.fanModes = j.modes ?? [];
                root.fanMode = j.mode ?? "";
                root.coolerBoost = j.boost ?? false;
            }
        }
    }

    function setFanMode(mode: string): void {
        oneShot.exec(["dashboard-fan", "mode", mode]);
        fanSettle.restart();
    }

    function toggleCoolerBoost(): void {
        oneShot.exec(["dashboard-fan", "boost", "toggle"]);
        fanSettle.restart();
    }

    // The EC takes a moment to reflect a write, and the card should not sit on
    // a stale value for most of a 3s tick after its own click.
    Timer {
        id: fanSettle
        interval: 400
        repeat: false
        onTriggered: fanProc.running = true
    }

    // ── Keyboard RGB (msi-perkeyrgb) ─────────────────────────────────────
    // Also hardware-gated — on the USB HID keyboard (1038:1122) this time.
    //
    // `kbdMode` is "off" | "steady" | "preset", and it comes out of a state
    // file rather than off the keyboard: the SteelSeries controller accepts
    // lighting packets and reports nothing back, so dashboard-kbd's record of
    // what it last sent is the only available answer. See that script.
    //
    // Polled once when the tab opens rather than on the tick: nothing else on
    // this machine writes the keyboard lighting, so the value can only change
    // when this card changes it — and those paths re-read directly.
    //
    // `kbdColor` is the BASE colour, not what is on the wire: the controller
    // has no brightness of its own, so dashboard-kbd dims by scaling the RGB
    // before sending. Keeping the two apart is what lets the swatch stay lit
    // on the colour that was picked while the keyboard shows a dimmed one.
    property bool kbdAvailable: false
    property bool kbdWritable: false
    property string kbdMode: ""
    property string kbdColor: ""
    property string kbdPreset: ""
    property int kbdBrightness: 100

    Process {
        id: kbdProc
        command: ["dashboard-kbd", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                let j;
                try {
                    j = JSON.parse(text);
                } catch (e) {
                    return;
                }
                root.kbdAvailable = j.available ?? false;
                root.kbdWritable = j.writable ?? false;
                root.kbdMode = j.mode ?? "";
                root.kbdColor = j.color ?? "";
                root.kbdPreset = j.preset ?? "";
                root.kbdBrightness = j.brightness ?? 100;
            }
        }
    }

    // QML stringifies an opaque color as "#rrggbb" and a translucent one as
    // "#aarrggbb"; msi-perkeyrgb wants six bare hex digits either way, and
    // dashboard-kbd rejects anything else rather than half-writing a colour.
    function setKbdColor(c: color): void {
        oneShot.exec(["dashboard-kbd", "color", String(c).slice(-6)]);
        kbdSettle.restart();
    }

    function setKbdPreset(name: string): void {
        oneShot.exec(["dashboard-kbd", "preset", name]);
        kbdSettle.restart();
    }

    function setKbdOff(): void {
        oneShot.exec(["dashboard-kbd", "off"]);
        kbdSettle.restart();
    }

    // Scales the base colour rather than touching a hardware register — see
    // dashboard-kbd. The card throttles the drag, because each call is a
    // Python process and a USB conversation.
    function setKbdBrightness(pct: int): void {
        oneShot.exec(["dashboard-kbd", "brightness", String(Math.max(0, Math.min(100, Math.round(pct))))]);
        kbdSettle.restart();
    }

    // Re-read rather than assume: msi-perkeyrgb exits non-zero if it cannot
    // open the HID device (the udev rule needs a reboot to take effect), and
    // dashboard-kbd only records state on success — so a failed click leaves
    // the card showing the truth instead of an optimistic lie.
    // Longer than the fan's: that one is a sysfs write that lands instantly,
    // this one is a USB HID conversation of several packets, and re-reading
    // before it finishes would show the previous colour.
    Timer {
        id: kbdSettle
        interval: 1200
        repeat: false
        onTriggered: kbdProc.running = true
    }

    // Shared fire-and-forget process for every command this panel issues.
    Process {
        id: oneShot
    }
}
