// nixos/config/home/dashboard/qml/Meter.qml
//
// A labelled value with a real progress bar. SystemView is built entirely out
// of these so CPU, memory, swap, disk, temperature and battery all read on the
// same scale and grade to the same colors (Theme.grade).
import QtQuick
import QtQuick.Layouts

Item {
    id: meter

    property string icon: ""
    property string label: ""
    property string value: ""
    property real frac: 0                       // 0..1
    property color accent: Theme.grade(frac)

    Layout.fillWidth: true
    implicitHeight: 36

    ColumnLayout {
        anchors.fill: parent
        spacing: 5

        RowLayout {
            Layout.fillWidth: true
            spacing: 7

            Text {
                text: meter.icon
                color: meter.accent
                font.pixelSize: 13
            }
            Text {
                Layout.fillWidth: true
                text: meter.label
                color: Theme.txt
                font.pixelSize: 12
                elide: Text.ElideRight
            }
            Text {
                text: meter.value
                color: Theme.subtle
                font.pixelSize: 12
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 4
            radius: 2
            color: Theme.alpha(Theme.bg, 0.55)

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, meter.frac))
                height: parent.height
                radius: parent.radius
                color: meter.accent
                Behavior on width {
                    NumberAnimation {
                        duration: 220
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }
}
