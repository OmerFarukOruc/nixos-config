.pragma library

var namePattern = /^[a-z0-9][a-z0-9.-]*$/
var usageCommand = "@claudeTools@/bin/claude-tools usage"
var accountsCommand = "@claudeTools@/bin/claude-tools accounts"

var pollCommand = "sh -c '" + usageCommand + " --json --cached'"
var refreshCommand = "sh -c '" + usageCommand + " --json --max-age 60'"

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

function fullest(a) {
    var f = usedOf(a.five_hour), s = usedOf(a.seven_day)
    if (f === null && s === null)
        return null
    return s === null || (f !== null && f >= s) ? a.five_hour : a.seven_day
}

function listedNames(data) {
    var names = {}, list = (data && data.combined) || []
    for (var i = 0; i < list.length; i++)
        names[list[i].name] = true
    return names
}

function bestAccount(data) {
    var listed = listedNames(data)
    var order = (data && data.order) || []
    var list = (data && data.accounts) || []
    for (var i = 0; i < order.length; i++) {
        if (order[i].group === "blocked" || !listed[order[i].name])
            continue
        for (var j = 0; j < list.length; j++) {
            var w = list[j].name === order[i].name ? fullest(list[j]) : null
            if (w)
                return { account: list[j], used: Number(w.used), tone: w.tone }
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

function paceText(w) {
    if (!w || w.pace_state === null || w.pace_state === undefined)
        return ""
    if (w.pace_state === "ahead")
        return "▲ +" + w.pace + "%"
    if (w.pace_state === "behind")
        return "▽ " + w.pace + "%"
    return "≈"
}

function resetText(w, weekday) {
    if (!w || w.reset_in === null || w.reset_in === undefined)
        return "no data"
    if (w.reset_in === "now")
        return "resets now"
    return weekday ? w.reset_clock : "in " + w.reset_in
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

function loginLeft(login) {
    if (!login.login_left)
        return ""
    return login.login_left === "expired" ? "login expired" : "login left: " + login.login_left
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
