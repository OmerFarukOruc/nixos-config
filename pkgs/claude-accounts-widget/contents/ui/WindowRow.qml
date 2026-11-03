import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "Logic.js" as Logic

RowLayout {
    id: row

    property string title
    property var win: null
    property bool weekday: false

    readonly property var used: Logic.usedOf(win)
    readonly property var paceTone: win ? win.pace_tone : null

    spacing: Kirigami.Units.smallSpacing

    PlasmaComponents3.Label {
        text: row.title
        opacity: 0.7
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.5
    }

    UsageBar {
        used: row.used
        tone: row.win ? row.win.tone : ""
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
    }

    PlasmaComponents3.Label {
        text: row.used === null ? "-" : Math.round(row.used) + "%"
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.5
    }

    PlasmaComponents3.Label {
        text: Logic.paceText(row.win)
        color: row.paceTone === "red" ? Kirigami.Theme.negativeTextColor
             : row.paceTone === "amber" ? Kirigami.Theme.neutralTextColor
             : row.paceTone === "green" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
        opacity: row.paceTone === "dim" ? 0.7 : 1
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 3
    }

    PlasmaComponents3.Label {
        text: Logic.resetText(row.win, row.weekday)
        opacity: 0.7
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
    }
}
