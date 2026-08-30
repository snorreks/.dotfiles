// nixos/config/home/dashboard/qml/NotifView.qml
//
// The notification list, grouped by app, newest first.
//
// Note what is NOT here: a Clear All button. There is exactly one, in the
// drawer header, and exactly one per-item dismiss on each card. swaync offered
// a header Clear All plus a per-group ✕ that looked like a close button and
// actually cleared the whole group — two controls for one idea, one of them
// mislabelled.
import QtQuick
import QtQuick.Layouts

Flickable {
    id: view

    contentWidth: width
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    ColumnLayout {
        id: col
        width: view.width
        spacing: 10

        // ── Do Not Disturb ───────────────────────────────────────────────
        Card {
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: Notifs.dnd ? "󰂛" : "󰂚"
                    color: Notifs.dnd ? Theme.magenta : Theme.subtle
                    font.pixelSize: 16
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1

                    Text {
                        text: "Do Not Disturb"
                        color: Theme.txt
                        font.pixelSize: 13
                    }
                    Text {
                        text: Notifs.dnd ? "Popups suppressed · still collected here" : "Popups shown"
                        color: Theme.muted
                        font.pixelSize: 10
                    }
                }

                // Switch
                Rectangle {
                    Layout.preferredWidth: 42
                    Layout.preferredHeight: 22
                    radius: 11
                    color: Notifs.dnd ? Theme.alpha(Theme.magenta, 0.55) : Theme.alpha(Theme.bg, 0.7)

                    Behavior on color {
                        ColorAnimation {
                            duration: 150
                        }
                    }

                    Rectangle {
                        x: Notifs.dnd ? parent.width - width - 3 : 3
                        y: 3
                        width: 16
                        height: 16
                        radius: 8
                        color: Notifs.dnd ? Theme.txt : Theme.subtle

                        Behavior on x {
                            NumberAnimation {
                                duration: 150
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Notifs.toggleDnd()
                    }
                }
            }
        }

        // ── Empty state ──────────────────────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 160
            visible: Notifs.count === 0

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 6

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "󰂜"
                    color: Theme.muted
                    font.pixelSize: 40
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "All caught up"
                    color: Theme.muted
                    font.pixelSize: 12
                }
            }
        }

        // ── Groups ───────────────────────────────────────────────────────
        Repeater {
            model: Notifs.groups

            delegate: Card {
                id: group
                required property var modelData

                gap: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        text: group.modelData.app
                        color: Theme.hi
                        font.pixelSize: 12
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        text: group.modelData.items.length
                        color: Theme.muted
                        font.pixelSize: 11
                    }
                }

                Repeater {
                    model: group.modelData.items

                    delegate: NotifCard {
                        required property var modelData
                        notification: modelData
                        onDismissed: Notifs.dismiss(modelData)
                    }
                }
            }
        }
    }
}
