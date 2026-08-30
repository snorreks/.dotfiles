// nixos/config/home/dashboard/qml/Toasts.qml
//
// The transient popup stack, top-right. Same NotifCard the drawer list uses —
// a toast is that card plus an expiry timer, not a separate widget.
//
// The window is only mapped while something is showing, and is anchored
// top+right with an implicit height so it is exactly as tall as its contents.
// A full-height transparent surface here would silently eat clicks across the
// whole right edge of the screen.
//
// Timeouts match what swaync was configured with (swaync.nix, now deleted):
// low 3s, normal 6s, critical never. An app's own expireTimeout wins when it
// sets one, which is the spec behaviour.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications

PanelWindow {
    id: toasts

    // Set while the drawer is already showing the notification list — no point
    // popping a card in front of the same card.
    property bool suppressed: false

    screen: Quickshell.screens[0]
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    visible: Notifs.popups.length > 0 && !suppressed

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-toasts"

    anchors {
        top: true
        right: true
    }
    margins {
        top: 10
        right: 10
    }
    implicitWidth: 380
    implicitHeight: Math.max(1, stack.implicitHeight)

    ColumnLayout {
        id: stack
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 8

        Repeater {
            model: Notifs.popups

            delegate: Item {
                id: slot
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: card.implicitHeight

                readonly property int timeout: {
                    if (slot.modelData.expireTimeout > 0)
                        return slot.modelData.expireTimeout;
                    switch (slot.modelData.urgency) {
                    case NotificationUrgency.Critical:
                        return 0; // never auto-expires
                    case NotificationUrgency.Low:
                        return 3000;
                    default:
                        return 6000;
                    }
                }

                Rectangle {
                    id: card
                    anchors.left: parent.left
                    anchors.right: parent.right
                    implicitHeight: inner.implicitHeight
                    radius: 12
                    color: Theme.surface
                    border.width: 1
                    border.color: Theme.alpha(Theme.fg, 0.1)

                    // Slide in from the right edge it came from.
                    opacity: 0
                    x: 20
                    Component.onCompleted: {
                        opacity = 1;
                        x = 0;
                    }
                    Behavior on opacity {
                        NumberAnimation {
                            duration: 160
                        }
                    }
                    Behavior on x {
                        NumberAnimation {
                            duration: 180
                            easing.type: Easing.OutCubic
                        }
                    }

                    NotifCard {
                        id: inner
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 4
                        notification: slot.modelData
                        color: "transparent"
                        border.width: 0
                        onDismissed: slot.modelData.dismiss()
                    }

                    HoverHandler {
                        id: cardHover
                    }

                    // Left-click runs the app's default action if it has one
                    // (that is the freedesktop convention for clicking the
                    // body); otherwise it just retires the popup and leaves the
                    // notification in the drawer. Middle-click always retires
                    // the popup without touching the notification.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        z: -1
                        onClicked: mouse => {
                            if (mouse.button === Qt.MiddleButton) {
                                Notifs.dropPopup(slot.modelData);
                                return;
                            }
                            const def = slot.modelData.actions.find(a => a.identifier === "default");
                            if (def)
                                def.invoke();
                            else
                                Notifs.dropPopup(slot.modelData);
                        }
                    }

                    // Hovering holds the toast open (and restarts its countdown
                    // on leave) — reading one should not be a race against it.
                    Timer {
                        interval: slot.timeout
                        running: slot.timeout > 0 && !cardHover.hovered
                        repeat: false
                        onTriggered: Notifs.dropPopup(slot.modelData)
                    }
                }
            }
        }
    }
}
