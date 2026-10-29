.pragma library

var namePattern = /^[a-z0-9][a-z0-9.-]*$/
var usageCommand = "@claudeTools@/bin/claude-tools usage"
var accountsCommand = "@claudeTools@/bin/claude-tools accounts"

var pollCommand = "sh -c '" + usageCommand + " --json --cached'"
var refreshCommand = "sh -c '" + usageCommand + " --json --max-age 60'"

// Returns null for a name or host that the shell could read as more than a word.
function loginCommand(name, host) {
    if (!namePattern.test(name || ""))
        return null
    if (host && !namePattern.test(host))
        return null
    return "sh -c '" + accountsCommand + " login-window " + name + (host ? " --on " + host : "") + "'"
}

function parse(stdout) {
    var d = JSON.parse(stdout)
    if (d.version !== 1)
        throw new Error("unsupported data version " + d.version)
    return d
}

function usedOf(w) {
    return (w && w.used !== null && w.used !== undefined) ? Number(w.used) : null
}

function maxUsed(a) {
    var f = usedOf(a.five_hour), s = usedOf(a.seven_day)
    if (f === null && s === null)
        return null
    return Math.max(f === null ? 0 : f, s === null ? 0 : s)
}

function listedNames(data) {
    var names = {}, list = (data && data.combined) || []
    for (var i = 0; i < list.length; i++)
        names[list[i].name] = true
    return names
}

// The account claude-tools rotate would start on: the first of claude-tools usage's order that nothing blocks.
function bestAccount(data) {
    var listed = listedNames(data)
    var order = (data && data.order) || []
    var list = (data && data.accounts) || []
    for (var i = 0; i < order.length; i++) {
        if (order[i].group === "blocked" || !listed[order[i].name])
            continue
        for (var j = 0; j < list.length; j++) {
            var u = list[j].name === order[i].name ? maxUsed(list[j]) : null
            if (u !== null)
                return { account: list[j], used: u }
        }
    }
    return null
}

function needsLogin(a) {
    return a.state === "expiring" || a.state === "logged-out" || a.state === "missing"
}

function anyNeedsLogin(data) {
    if (!data)
        return false
    var i, j, listed = listedNames(data), list = data.accounts || []
    for (i = 0; i < list.length; i++)
        if (listed[list[i].name] && list[i].state !== "missing" && needsLogin(list[i]))
            return true
    var hosts = data.hosts || []
    for (j = 0; j < hosts.length; j++) {
        list = hosts[j].accounts || []
        for (i = 0; i < list.length; i++)
            if (listed[list[i].name] && needsLogin(list[i]))
                return true
    }
    return false
}

function duration(secs) {
    if (secs <= 0)
        return "now"
    var m = Math.floor(secs / 60)
    var d = Math.floor(m / 1440)
    m -= d * 1440
    var h = Math.floor(m / 60)
    m -= h * 60
    if (d > 0)
        return d + "d " + h + "h"
    if (h > 0)
        return h + "h " + m + "m"
    return Math.max(m, 1) + "m"
}

// Used percent minus the elapsed percent of the window at the reading time, as claude-tools usage and the status line
// compute it; null when the reset time does not fall inside the window.
function pace(win, length, at) {
    var u = usedOf(win)
    if (u === null || !win.resets_at || !length)
        return null
    var left = win.resets_at - at
    if (left <= 0 || left > length)
        return null
    return u - (1 - left / length) * 100
}

function paceText(d) {
    if (d === null)
        return ""
    if (d > 5)
        return "▲ +" + Math.round(d) + "%"
    if (d < -5)
        return "▽ " + Math.round(d) + "%"
    return "≈"
}

function weekdayTime(ts) {
    return Qt.formatDateTime(new Date(ts * 1000), "ddd HH:mm")
}

function age(ts, now) {
    var s = Math.max(0, now - ts)
    if (s < 60)
        return "just now"
    var m = Math.floor(s / 60)
    if (m < 60)
        return m + " min ago"
    var h = Math.floor(m / 60)
    if (h < 48)
        return h + " h ago"
    return Math.floor(h / 24) + " d ago"
}

function loginEnds(ts, now) {
    if (ts === null || ts === undefined)
        return ""
    var left = ts - now
    if (left <= 0)
        return "login expired"
    if (left >= 86400)
        return "login ends in " + Math.floor(left / 86400) + " d"
    return "login ends in " + duration(left)
}

function stateText(state) {
    switch (state) {
    case "ok": return "ok"
    case "expiring": return "login expiring"
    case "logged-out": return "logged out"
    case "missing": return "no login"
    default: return "error"
    }
}
