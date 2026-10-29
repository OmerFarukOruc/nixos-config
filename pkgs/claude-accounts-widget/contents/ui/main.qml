pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support

import "Logic.js" as Logic

PlasmoidItem {
    id: root

    property var usage: null
    property string errorText: ""
    property string notice: ""
    property bool busy: false
    property real now: Date.now() / 1000

    readonly property var best: Logic.bestAccount(usage)

    toolTipMainText: "Claude accounts"
    toolTipSubText: {
        if (errorText !== "")
            return errorText
        if (!usage)
            return "No data"
        if (best)
            return best.account.name + ": " + Math.round(100 - best.used) + "% left"
        return "No account with room data"
    }

    compactRepresentation: CompactRepresentation {
        best: root.best
        attention: Logic.anyNeedsLogin(root.usage)
        onClicked: root.expanded = !root.expanded
    }

    fullRepresentation: FullRepresentation {
        usage: root.usage
        errorText: root.errorText
        notice: root.notice
        busy: root.busy
        now: root.now
        onRefreshRequested: root.refresh()
        onLoginRequested: (name, host) => root.login(name, host)
    }

    function refresh() {
        if (busy)
            return
        busy = true
        executable.connectSource(Logic.refreshCommand)
    }

    function login(name, host) {
        var cmd = Logic.loginCommand(name, host)
        if (cmd === null) {
            notice = "Refused to log in: unexpected account or host name"
            return
        }
        notice = ""
        executable.connectSource(cmd)
    }

    function apply(result) {
        now = Date.now() / 1000
        if (result["exit code"] !== 0 && String(result.stdout).trim() === "") {
            usage = null
            var lines = String(result.stderr).trim().split("\n")
            errorText = lines[lines.length - 1] || "claude-tools usage exited with code " + result["exit code"]
            return
        }
        try {
            usage = Logic.parse(result.stdout)
            errorText = ""
        } catch (e) {
            usage = null
            errorText = "claude-tools usage printed unusable data: " + e.message
        }
    }

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, result) => {
            disconnectSource(sourceName)
            if (sourceName === Logic.pollCommand) {
                root.apply(result)
            } else if (sourceName === Logic.refreshCommand) {
                root.busy = false
                root.apply(result)
            } else if (result["exit code"] !== 0) {
                var lines = String(result.stderr).trim().split("\n")
                root.notice = "Log in failed: " + (lines[lines.length - 1] || "exit code " + result["exit code"])
            }
        }
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: executable.connectSource(Logic.pollCommand)
    }
}
