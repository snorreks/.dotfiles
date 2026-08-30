// nixos/config/home/dashboard/qml/Scrim.qml
//
// Fullscreen transparent click-catcher behind the drawer, so clicking away
// closes it — the behaviour a drawer is expected to have, and the reason the
// panel needs no close button of its own.
//
// Layer Top, not Overlay: the drawer sits on Overlay, so this can never end up
// in front of it. Only mapped while the drawer is open, so it never eats a
// click at any other time.
import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: scrim

    signal clicked

    screen: Quickshell.screens[0]
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-dashboard-scrim"

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: scrim.clicked()
    }
}
