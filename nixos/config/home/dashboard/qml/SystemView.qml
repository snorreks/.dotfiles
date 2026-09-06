// nixos/config/home/dashboard/qml/SystemView.qml
//
// The half that didn't exist before. Utilisation with real bars rather than
// three bare percentages in a row, plus battery detail and the power-mode
// selector — which is here, not on Home, because "how hard is this machine
// working" and "how hard should it work" are one question.
//
// Not a Flickable: the fixed cards are a known height, so the process list can
// take `Layout.fillHeight` and absorb everything left over, scrolling inside
// itself. Inside a Flickable's content column `fillHeight` is meaningless —
// the column's height is its own content — which is why the list used to stop
// after three rows with dead space under it.
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.UPower

Item {
    id: view

    readonly property var battery: UPower.displayDevice

    // UPower reports a battery percentage; normalise defensively so this reads
    // correctly whether the binding hands back 0..1 or 0..100.
    readonly property real batteryFrac: {
        const p = battery?.percentage ?? 0;
        return p > 1 ? p / 100 : p;
    }

    function gib(kb: int): string {
        return (kb / 1048576).toFixed(1) + " GiB";
    }

    function dur(s: int): string {
        if (s <= 0)
            return "";
        const d = Math.floor(s / 86400);
        const h = Math.floor((s % 86400) / 3600);
        const m = Math.floor((s % 3600) / 60);
        if (d > 0)
            return d + "d " + h + "h";
        if (h > 0)
            return h + "h " + m + "m";
        return m + "m";
    }

    // msi-ec's mode names, mapped to something glanceable. Falls back to the
    // fan glyph for any name a future firmware config might add.
    function fanIcon(mode: string): string {
        switch (mode) {
        case "silent":
            return "󰤄";
        case "advanced":
            return "󰈸";
        default:
            return "󰈐";
        }
    }

    // Keyboard swatches. Deliberately literal colours rather than Theme
    // tokens: this picks what the keyboard emits, and a swatch has to show
    // the colour it will actually produce — a "red" that follows the wallpaper
    // would be a swatch that lies. The card appends one extra, theme-derived
    // swatch after these, marked with a palette glyph so it reads as the
    // deliberate exception.
    readonly property var kbdSwatches: ["#ff0000", "#ff7700", "#ffdd00", "#00ff40", "#00e5ff", "#0055ff", "#aa00ff", "#ffffff"]

    function batteryState(): string {
        switch (view.battery?.state) {
        case UPowerDeviceState.Charging:
            return "Charging · " + view.dur(view.battery.timeToFull) + " to full";
        case UPowerDeviceState.Discharging:
            return view.dur(view.battery.timeToEmpty) + " remaining";
        case UPowerDeviceState.FullyCharged:
            return "Fully charged";
        case UPowerDeviceState.Empty:
            return "Empty";
        default:
            return "On AC power";
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        // ── Power mode ───────────────────────────────────────────────────
        Card {
            title: "Power mode"

            Segmented {
                // Segment ids are the PowerProfile enum values themselves, so
                // the selection is compared against exactly what the D-Bus
                // property holds — no string round-trip to get out of sync.
                model: [
                    {
                        id: PowerProfile.PowerSaver,
                        icon: "󰾆",
                        label: "Saver"
                    },
                    {
                        id: PowerProfile.Balanced,
                        icon: "󰌪",
                        label: "Balanced"
                    },
                    {
                        id: PowerProfile.Performance,
                        icon: "󰓅",
                        label: "Perf"
                    }
                ]
                current: Sys.powerProfile
                onActivated: id => Sys.setPower(id)
            }
        }

        // ── Cooling ──────────────────────────────────────────────────────
        // Directly under Power mode on purpose: this is the second half of
        // the same question. Power mode asks the CPU how hard to work;
        // this asks the fans how hard to answer.
        //
        // Hidden entirely unless a fan backend is there: msi-ec on the GS65,
        // or the legion-laptop module on the Legion (see
        // hosts/legion/fan-control.nix — the in-tree mainline WMI driver binds
        // this Legion but refuses fan control on this model, so legion-laptop
        // replaces it for that one purpose). The Legion has no discrete fan
        // modes, so Sys.fanModes comes back empty there and the Segmented
        // control below renders nothing; only the boost pill does anything.
        // Nothing here tests a hostname; see Sys.qml.
        Card {
            title: "Cooling"
            visible: Sys.fanAvailable

            Segmented {
                // Built from the driver's own available_fan_modes rather than
                // a hardcoded triple: which modes exist depends on the
                // msi_ec_conf that matched this machine's EC firmware, and
                // this file has no business assuming which one that was.
                model: Sys.fanModes.map(m => ({
                            id: m,
                            icon: view.fanIcon(m),
                            label: m.charAt(0).toUpperCase() + m.slice(1)
                        }))
                current: Sys.fanMode
                onActivated: id => Sys.setFanMode(id)
            }

            // Cooler boost is not a fourth fan mode — it is an independent
            // override that pins both fans to maximum on top of whichever
            // mode is selected, so it is a pill, not a segment.
            PillToggle {
                icon: "󰜗"
                label: "Cooler boost"
                accent: Theme.warn
                active: Sys.coolerBoost
                onClicked: Sys.toggleCoolerBoost()
            }

            // The EC can hold a byte the driver has no name for — this machine
            // boots with 0x0c, one bit off the 0x0d it calls `auto`, presumably
            // whatever the firmware leaves behind. fan_mode then reads back
            // "unknown (12)", no segment matches it, and the selector renders
            // with nothing lit. That is honest rather than broken, but it looks
            // broken, so say what is going on. Picking any mode clears it.
            Text {
                Layout.fillWidth: true
                visible: Sys.fanMode.startsWith("unknown")
                text: "Fan is in a firmware state with no name (" + Sys.fanMode + ") — pick a mode to take over."
                color: Theme.subtle
                font.pixelSize: 10
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                visible: !Sys.fanWritable
                text: "Read-only until the fan-control udev rule applies — reboot."
                color: Theme.warn
                font.pixelSize: 10
                wrapMode: Text.Wrap
            }
        }

        // ── Utilisation ──────────────────────────────────────────────────
        Card {
            title: "Utilisation"
            gap: 10

            Meter {
                icon: "󰍛"
                label: "CPU"
                frac: Sys.cpuFrac
                value: Math.round(Sys.cpuFrac * 100) + "% · " + Sys.load.toFixed(2) + " load"
            }
            Meter {
                icon: "󰧑"
                label: "Memory"
                frac: Sys.memPct / 100
                value: view.gib(Sys.memUsedKb) + " / " + view.gib(Sys.memTotalKb)
            }
            Meter {
                icon: "󰓡"
                label: "Swap"
                visible: Sys.swapPct > 0
                frac: Sys.swapPct / 100
                value: Sys.swapPct + "%"
            }
            Meter {
                icon: "󰋊"
                label: "Disk /"
                frac: Sys.diskPct / 100
                value: view.gib(Sys.diskUsedKb) + " / " + view.gib(Sys.diskTotalKb)
            }
            Meter {
                icon: "󰔏"
                label: "Temperature"
                // Graded on the 40–95°C band a laptop actually lives in, not
                // on 0–100, so the bar moves where the interesting range is.
                frac: Math.max(0, Math.min(1, (Sys.tempC - 40) / 55))
                value: Sys.tempC + "°C"
            }

            Text {
                Layout.fillWidth: true
                Layout.topMargin: 2
                text: "Uptime " + view.dur(Sys.uptimeS) + " · " + Sys.cores + " cores"
                color: Theme.muted
                font.pixelSize: 10
            }
        }

        // ── Battery ──────────────────────────────────────────────────────
        Card {
            title: "Battery"
            visible: view.battery !== null && view.battery.isLaptopBattery

            Meter {
                icon: view.battery?.state === UPowerDeviceState.Charging ? "󰂄" : "󰁹"
                label: view.batteryState()
                frac: view.batteryFrac
                value: Math.round(view.batteryFrac * 100) + "%"
                // Inverted grading: on a battery, low is the bad end.
                accent: view.batteryFrac <= 0.15 ? Theme.crit : view.batteryFrac <= 0.3 ? Theme.warn : Theme.ok
            }

            Text {
                Layout.fillWidth: true
                visible: (view.battery?.healthSupported ?? false) && text !== ""
                text: "Health " + Math.round(view.battery?.healthPercentage ?? 0) + "% · " + (view.battery?.model ?? "")
                color: Theme.muted
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }

        // ── Keyboard light ───────────────────────────────────────────────
        // Hidden unless the SteelSeries HID controller is present, same rule
        // as Cooling: hardware, not hostname.
        //
        // Note there is no "current colour" coming back from the keyboard —
        // it is a write-only device (see dashboard-kbd). What is highlighted
        // below is what this panel last successfully set, which is the same
        // thing as long as nothing else writes the lighting, and nothing does.
        Card {
            title: "Keyboard light"
            visible: Sys.kbdAvailable

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Repeater {
                    model: view.kbdSwatches

                    delegate: Rectangle {
                        id: swatch
                        required property string modelData

                        readonly property bool active: Sys.kbdMode === "steady" && Sys.kbdColor === modelData.slice(1).toLowerCase()

                        Layout.fillWidth: true
                        implicitHeight: 26
                        radius: 7
                        color: swatch.modelData

                        // Ring rather than a check mark: at 26px a glyph on
                        // top of an arbitrary colour is unreadable half the
                        // time, and the ring reads against any of them.
                        border.width: swatch.active ? 2 : 0
                        border.color: Theme.txt

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Sys.setKbdColor(swatch.modelData)
                        }
                    }
                }

                // Whatever the wallpaper is currently themed to.
                Rectangle {
                    readonly property string hex: String(Theme.hi).slice(1).toLowerCase()

                    Layout.fillWidth: true
                    implicitHeight: 26
                    radius: 7
                    color: Theme.hi
                    border.width: Sys.kbdMode === "steady" && Sys.kbdColor === hex ? 2 : 0
                    border.color: Theme.txt

                    Text {
                        anchors.centerIn: parent
                        text: "󰸌"
                        color: Theme.bg
                        font.pixelSize: 13
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Sys.setKbdColor(Theme.hi)
                    }
                }
            }

            // Not a hardware brightness register — there isn't one. This
            // scales the base colour on its way to the keyboard, which is why
            // it only bites on a steady colour and goes inert (dimmed, not
            // hidden, so the card doesn't change height) under a preset.
            DragSlider {
                // Same glyph as the display-brightness slider on Home. It
                // means brightness in both places; the card title is what says
                // which light it is.
                icon: "󰃟"
                // Tinted with the colour it is dimming, which is the one place
                // in the panel where the accent is not a theme token: the
                // slider IS the colour's intensity.
                accent: Sys.kbdMode === "steady" && Sys.kbdColor !== "" ? "#" + Sys.kbdColor : Theme.hi
                value: Sys.kbdBrightness / 100
                enabled: Sys.kbdMode === "steady"
                opacity: enabled ? 1 : 0.35
                // Every move is a Python process opening a USB device — far
                // heavier than the backlight slider's 80ms, so throttle hard.
                throttleMs: 250
                onMoved: v => Sys.setKbdBrightness(v * 100)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                PillToggle {
                    icon: "󰌌"
                    label: "Off"
                    active: Sys.kbdMode === "off"
                    onClicked: Sys.setKbdOff()
                }
                // Two of msi-perkeyrgb's nine vendor presets. The rest are
                // reachable from `dashboard-kbd presets` / `dashboard-kbd
                // preset <name>`; putting all nine in here would make this
                // the largest card in the panel for the least-used control.
                PillToggle {
                    icon: "󰸉"
                    label: "Rainbow"
                    active: Sys.kbdPreset === "rainbow-split"
                    onClicked: Sys.setKbdPreset("rainbow-split")
                }
                PillToggle {
                    icon: "󰧵"
                    label: "Disco"
                    active: Sys.kbdPreset === "disco"
                    onClicked: Sys.setKbdPreset("disco")
                }
            }

            Text {
                Layout.fillWidth: true
                visible: !Sys.kbdWritable
                text: "No access to the keyboard's HID device — reboot for the udev rule to apply."
                color: Theme.warn
                font.pixelSize: 10
                wrapMode: Text.Wrap
            }
        }

        // ── Top processes ────────────────────────────────────────────────
        Card {
            title: "Top processes"
            fill: true
            Layout.fillHeight: true
            Layout.minimumHeight: 90

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item {
                    Layout.fillWidth: true
                }
                Text {
                    text: "CPU"
                    color: Theme.muted
                    font.pixelSize: 9
                    Layout.preferredWidth: 46
                    horizontalAlignment: Text.AlignRight
                }
                Text {
                    text: "MEM"
                    color: Theme.muted
                    font.pixelSize: 9
                    Layout.preferredWidth: 46
                    horizontalAlignment: Text.AlignRight
                }
            }

            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: Sys.topProcs
                spacing: 4

                delegate: Item {
                    id: procRow
                    required property var modelData

                    width: ListView.view.width
                    implicitHeight: 18

                    RowLayout {
                        anchors.fill: parent
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: procRow.modelData.name
                            color: Theme.txt
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Text {
                            text: procRow.modelData.cpu.toFixed(1) + "%"
                            color: Theme.grade(Math.min(1, procRow.modelData.cpu / 100))
                            font.pixelSize: 11
                            Layout.preferredWidth: 46
                            horizontalAlignment: Text.AlignRight
                        }
                        Text {
                            text: procRow.modelData.mem.toFixed(1) + "%"
                            color: Theme.muted
                            font.pixelSize: 11
                            Layout.preferredWidth: 46
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                }
            }
        }
    }
}
