import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid


// Panel view: one bar for the local account with the most room left, and a red
// dot when any account needs a login. Without data it shows the plasmoid icon.
Item {
    id: compact

    property var best: null
    property bool attention: false

    signal clicked()

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical

    Layout.minimumWidth: vertical ? 0 : Kirigami.Units.gridUnit * 3
    Layout.preferredWidth: Layout.minimumWidth
    Layout.minimumHeight: vertical ? Kirigami.Units.gridUnit : 0

    Kirigami.Icon {
        anchors.centerIn: parent
        width: Math.min(parent.width, parent.height, Kirigami.Units.iconSizes.medium)
        height: width
        source: Plasmoid.icon
        active: area.containsMouse
        visible: compact.best === null
    }

    UsageBar {
        id: bar
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Kirigami.Units.smallSpacing
        implicitHeight: Kirigami.Units.smallSpacing * 2
        used: compact.best ? compact.best.used : null
        visible: compact.best !== null
    }

    Rectangle {
        visible: compact.attention
        width: Kirigami.Units.smallSpacing * 2
        height: width
        radius: width / 2
        color: Kirigami.Theme.negativeTextColor
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Kirigami.Units.smallSpacing
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        onClicked: compact.clicked()
    }
}
