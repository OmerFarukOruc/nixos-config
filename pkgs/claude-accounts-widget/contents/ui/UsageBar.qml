import QtQuick
import org.kde.kirigami as Kirigami

// A rounded bar for a percentage. A null value draws only the track.
Item {
    id: bar

    property var used: null

    readonly property bool known: used !== null && used !== undefined
    readonly property real clamped: known ? Math.max(0, Math.min(100, Number(used))) : 0

    implicitHeight: Kirigami.Units.smallSpacing * 2
    implicitWidth: Kirigami.Units.gridUnit * 6

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.alpha(Kirigami.Theme.textColor, 0.15)
    }

    Rectangle {
        visible: bar.known
        width: Math.max(parent.height, parent.width * bar.clamped / 100)
        height: parent.height
        radius: height / 2
        color: bar.clamped >= 90 ? Kirigami.Theme.negativeTextColor
             : bar.clamped >= 70 ? Kirigami.Theme.neutralTextColor
             : Kirigami.Theme.positiveTextColor
    }
}
