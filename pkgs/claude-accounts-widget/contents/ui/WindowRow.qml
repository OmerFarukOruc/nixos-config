import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "Logic.js" as Logic

// One usage window: label, bar, percent and reset time.
RowLayout {
    id: row

    property string title
    property var win: null
    property real now: 0
    property bool weekday: false
    // The window's length in seconds and the time of the reading, for the pace mark.
    property int length: 0
    property real checked: 0

    readonly property var used: Logic.usedOf(win)
    readonly property var pace: Logic.pace(win, length, checked || now)

    spacing: Kirigami.Units.smallSpacing

    PlasmaComponents3.Label {
        text: row.title
        opacity: 0.7
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.5
    }

    UsageBar {
        used: row.used
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
    }

    PlasmaComponents3.Label {
        text: row.used === null ? "-" : Math.round(row.used) + "%"
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.5
    }

    // ▲ uses the window faster than an even spread to the reset, ▽ has room to spare.
    PlasmaComponents3.Label {
        text: Logic.paceText(row.pace)
        color: row.pace === null || Math.abs(row.pace) <= 5 ? Kirigami.Theme.textColor
             : row.pace > 5 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.positiveTextColor
        opacity: row.pace === null || Math.abs(row.pace) <= 5 ? 0.7 : 1
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 3
    }

    PlasmaComponents3.Label {
        text: {
            if (!row.win || row.win.resets_at === null || row.win.resets_at === undefined)
                return "no data"
            if (row.win.resets_at <= row.now)
                return "resets now"
            return row.weekday ? Logic.weekdayTime(row.win.resets_at)
                               : "in " + Logic.duration(row.win.resets_at - row.now)
        }
        opacity: 0.7
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
    }
}
