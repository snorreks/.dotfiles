// nixos/config/home/dashboard/qml/PillToggle.qml
//
// One on/off quick control. Unlike Segmented these ARE independent booleans
// (wifi, bluetooth, airplane, vpn, eye protection), so a pill per value is the
// honest shape — the fix was never "no toggles", it was "don't render a radio
// group as toggles".
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: pill

    property string icon: ""
    property string label: ""
    property bool active: false
    property bool busy: false
    property color accent: Theme.hi

    signal clicked

    Layout.fillWidth: true
    implicitHeight: 46
    radius: 10
    color: active ? Theme.alpha(accent, 0.22) : Theme.alpha(Theme.bg, 0.5)
    border.width: 1
    border.color: active ? Theme.alpha(accent, 0.5) : "transparent"

    Behavior on color {
        ColorAnimation {
            duration: 150
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 2

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: pill.icon
            color: pill.active ? pill.accent : Theme.subtle
            font.pixelSize: 16
            opacity: pill.busy ? 0.45 : 1

            SequentialAnimation on opacity {
                running: pill.busy
                loops: Animation.Infinite
                NumberAnimation {
                    to: 1
                    duration: 500
                }
                NumberAnimation {
                    to: 0.35
                    duration: 500
                }
            }
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            visible: pill.label !== ""
            text: pill.label
            color: pill.active ? pill.accent : Theme.subtle
            font.pixelSize: 9
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: pill.clicked()
    }
}
