// nixos/config/home/dashboard/qml/Segmented.qml
//
// An exclusive N-way selector: one track, one sliding indicator, exactly one
// active segment — the shape a mutually exclusive value actually has.
//
// This exists because power mode used to be three independent `type = "toggle"`
// buttons in swaync's buttons-grid (swaync.nix, now deleted). A checkbox grid
// has no radio semantics, so it rendered three switches for one value and two
// of them were always showing the wrong state.
import QtQuick
import QtQuick.Layouts

Item {
    id: seg

    // [{ id: "balanced", icon: "󰌪", label: "Balanced" }, ...]
    property var model: []

    // `var`, not `string`: SystemView's ids are PowerProfile enum values, and a
    // string-typed property would coerce the int to "1" so the `===` below
    // could never match — nothing would ever look selected.
    property var current: null
    property color accent: Theme.hi
    property bool showLabels: true

    signal activated(string id)

    readonly property int index: {
        for (let i = 0; i < model.length; i++)
            if (model[i].id === current)
                return i;
        return -1;
    }
    readonly property real segWidth: model.length > 0 ? width / model.length : 0

    Layout.fillWidth: true
    implicitHeight: 34

    Rectangle {
        anchors.fill: parent
        radius: 9
        color: Theme.alpha(Theme.bg, 0.55)
    }

    // The indicator is a single moving rectangle rather than a per-segment
    // highlight — that is what makes the exclusivity legible while it animates.
    Rectangle {
        visible: seg.index >= 0
        x: seg.index * seg.segWidth + 2
        y: 2
        width: Math.max(0, seg.segWidth - 4)
        height: parent.height - 4
        radius: 7
        color: Theme.alpha(seg.accent, 0.28)
        border.width: 1
        border.color: Theme.alpha(seg.accent, 0.55)

        Behavior on x {
            NumberAnimation {
                duration: 180
                easing.type: Easing.OutCubic
            }
        }
    }

    Row {
        anchors.fill: parent

        Repeater {
            model: seg.model

            delegate: Item {
                id: cell
                required property var modelData
                readonly property bool active: modelData.id === seg.current

                width: seg.segWidth
                height: seg.height

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        text: cell.modelData.icon ?? ""
                        color: cell.active ? seg.accent : Theme.subtle
                        font.pixelSize: 14
                    }
                    Text {
                        visible: seg.showLabels && (cell.modelData.label ?? "") !== ""
                        text: cell.modelData.label ?? ""
                        color: cell.active ? seg.accent : Theme.subtle
                        font.pixelSize: 11
                        font.bold: cell.active
                    }

                    // Optional count badge — used by the drawer's tab bar so
                    // the unread total is readable without opening the tab.
                    Rectangle {
                        visible: (cell.modelData.badge ?? 0) > 0
                        implicitWidth: Math.max(16, badgeText.implicitWidth + 8)
                        implicitHeight: 16
                        radius: 8
                        color: seg.accent

                        Text {
                            id: badgeText
                            anchors.centerIn: parent
                            text: cell.modelData.badge ?? 0
                            color: Theme.bg
                            font.pixelSize: 9
                            font.bold: true
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.activated(cell.modelData.id)
                }
            }
        }
    }
}
