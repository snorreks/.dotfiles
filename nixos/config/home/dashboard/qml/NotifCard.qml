// nixos/config/home/dashboard/qml/NotifCard.qml
//
// One notification. The same delegate serves the drawer list and the toast
// stack — a toast is not a different object, it is this card with a timer.
//
// Exactly one destructive control: the per-item ✕, which dismisses THIS
// notification. Clearing everything lives in the drawer header and nowhere
// else. swaync had both a header Clear All and a per-group ✕ that silently
// cleared the whole group, which is the ambiguity this replaces.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications

Rectangle {
    id: nc

    required property Notification notification
    property bool showActions: true

    signal dismissed

    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + 20
    radius: 10
    color: hover.hovered ? Theme.alpha(Theme.bg, 0.75) : Theme.alpha(Theme.bg, 0.5)
    border.width: nc.notification.urgency === NotificationUrgency.Critical ? 1 : 0
    border.color: Theme.crit

    Behavior on color {
        ColorAnimation {
            duration: 120
        }
    }

    HoverHandler {
        id: hover
    }

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 10
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            // Notification image (album art, avatars) wins over the app icon;
            // most apps set only one of the two.
            Item {
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
                Layout.alignment: Qt.AlignTop
                visible: img.visible || appIcon.visible

                ClippingRectangle {
                    anchors.fill: parent
                    radius: 8
                    color: "transparent"

                    Image {
                        id: img
                        anchors.fill: parent
                        visible: (nc.notification.image ?? "") !== ""
                        source: nc.notification.image ?? ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                }

                IconImage {
                    id: appIcon
                    anchors.fill: parent
                    visible: !img.visible && source != ""
                    source: Quickshell.iconPath(nc.notification.appIcon ?? "", true)
                    asynchronous: true
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                        Layout.fillWidth: true
                        text: nc.notification.summary
                        color: Theme.txt
                        font.pixelSize: 12
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        text: Notifs.ago(nc.notification)
                        color: Theme.muted
                        font.pixelSize: 10
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: nc.notification.body
                    textFormat: Text.RichText
                    wrapMode: Text.Wrap
                    maximumLineCount: 6
                    elide: Text.ElideRight
                    color: Theme.subtle
                    font.pixelSize: 11
                    onLinkActivated: link => Qt.openUrlExternally(link)
                }
            }

            // Dismiss stays visible on critical notifications even unhovered —
            // those never time out, so there must always be a way out.
            Rectangle {
                Layout.preferredWidth: 20
                Layout.preferredHeight: 20
                Layout.alignment: Qt.AlignTop
                radius: 6
                opacity: hover.hovered || nc.notification.urgency === NotificationUrgency.Critical ? 1 : 0
                color: closeArea.containsMouse ? Theme.alpha(Theme.crit, 0.3) : "transparent"

                Behavior on opacity {
                    NumberAnimation {
                        duration: 120
                    }
                }

                Text {
                    anchors.centerIn: parent
                    text: "󰅖"
                    color: closeArea.containsMouse ? Theme.crit : Theme.muted
                    font.pixelSize: 11
                }
                MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: nc.dismissed()
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            visible: nc.showActions && nc.notification.actions.length > 0
            spacing: 6

            Repeater {
                model: nc.notification.actions

                delegate: Rectangle {
                    id: act
                    required property var modelData

                    implicitWidth: actText.implicitWidth + 20
                    implicitHeight: 24
                    radius: 7
                    color: actArea.containsMouse ? Theme.alpha(Theme.hi, 0.28) : Theme.alpha(Theme.overlay, 0.9)

                    Text {
                        id: actText
                        anchors.centerIn: parent
                        text: act.modelData.text
                        color: Theme.txt
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: actArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: act.modelData.invoke()
                    }
                }
            }
        }
    }
}
