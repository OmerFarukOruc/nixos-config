.pragma library

var namePattern = /^[a-z0-9][a-z0-9.-]*$/
var usageBin = "@claudeTools@/bin/claude-usage"
var accountsBin = "@claudeTools@/bin/claude-accounts"

var pollCommand = "sh -c '" + usageBin + " --json --cached'"
var refreshCommand = "sh -c '" + usageBin + " --json --max-age 60'"

// Returns null for a name or host that the shell could read as more than a word.
function loginCommand(name, host) {
    if (!namePattern.test(name || ""))
        return null
    if (host && !namePattern.test(host))
        return null
    return "sh -c '" + accountsBin + " login-window " + name + (host ? " --on " + host : "") + "'"
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

// The binding window of an account is the one with the higher use.
function maxUsed(a) {
    var f = usedOf(a.five_hour), s = usedOf(a.seven_day)
    if (f === null && s === null)
        return null
    return Math.max(f === null ? 0 : f, s === null ? 0 : s)
}

// Local account in state ok or expiring with the most room left, or null.
function bestAccount(data) {
    var best = null, bestUsed = 0
    var list = (data && data.accounts) || []
    for (var i = 0; i < list.length; i++) {
        var a = list[i]
        if (a.state !== "ok" && a.state !== "expiring")
            continue
        var u = maxUsed(a)
        if (u === null)
            continue
        if (best === null || u < bestUsed) {
            best = a
            bestUsed = u
        }
    }
    return best === null ? null : { account: best, used: bestUsed }
}

function needsLogin(a) {
    return a.state === "expiring" || a.state === "logged-out" || a.state === "missing"
}

function anyNeedsLogin(data) {
    if (!data)
        return false
    var i, j, list = data.accounts || []
    for (i = 0; i < list.length; i++)
        if (list[i].state !== "missing" && needsLogin(list[i]))
            return true
    var hosts = data.hosts || []
    for (j = 0; j < hosts.length; j++) {
        list = hosts[j].accounts || []
        for (i = 0; i < list.length; i++)
            if (needsLogin(list[i]))
                return true
    }
    return false
}

// "2h 10m", "35m", "3d 4h"
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

// Used percent minus the elapsed percent of the window at the reading time, as claude-usage and the status line
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
