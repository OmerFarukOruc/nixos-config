import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: bar

    property var used: null
    property string tone: ""

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
        color: bar.tone === "red" ? Kirigami.Theme.negativeTextColor
             : bar.tone === "amber" ? Kirigami.Theme.neutralTextColor
             : Kirigami.Theme.positiveTextColor
    }
}
