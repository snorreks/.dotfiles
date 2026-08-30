// nixos/config/home/dashboard/qml/Drawer.qml
//
// The merged panel: one window, one header, three views that switch in place.
//
// The header is the whole point of the merge — whichever entry point you used
// (SUPER+D, SUPER+I, the waybar bell), you land inside the same surface and
// the other two views are one click away. Previously they were two separate
// layer-shell surfaces bound to two different keys.
//
// A StackLayout, not a Loader: all three views stay instantiated, so scroll
// position and DND state survive tab switches, and switching costs nothing.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: drawer

    property bool active: false
    property string view: "home"

    readonly property var tabs: [
        {
            id: "home",
            icon: "󰋜",
            label: "Home"
        },
        {
            id: "system",
            icon: "󰄨",
            label: "System"
        },
        {
            id: "notifications",
            icon: "󰂚",
            label: "Alerts",
            badge: Notifs.count
        }
    ]

    function open(name: string): void {
        if (name && name.length > 0)
            drawer.view = name;
        drawer.active = true;
    }

    function close(): void {
        drawer.active = false;
    }

    screen: Quickshell.screens[0]
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    // Stay mapped through the close animation, then unmap — an unmapped layer
    // surface costs nothing, which is why this shell can afford to run always.
    visible: active || content.opacity > 0

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-dashboard"
    // OnDemand rather than Exclusive: the panel takes the keyboard only while
    // it is clicked/focused, which is what makes Escape reachable without
    // stealing every keystroke from the focused window behind it.
    WlrLayershell.keyboardFocus: active ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    anchors {
        top: true
        right: true
        bottom: true
    }
    margins {
        top: 10
        right: 10
        // waybar sits at the bottom (position "bottom", height 38 in
        // waybar/settings.nix) and this panel's exclusionMode is Ignore, so
        // without this the panel's own bottom edge would render straight over
        // the bar instead of stopping above it.
        bottom: 48
    }
    implicitWidth: 400

    Rectangle {
        id: content
        anchors.fill: parent
        radius: 14
        color: Theme.surface
        border.width: 1
        border.color: Theme.alpha(Theme.fg, 0.1)

        opacity: drawer.active ? 1 : 0
        x: drawer.active ? 0 : 24

        Behavior on opacity {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutCubic
            }
        }
        Behavior on x {
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutCubic
            }
        }

        focus: true
        Keys.onEscapePressed: drawer.close()

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 12

            // ── Header ───────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Segmented {
                    Layout.fillWidth: true
                    implicitHeight: 36
                    model: drawer.tabs
                    current: drawer.view
                    onActivated: id => drawer.view = id
                }

                // The one and only Clear All, and only where it applies.
                Rectangle {
                    Layout.preferredHeight: 36
                    Layout.preferredWidth: drawer.view === "notifications" && Notifs.count > 0 ? 36 : 0
                    opacity: Layout.preferredWidth > 0 ? 1 : 0
                    visible: opacity > 0
                    radius: 9
                    color: clearArea.containsMouse ? Theme.alpha(Theme.crit, 0.28) : Theme.alpha(Theme.bg, 0.55)

                    Behavior on Layout.preferredWidth {
                        NumberAnimation {
                            duration: 140
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on opacity {
                        NumberAnimation {
                            duration: 140
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "󰎟"
                        color: clearArea.containsMouse ? Theme.crit : Theme.subtle
                        font.pixelSize: 15
                    }
                    MouseArea {
                        id: clearArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Notifs.clearAll()
                    }
                }
            }

            // ── Views ────────────────────────────────────────────────────
            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: drawer.view === "system" ? 1 : drawer.view === "notifications" ? 2 : 0

                HomeView {}
                SystemView {}
                NotifView {}
            }
        }
    }
}
