// nixos/config/home/dashboard/qml/DragSlider.qml
//
// Click-anywhere-to-seek, drag and scroll-wheel slider.
//
// `shown` deliberately shadows `value` while dragging: volume and brightness
// both have an external source of truth that keeps pushing updates, and
// binding the knob straight to it makes the handle fight the finger on every
// round trip. The external value takes over again the moment the drag ends.
//
// `throttleMs` exists for brightness: change_brightness spawns a process and
// debounces a ddcutil fan-out, so firing it per mouse-move pixel would be
// dozens of spawns per drag. Volume leaves it at 0 — that write is a direct
// Pipewire property set with no process at all.
import QtQuick
import QtQuick.Layouts

Item {
    id: slider

    property string icon: ""
    property real value: 0                       // 0..1, external truth
    property color accent: Theme.hi
    property int throttleMs: 0
    property bool dragging: false
    property real pending: 0

    readonly property real shown: dragging ? pending : Math.max(0, Math.min(1, value))

    signal moved(real v)

    Layout.fillWidth: true
    implicitHeight: 34

    function seek(mouseX: real): void {
        pending = Math.max(0, Math.min(1, (mouseX - track.x) / track.width));
        if (throttleMs > 0) {
            if (!throttle.running)
                throttle.start();
        } else {
            slider.moved(pending);
        }
    }

    Timer {
        id: throttle
        interval: slider.throttleMs
        repeat: false
        onTriggered: slider.moved(slider.pending)
    }

    RowLayout {
        anchors.fill: parent
        spacing: 10

        Text {
            text: slider.icon
            color: slider.accent
            font.pixelSize: 15
            Layout.preferredWidth: 20
            horizontalAlignment: Text.AlignHCenter
        }

        Item {
            id: track
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            implicitHeight: 6

            Rectangle {
                anchors.fill: parent
                radius: 3
                color: Theme.alpha(Theme.bg, 0.6)
            }
            Rectangle {
                width: parent.width * slider.shown
                height: parent.height
                radius: 3
                color: slider.accent
            }
            Rectangle {
                x: parent.width * slider.shown - width / 2
                y: (parent.height - height) / 2
                width: 14
                height: 14
                radius: 7
                color: slider.accent
                border.width: 2
                border.color: Theme.surface
                scale: slider.dragging ? 1.15 : 1
                Behavior on scale {
                    NumberAnimation {
                        duration: 120
                    }
                }
            }
        }

        Text {
            text: Math.round(slider.shown * 100) + "%"
            color: Theme.subtle
            font.pixelSize: 11
            Layout.preferredWidth: 34
            horizontalAlignment: Text.AlignRight
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor

        onPressed: mouse => {
            slider.pending = slider.value;
            slider.dragging = true;
            slider.seek(mouse.x);
        }
        onPositionChanged: mouse => {
            if (slider.dragging)
                slider.seek(mouse.x);
        }
        onReleased: {
            // Always emit the final position, even if the throttle timer was
            // mid-interval — otherwise a quick drag ends on a stale value.
            throttle.stop();
            slider.moved(slider.pending);
            slider.dragging = false;
        }

        WheelHandler {
            onWheel: event => {
                const step = event.angleDelta.y > 0 ? 0.05 : -0.05;
                slider.pending = Math.max(0, Math.min(1, slider.value + step));
                slider.moved(slider.pending);
            }
        }
    }
}
