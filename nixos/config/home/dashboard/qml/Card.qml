// nixos/config/home/dashboard/qml/Card.qml
//
// The one container primitive. Every tile in every view is a Card, so the
// radius/padding/elevation vocabulary is defined once instead of being
// re-typed (and drifting) at each of the ~15 call sites the old shell.qml had.
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: card

    default property alias content: body.data
    property string title: ""
    property int pad: 12
    property int gap: 6

    // Set alongside `Layout.fillHeight` when the card should absorb the
    // leftover height of its column: it anchors the content to the bottom too,
    // so a child with `Layout.fillHeight` inside actually gets the space.
    property bool fill: false

    Layout.fillWidth: true
    implicitHeight: outer.implicitHeight + pad * 2
    radius: 12
    color: Theme.overlay

    ColumnLayout {
        id: outer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: card.fill ? parent.bottom : undefined
        anchors.margins: card.pad
        spacing: card.gap

        Text {
            visible: card.title !== ""
            Layout.fillWidth: true
            text: card.title
            color: Theme.hi
            font.pixelSize: 13
            font.bold: true
        }

        ColumnLayout {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: card.fill
            spacing: card.gap
        }
    }
}
