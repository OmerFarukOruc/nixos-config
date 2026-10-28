import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "Logic.js" as Logic

ColumnLayout {
    id: item

    property var account
    property real now: 0

    signal loginRequested(string name, string host)

    spacing: Kirigami.Units.smallSpacing

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents3.Label {
            text: item.account.name
            font.bold: true
        }
        PlasmaComponents3.Label {
            text: item.account.plan || ""
            opacity: 0.7
            visible: text !== ""
        }
        Item { Layout.fillWidth: true }
    }

    PlasmaComponents3.Label {
        text: [item.account.email, item.account.org].filter(function (s) { return !!s }).join(" - ")
        opacity: 0.7
        visible: text !== ""
        elide: Text.ElideRight
        Layout.fillWidth: true
    }

    WindowRow {
        title: "5 h"
        win: item.account.five_hour
        now: item.now
        length: 5 * 3600
        checked: item.account.checked || 0
        Layout.fillWidth: true
    }

    WindowRow {
        title: "7 d"
        win: item.account.seven_day
        now: item.now
        weekday: true
        length: 7 * 86400
        checked: item.account.checked || 0
        Layout.fillWidth: true
    }

    Repeater {
        model: item.account.scoped || []

        WindowRow {
            required property var modelData
            title: modelData.label
            win: modelData
            now: item.now
            weekday: true
            length: 7 * 86400
            checked: item.account.checked || 0
            Layout.fillWidth: true
        }
    }

    PlasmaComponents3.Label {
        text: item.account.source === "stale" ? "data is stale, read on " + item.account.read_on : ""
        opacity: 0.7
        visible: text !== ""
        Layout.fillWidth: true
    }

    Repeater {
        model: item.account.logins || []

        delegate: ColumnLayout {
            id: login

            required property var modelData

            Layout.fillWidth: true
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: login.modelData.host
                    opacity: 0.7
                }
                StateLabel {
                    acctState: login.modelData.state
                }
                PlasmaComponents3.Label {
                    text: Logic.loginEnds(login.modelData.login_expires_at, item.now)
                    opacity: 0.7
                    visible: text !== ""
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Button {
                    text: "Log in"
                    visible: Logic.needsLogin(login.modelData)
                    onClicked: item.loginRequested(item.account.name, login.modelData.local ? "" : login.modelData.host)
                }
            }

            PlasmaComponents3.Label {
                text: login.modelData.error || ""
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.Wrap
                visible: text !== ""
                Layout.fillWidth: true
            }
        }
    }
}
