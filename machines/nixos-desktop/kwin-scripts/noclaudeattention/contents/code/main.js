// Clears the "demands attention" (urgency) flag that Claude Desktop raises on
// itself when alt-tabbing. That false flag makes auto-hide Plasma panels reveal
// themselves. Scoped to windows whose resource class/name contains "claude" so
// every other application keeps the normal attention behavior.

function isClaude(window) {
    if (!window) {
        return false;
    }
    var resourceClass = (window.resourceClass || "").toString().toLowerCase();
    var resourceName = (window.resourceName || "").toString().toLowerCase();
    return resourceClass.indexOf("claude") !== -1 || resourceName.indexOf("claude") !== -1;
}

function clearAttention(window) {
    if (isClaude(window) && window.demandsAttention) {
        window.demandsAttention = false;
        print("noclaudeattention: cleared demandsAttention for " + window.resourceClass);
    }
}

function watch(window) {
    if (!isClaude(window)) {
        return;
    }
    print("noclaudeattention: watching " + window.resourceClass);
    window.demandsAttentionChanged.connect(function () {
        clearAttention(window);
    });
    clearAttention(window);
}

var windows = workspace.windowList ? workspace.windowList() : workspace.clientList();
for (var i = 0; i < windows.length; i++) {
    watch(windows[i]);
}
workspace.windowAdded.connect(watch);
print("noclaudeattention: loaded, scanned " + windows.length + " windows");
