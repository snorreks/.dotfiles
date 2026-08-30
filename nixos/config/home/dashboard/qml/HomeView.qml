// nixos/config/home/dashboard/qml/HomeView.qml
//
// Glanceable + immediately actionable: what's the weather, what's on today,
// what's playing, and the handful of switches worth reaching for. Everything
// heavier (utilisation, battery detail, power mode) lives in SystemView so
// this stays scannable.
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris

Flickable {
    id: view

    contentWidth: width
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    readonly property MprisPlayer player: Mpris.players.values.length > 0 ? Mpris.players.values[0] : null

    ColumnLayout {
        id: col
        width: view.width
        spacing: 10

        // ── Weather ──────────────────────────────────────────────────────
        // Glance first: temperature, place, and one dim line of conditions.
        // The hourly and daily blocks are a wall of text for a tile you look
        // at for a second, so they stay folded until you ask — click anywhere
        // on the card. Sys.qml does the section splitting.
        Card {
            id: weatherCard
            property bool expanded: false

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: Sys.weatherText.length > 0 ? Sys.weatherText : "󰼯 —"
                    color: Theme.txt
                    font.pixelSize: 20
                    font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    text: Sys.weatherPlace.length > 0 ? Sys.weatherPlace : "Weather unavailable"
                    textFormat: Text.RichText
                    color: Theme.txt
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
                Text {
                    visible: Sys.weatherForecast !== ""
                    text: weatherCard.expanded ? "󰅃" : "󰅀"
                    color: chevron.containsMouse ? Theme.hi : Theme.muted
                    font.pixelSize: 14

                    MouseArea {
                        id: chevron
                        // Bigger than the glyph: a 14px chevron is not a target.
                        anchors.centerIn: parent
                        width: 28
                        height: 28
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: weatherCard.expanded = !weatherCard.expanded
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: Sys.weatherFacts !== ""
                text: Sys.weatherFacts
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                color: Theme.subtle
                font.pixelSize: 11
            }

            Text {
                Layout.fillWidth: true
                visible: weatherCard.expanded && Sys.weatherForecast !== ""
                text: Sys.weatherForecast
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                color: Theme.subtle
                font.pixelSize: 11
                lineHeight: 1.3
            }
        }

        // ── Calendar ─────────────────────────────────────────────────────
        Card {
            title: Sys.calMonth

            Column {
                Layout.fillWidth: true
                // A plain Column of Rows, not a Grid: Grid treats each
                // top-level child as exactly one cell, so nesting a
                // multi-child Row delegate (week number + 7 days) inside it
                // doesn't align into its column model at all — it just pushes
                // everything after it sideways. Each Row lays out its own 8
                // cells independently, which is what's actually wanted.
                spacing: 3

                Row {
                    spacing: 4
                    Text {
                        text: "wk"
                        color: Theme.muted
                        font.pixelSize: 10
                        horizontalAlignment: Text.AlignRight
                        width: 22
                    }
                    Repeater {
                        model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                        delegate: Text {
                            required property string modelData
                            text: modelData
                            color: Theme.muted
                            font.pixelSize: 10
                            horizontalAlignment: Text.AlignHCenter
                            width: 26
                        }
                    }
                }

                Repeater {
                    model: Sys.calRows
                    delegate: Row {
                        id: weekRow
                        required property var modelData
                        spacing: 4

                        Text {
                            text: weekRow.modelData.week
                            color: Theme.muted
                            font.pixelSize: 10
                            horizontalAlignment: Text.AlignRight
                            width: 22
                        }
                        Repeater {
                            model: weekRow.modelData.days
                            delegate: Item {
                                id: dayCell
                                required property var modelData
                                width: 26
                                height: 18

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 22
                                    height: 18
                                    radius: 6
                                    visible: dayCell.modelData.today
                                    color: Theme.alpha(Theme.hi, 0.25)
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: dayCell.modelData.day
                                    font.pixelSize: 11
                                    font.bold: dayCell.modelData.today
                                    color: dayCell.modelData.today ? Theme.hi : dayCell.modelData.otherMonth ? Theme.muted : Theme.txt
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── Agenda ───────────────────────────────────────────────────────
        Card {
            title: "Agenda"

            Text {
                Layout.fillWidth: true
                text: Sys.agendaEvents.length > 0 ? Sys.agendaEvents : "Nothing upcoming"
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                color: Theme.txt
                font.pixelSize: 11
                lineHeight: 1.3
            }
        }

        // ── Media ────────────────────────────────────────────────────────
        Card {
            visible: view.player !== null

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                Image {
                    visible: (view.player?.trackArtUrl ?? "") !== ""
                    source: view.player?.trackArtUrl ?? ""
                    Layout.preferredWidth: 52
                    Layout.preferredHeight: 52
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        Layout.fillWidth: true
                        text: view.player?.trackTitle ?? ""
                        color: Theme.txt
                        font.pixelSize: 13
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: view.player?.trackArtist ?? ""
                        color: Theme.subtle
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }

                RowLayout {
                    spacing: 10

                    Repeater {
                        model: [
                            {
                                icon: "󰒮",
                                act: "prev"
                            },
                            {
                                icon: "play",
                                act: "play"
                            },
                            {
                                icon: "󰒭",
                                act: "next"
                            }
                        ]
                        delegate: Text {
                            id: ctrl
                            required property var modelData
                            text: modelData.act === "play" ? (view.player?.isPlaying ? "󰏤" : "󰐊") : modelData.icon
                            color: Theme.hi
                            font.pixelSize: modelData.act === "play" ? 20 : 15

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (!view.player)
                                        return;
                                    if (ctrl.modelData.act === "play")
                                        view.player.togglePlaying();
                                    else if (ctrl.modelData.act === "next")
                                        view.player.next();
                                    else
                                        view.player.previous();
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── Quick toggles ────────────────────────────────────────────────
        Card {
            GridLayout {
                Layout.fillWidth: true
                columns: 3
                columnSpacing: 8
                rowSpacing: 8

                PillToggle {
                    icon: Sys.wifiOn ? "󰖩" : "󰖪"
                    label: "Wi-Fi"
                    active: Sys.wifiOn
                    onClicked: Sys.runToggle("wifi_toggle")
                }
                PillToggle {
                    icon: "󰂯"
                    label: "Bluetooth"
                    active: Sys.btOn
                    onClicked: Sys.runToggle("bluetooth_toggle")
                }
                PillToggle {
                    icon: "󰀝"
                    label: "Airplane"
                    active: Sys.airplaneOn
                    accent: Theme.warn
                    onClicked: Sys.runToggle("airplane_mode_toggle")
                }
                PillToggle {
                    icon: "󰌾"
                    label: "VPN"
                    active: Sys.vpnOn
                    busy: Sys.vpnBusy
                    accent: Theme.ok
                    onClicked: Sys.runToggle("toggle_vpn")
                }
                PillToggle {
                    icon: "󱩌"
                    label: Sys.eyeClass === "eye-forced" ? "Night 3500K" : "Night light"
                    active: Sys.eyeOn
                    accent: Theme.orange
                    onClicked: Sys.runToggle("toggle_eye_protection")
                }
                PillToggle {
                    icon: Notifs.dnd ? "󰂛" : "󰂚"
                    label: "Do Not Disturb"
                    active: Notifs.dnd
                    accent: Theme.magenta
                    onClicked: Notifs.toggleDnd()
                }
            }
        }

        // ── Volume + brightness ──────────────────────────────────────────
        Card {
            gap: 10

            DragSlider {
                icon: Sys.muted ? "󰝟" : "󰕾"
                value: Sys.volume
                accent: Sys.muted ? Theme.muted : Theme.hi
                // Direct Pipewire property write — no process, so no throttle.
                onMoved: v => Sys.setVolume(v)

                MouseArea {
                    // Middle-click the icon area to mute, matching waybar's
                    // pulseaudio module binding.
                    width: 20
                    height: parent.height
                    acceptedButtons: Qt.MiddleButton
                    onClicked: Sys.toggleMute()
                }
            }

            DragSlider {
                icon: "󰃟"
                value: Sys.brightness / 100
                accent: Theme.yellow
                // change_brightness spawns a process and debounces a ddcutil
                // fan-out to the external displays — throttle the drag.
                throttleMs: 80
                onMoved: v => Sys.setBrightness(v * 100)
            }
        }
    }
}
