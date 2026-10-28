pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "Logic.js" as Logic

Item {
    id: full

    property var usage: null
    property string errorText: ""
    property string notice: ""
    property bool busy: false
    property real now: 0

    signal refreshRequested()
    signal loginRequested(string name, string host)

    Layout.minimumWidth: Kirigami.Units.gridUnit * 24
    Layout.preferredWidth: Kirigami.Units.gridUnit * 26
    Layout.minimumHeight: Kirigami.Units.gridUnit * 8
    Layout.preferredHeight: Math.min(content.implicitHeight + Kirigami.Units.largeSpacing * 2,
                                     Kirigami.Units.gridUnit * 40)

    PlasmaComponents3.ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth

        ColumnLayout {
            id: content
            width: parent.width
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Heading {
                    text: "Claude accounts"
                    level: 3
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Label {
                    text: full.usage ? "updated " + Logic.age(full.usage.updated, full.now) : ""
                    opacity: 0.7
                    visible: text !== ""
                }
                PlasmaComponents3.BusyIndicator {
                    running: full.busy
                    visible: full.busy
                    Layout.preferredHeight: refresh.implicitHeight
                    Layout.preferredWidth: refresh.implicitHeight
                }
                PlasmaComponents3.Button {
                    id: refresh
                    icon.name: "view-refresh"
                    text: "Refresh"
                    enabled: !full.busy
                    onClicked: full.refreshRequested()
                }
            }

            PlasmaComponents3.Label {
                text: full.errorText
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.Wrap
                visible: text !== ""
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
            }

            PlasmaComponents3.Label {
                text: full.notice
                wrapMode: Text.Wrap
                visible: text !== ""
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
            }

            PlasmaComponents3.Label {
                text: "No accounts"
                opacity: 0.7
                visible: full.usage !== null && (full.usage.combined || []).length === 0
                Layout.margins: Kirigami.Units.smallSpacing
            }

            Repeater {
                model: full.usage ? full.usage.hosts || [] : []

                delegate: PlasmaComponents3.Label {
                    required property var modelData

                    text: modelData.error ? modelData.host + ": " + modelData.error : ""
                    color: Kirigami.Theme.negativeTextColor
                    wrapMode: Text.Wrap
                    visible: text !== ""
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                }
            }

            Repeater {
                model: full.usage ? full.usage.combined || [] : []

                delegate: ColumnLayout {
                    id: accountItem

                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Separator {
                        visible: accountItem.index > 0
                        Layout.fillWidth: true
                    }
                    AccountRow {
                        account: accountItem.modelData
                        now: full.now
                        Layout.fillWidth: true
                        onLoginRequested: (name, host) => full.loginRequested(name, host)
                    }
                }
            }
        }
    }
}
