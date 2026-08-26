// nixos/config/home/dashboard/shell.qml
//
// A single toggleable panel — weather / calendar / agenda / mpris / stats /
// power-mode — on ONE PanelWindow. Written from scratch (no caelestia/DMS
// code); see nixos/config/home/dashboard/default.nix for why: this avoids
// per-screen instantiation entirely (Quickshell.screens[0] only, never
// `Variants { model: Quickshell.screens }`) because that's the exact
// per-monitor cost this setup exists to avoid — 3 monitors on legion.
//
// Data flow, all deliberately one-shot-or-streaming-on-a-Timer, never a
// blocking call on the UI thread:
//   - theme     : FileView over ~/.cache/theme/dashboard.json, watched —
//                 matugen re-renders it, this panel picks the change up
//                 live with no signal/reload of its own needed.
//   - weather/
//     agenda    : the exact `waybar-weather --once` / `waybar-agenda --once`
//                 binaries waybar itself uses, re-run on a Timer. Their JSON
//                 is waybar-shaped (text/tooltip/class, tooltip in Pango
//                 markup) because that's the one contract they already have;
//                 Text.RichText renders the overlapping subset of tags fine.
//   - mpris     : Quickshell.Services.Mpris — no polling, it's a live D-Bus
//                 service binding.
//   - stats     : dashboard-stats.sh (nixos/config/home/scripts/scripts/),
//                 re-run on a Timer — CPU/mem/temp have no push source.
//   - power mode: `sys-daemon waybar power`, same long-lived stream the
//                 waybar pill reads (P1) — one process, one source of truth.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

ShellRoot {
    id: root

    // ── Theme ────────────────────────────────────────────────────────────
    // Fallback tokyo-night values so the panel never renders blank/undefined
    // colors before the first FileView load completes.
    property var theme: ({
        bg: "#1a1b26",
        surface: "#16161e",
        overlay: "#2f3549",
        muted: "#444b6a",
        subtle: "#787c99",
        fg: "#a9b1d6",
        red: "#c0caf5",
        orange: "#a9b1d6",
        yellow: "#0db9d7",
        green: "#9ece6a",
        cyan: "#b4f9f8",
        blue: "#2ac3de",
        magenta: "#bb9af7",
        txt: "#a9b1d6",
        hi: "#2ac3de",
        ok: "#9ece6a",
        warn: "#0db9d7",
        crit: "#c0caf5"
    })

    FileView {
        id: themeFile
        path: Quickshell.env("HOME") + "/.cache/theme/dashboard.json"
        watchChanges: true
        onLoaded: {
            try {
                root.theme = JSON.parse(text());
            } catch (e) {
                console.warn("dashboard: failed to parse theme json:", e);
            }
        }
        onFileChanged: reload()
    }

    // ── IPC: `qs -c dashboard ipc call dash toggle` ─────────────────────
    // Deliberately just `toggle` — `show`/`hide` collide with `ipc`'s own
    // subcommand names ("qs ipc show" lists targets) and its CLI parser
    // resolves that ambiguity by running the wrong thing: `ipc call dash
    // show` silently no-ops instead of calling this handler's function.
    // Confirmed live (0.3.0); `toggle` doesn't collide and works correctly.
    IpcHandler {
        target: "dash"

        function toggle(): void {
            panel.visible = !panel.visible;
        }
    }

    // ── Power mode: same event-driven stream the waybar pill reads ─────
    QtObject {
        id: power
        property string profile: ""
        property string text: ""
    }
    Process {
        id: powerProc
        command: ["sys-daemon", "waybar", "power"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                try {
                    const j = JSON.parse(line);
                    power.text = j.text ?? "";
                    // class is "power-<profile>" (power-performance, power-balanced,
                    // power-saver, power-unknown) — see sys-daemon power.rs render().
                    power.profile = (j.class ?? "power-unknown").replace("power-", "");
                } catch (e) {}
            }
        }
    }

    // ── Weather / agenda: re-run the exact waybar `--once` binaries ────
    QtObject {
        id: weather
        property string text: ""
        property string tooltip: ""
    }
    Process {
        id: weatherProc
        command: ["waybar-weather", "--once"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const j = JSON.parse(text);
                    weather.text = j.text ?? "";
                    weather.tooltip = j.tooltip ?? "";
                } catch (e) {}
            }
        }
    }
    Timer {
        interval: 15 * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: weatherProc.running = true
    }

    QtObject {
        id: agenda
        property string text: ""
        property string tooltip: ""
        // The event-listing slice of `tooltip`, with the embedded mini
        // calendar (this panel already has its own calendar tile) and the
        // "synced HH:MM · click → ..." footer stripped. agenda.py's emit()
        // joins [month_grid, "", agenda_lines, "", footer] with "\n" — so
        // splitting on the blank line always isolates agenda_lines exactly,
        // regardless of any blank lines *inside* it.
        property string eventsText: {
            const parts = tooltip.split("\n\n");
            return parts.length >= 3 ? parts.slice(1, -1).join("\n\n") : tooltip;
        }
    }
    Process {
        id: agendaProc
        command: ["waybar-agenda", "--once"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const j = JSON.parse(text);
                    agenda.text = j.text ?? "";
                    agenda.tooltip = j.tooltip ?? "";
                } catch (e) {}
            }
        }
    }
    Timer {
        interval: 15 * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: agendaProc.running = true
    }

    // ── CPU / mem / temp ─────────────────────────────────────────────────
    QtObject {
        id: stats
        property real load: 0
        property int cores: 1
        property int memPct: 0
        property int tempC: 0
    }
    Process {
        id: statsProc
        command: ["dashboard-stats"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const j = JSON.parse(text);
                    stats.load = j.load ?? 0;
                    stats.cores = j.cores ?? 1;
                    stats.memPct = j.mem_pct ?? 0;
                    stats.tempC = j.temp_c ?? 0;
                } catch (e) {}
            }
        }
    }
    Timer {
        interval: 3000
        running: panel.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: statsProc.running = true
    }

    // ── Calendar: native month grid, Monday-first, ISO week numbers ────
    // (Not sourced from waybar-agenda's tooltip — that has its own compact
    // grid meant for a GTK tooltip. This mirrors waybar's own `clock`
    // module calendar config: iso8601 week numbers, Monday-first rows.)
    QtObject {
        id: calendar

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
        function grid(): var {
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

        property var rows: grid()
        property string monthLabel: Qt.formatDate(new Date(), "MMMM yyyy")
    }
    Timer {
        // Recompute at local midnight-ish granularity; cheap enough to just
        // poll hourly rather than schedule an exact midnight timeout.
        interval: 60 * 60 * 1000
        running: true
        repeat: true
        onTriggered: {
            calendar.rows = calendar.grid();
            calendar.monthLabel = Qt.formatDate(new Date(), "MMMM yyyy");
        }
    }

    PanelWindow {
        id: panel
        screen: Quickshell.screens[0]
        visible: false
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        anchors {
            top: true
            right: true
            bottom: true
        }
        margins {
            top: 10
            right: 10
            bottom: 10
        }
        implicitWidth: 400

        Rectangle {
            anchors.fill: parent
            radius: 14
            color: root.theme.surface
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.08)

            Flickable {
                anchors.fill: parent
                anchors.margins: 14
                contentWidth: width
                contentHeight: tiles.implicitHeight
                clip: true

                ColumnLayout {
                    id: tiles
                    width: parent.width
                    spacing: 12

                    // ── Weather ──────────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: weatherCol.implicitHeight + 20
                        radius: 10
                        color: root.theme.overlay
                        Column {
                            id: weatherCol
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 4
                            Text {
                                text: weather.text.length > 0 ? weather.text : "Weather unavailable"
                                color: root.theme.txt
                                font.pixelSize: 16
                                font.bold: true
                            }
                            Text {
                                width: weatherCol.width
                                text: weather.tooltip
                                textFormat: Text.RichText
                                wrapMode: Text.Wrap
                                color: root.theme.txt
                                font.pixelSize: 11
                                opacity: 0.85
                            }
                        }
                    }

                    // ── Calendar ─────────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: calCol.implicitHeight + 20
                        radius: 10
                        color: root.theme.overlay
                        Column {
                            id: calCol
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 6
                            Text {
                                text: calendar.monthLabel
                                color: root.theme.hi
                                font.pixelSize: 14
                                font.bold: true
                            }
                            Column {
                                // A plain Column of Rows, not Grid: Grid treats each
                                // top-level child as exactly one cell, so nesting a
                                // multi-child Row delegate inside it (for the week-
                                // number + 7 days) doesn't align into its column
                                // model at all — it just pushes everything after it
                                // sideways. Each Row below lays out its own 8 cells
                                // independently, which is what's actually wanted.
                                spacing: 3
                                Row {
                                    spacing: 4
                                    Text {
                                        text: "wk"
                                        color: root.theme.subtle
                                        font.pixelSize: 10
                                        horizontalAlignment: Text.AlignRight
                                        width: 22
                                    }
                                    Repeater {
                                        model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                                        Text {
                                            text: modelData
                                            color: root.theme.subtle
                                            font.pixelSize: 10
                                            horizontalAlignment: Text.AlignHCenter
                                            width: 26
                                        }
                                    }
                                }
                                Repeater {
                                    model: calendar.rows
                                    delegate: Row {
                                        spacing: 4
                                        required property var modelData
                                        Text {
                                            text: modelData.week
                                            color: root.theme.subtle
                                            font.pixelSize: 10
                                            horizontalAlignment: Text.AlignRight
                                            width: 22
                                        }
                                        Repeater {
                                            model: modelData.days
                                            delegate: Text {
                                                required property var modelData
                                                text: modelData.day
                                                width: 26
                                                horizontalAlignment: Text.AlignHCenter
                                                font.pixelSize: 11
                                                font.bold: modelData.today
                                                color: modelData.today ? root.theme.hi : modelData.otherMonth ? root.theme.subtle : root.theme.txt
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Agenda ───────────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: agendaCol.implicitHeight + 20
                        radius: 10
                        color: root.theme.overlay
                        Column {
                            id: agendaCol
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 4
                            Text {
                                text: "Agenda"
                                color: root.theme.hi
                                font.pixelSize: 14
                                font.bold: true
                            }
                            Text {
                                width: agendaCol.width
                                text: agenda.eventsText.length > 0 ? agenda.eventsText : "Nothing upcoming"
                                textFormat: Text.RichText
                                wrapMode: Text.Wrap
                                color: root.theme.txt
                                font.pixelSize: 11
                            }
                        }
                    }

                    // ── MPRIS ────────────────────────────────────────────
                    Rectangle {
                        id: mprisTile
                        visible: Mpris.players.values.length > 0
                        Layout.fillWidth: true
                        Layout.preferredHeight: mprisCol.implicitHeight + 20
                        radius: 10
                        color: root.theme.overlay

                        property var player: Mpris.players.values.length > 0 ? Mpris.players.values[0] : null

                        RowLayout {
                            id: mprisCol
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 10

                            Image {
                                visible: mprisTile.player && mprisTile.player.trackArtUrl.length > 0
                                source: mprisTile.player ? mprisTile.player.trackArtUrl : ""
                                Layout.preferredWidth: 48
                                Layout.preferredHeight: 48
                                fillMode: Image.PreserveAspectCrop
                            }

                            Column {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    width: parent.width
                                    text: mprisTile.player ? mprisTile.player.trackTitle : ""
                                    color: root.theme.txt
                                    font.pixelSize: 13
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: mprisTile.player ? mprisTile.player.trackArtist : ""
                                    color: root.theme.subtle
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                text: mprisTile.player && mprisTile.player.isPlaying ? "󰏤" : "󰐊"
                                color: root.theme.hi
                                font.pixelSize: 18
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        if (mprisTile.player)
                                            mprisTile.player.togglePlaying();
                                    }
                                }
                            }
                        }
                    }

                    // ── CPU / mem / temp ─────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 60
                        radius: 10
                        color: root.theme.overlay
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 10
                            Text {
                                Layout.fillWidth: true
                                text: "󰍛 " + Math.round((stats.load / stats.cores) * 100) + "%"
                                color: root.theme.txt
                                font.pixelSize: 13
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "󰋊 " + stats.memPct + "%"
                                color: root.theme.txt
                                font.pixelSize: 13
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "󰔏 " + stats.tempC + "°"
                                color: stats.tempC >= 85 ? root.theme.crit : root.theme.txt
                                font.pixelSize: 13
                            }
                        }
                    }

                    // ── Power mode row ───────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 44
                        radius: 10
                        color: root.theme.overlay
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 8
                            Repeater {
                                model: [
                                    {
                                        id: "performance",
                                        icon: "󰓅"
                                    },
                                    {
                                        id: "balanced",
                                        icon: "󰖣"
                                    },
                                    {
                                        id: "power-saver",
                                        icon: "󰾆"
                                    }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: 8
                                    color: power.profile === modelData.id ? Qt.alpha(root.theme.hi, 0.35) : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.icon
                                        color: power.profile === modelData.id ? root.theme.hi : root.theme.subtle
                                        font.pixelSize: 16
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: powerSetProc.exec(["sys-daemon", "power", "set", modelData.id])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Process {
        id: powerSetProc
    }
}
