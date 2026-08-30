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
