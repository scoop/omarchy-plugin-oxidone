import QtQuick
import Quickshell
import "src/today.js" as Today
import "src/state.js" as State
import "src/version.js" as Version

// Owns the poll and the state derived from it.
//
// Mounted for the life of the shell, because the Indicator's job is to be right
// when nobody is looking at it. The Indicator reads from here; it never runs
// oxidone itself.
//
// Every read is one short-lived process. There is no daemon and no connection
// to keep alive: a five-minute cadence does not justify supervising one, and a
// process that exits is a process that cannot leak.
Item {
    id: root

    property string omarchyPath: ""
    property var shell: null
    property var manifest: null

    // Pushed down by the Indicator: the shell injects settings into bar widgets
    // only, never into a service.
    property string binaryPath: ""
    property int pollIntervalSec: 300

    // The Snapshot: the last good answer, and what the bar shows until a newer
    // one arrives. Held in memory only — the first poll lands seconds after the
    // shell starts, and a file written every five minutes would buy a few
    // seconds of cold-start accuracy for exactly the symlink and
    // predictable-path race surface that review scrutinises hardest.
    property int outstanding: 0
    property bool overdue: false

    // The Snapshot the Pane renders. Held in memory only, like the counts.
    property var payload: null

    // The List scope: on-demand reads, never polled. `lists` is the
    // selector's own options; `listPayload` is whichever List was last
    // asked for, keyed loosely by `listId` rather than tracked per-id,
    // since the Pane only ever looks at one List at a time.
    property var lists: []
    property var listPayload: null
    property string listId: ""

    // The list the running request was actually started for. `listId` is what is
    // wanted; this is what was asked for. They differ exactly while a request is
    // in flight and the scope has moved on.
    property string listRequestedId: ""

    // Consecutive answers that named a list nobody asked for. Bounded, because a
    // binary that keeps answering for the wrong list would otherwise be retried
    // forever.
    property int listStaleDiscards: 0

    // Starts silent, not alarmed. UNUSABLE would light the attention glyph for
    // the few hundred milliseconds before the first version check answers, and
    // a widget that cries wolf on every shell start is one you learn to ignore.
    // With no entries yet the Indicator is hidden either way.
    property string state: State.OK
    property double lastSuccess: 0
    property int consecutiveFailures: 0

    // Empty means "the default install location". Resolved once, here, so the
    // rest of the file can assume an absolute path.
    readonly property string resolvedBinary: binaryPath !== "" ? binaryPath : Quickshell.env("HOME") + "/.local/bin/oxidone"

    // A relative path would resolve against whatever directory the shell
    // happens to be in, which is not a decision this plugin gets to leave to
    // chance. Fail closed and say so.
    readonly property bool binaryLooksAbsolute: resolvedBinary.charAt(0) === "/"

    property bool versionChecked: false
    property bool versionOk: false

    // Bumped whenever the binary we talk to changes. A callback carrying a stale
    // epoch belongs to a process started against a different binary, and its
    // answer must not be written into the state we hold now.
    property int epoch: 0
    property int versionEpoch: 0
    property int todayEpoch: 0

    function refresh() {
        if (!binaryLooksAbsolute) {
            root.state = State.UNUSABLE;
            console.warn("oxidone: configured path is not absolute:", resolvedBinary);
            root.consecutiveFailures += 1;
            root.scheduleNext(1);
            return;
        }
        if (!versionChecked) {
            if (!versionProc.running) {
                root.versionEpoch = root.epoch;
                versionProc.start();
            }
            return;
        }
        if (!versionOk) {
            // Defensive: the version handler clears versionChecked so a retry
            // re-runs the check. Reaching here still must not stop the clock.
            root.state = State.UNUSABLE;
            root.consecutiveFailures += 1;
            root.scheduleNext(1);
            return;
        }
        if (!todayProc.running) {
            root.todayEpoch = root.epoch;
            todayProc.start();
        }
    }

    // On-demand, not polled: the Pane calls these when it opens or when the
    // person picks a List, not on the five-minute clock, so neither touches
    // `scheduleNext` or the failure state the poll cycle owns.
    function loadLists() {
        if (versionOk && !listsProc.running) {
            listsProc.start();
        }
    }

    // A single place that starts a request, so `listId` (what is wanted) and
    // `listRequestedId` (what was asked for) can never drift apart.
    function startListLoad() {
        root.listRequestedId = root.listId;
        tasksProc.start();
    }

    function loadList(id) {
        root.listId = id;
        if (!versionOk) {
            return;
        }
        // A request already in flight is left to finish; its handler starts the
        // one that is wanted by then, so a scope change is deferred, never lost.
        if (!tasksProc.running) {
            root.startListLoad();
        }
    }

    function scheduleNext(code) {
        pollTimer.interval = State.nextDelaySeconds(code, root.pollIntervalSec, root.consecutiveFailures) * 1000;
        pollTimer.restart();
    }

    // Re-check the binary whenever the person points us somewhere else.
    onResolvedBinaryChanged: {
        epoch += 1;
        versionChecked = false;
        versionOk = false;
        consecutiveFailures = 0;
        refresh();
    }

    BoundedProcess {
        id: versionProc
        command: [root.resolvedBinary, "--version"]
        maxBytes: 256
        deadlineMs: 5000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (root.versionEpoch !== root.epoch) {
                // Stale: started against a different binary. Its answer must not
                // be written, but dropping it silently would leave nothing running
                // and nothing scheduled.
                root.refresh();
                return;
            }
            root.versionChecked = true;
            root.versionOk = code === 0 && !tooLarge && Version.satisfies(Version.parseVersion(out), Version.MINIMUM);
            if (!root.versionOk) {
                root.state = State.UNUSABLE;
                console.warn("oxidone: no usable binary at", root.resolvedBinary, "— needs >= 1.2.0");
                // Do not latch: the next retry re-runs the check, so replacing the
                // binary in place at the same path is eventually picked up.
                root.versionChecked = false;
                root.consecutiveFailures += 1;
                root.scheduleNext(1);
                return;
            }
            root.consecutiveFailures = 0;
            root.refresh();
        }
    }

    BoundedProcess {
        id: todayProc
        command: [root.resolvedBinary, "json", "today"]
        // A day's worth of entries across every List, with room to spare. An
        // answer larger than this is not a day, it is a fault.
        maxBytes: 262144
        deadlineMs: 30000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (root.todayEpoch !== root.epoch) {
                // Stale: started against a different binary. Its answer must not
                // be written, but dropping it silently would leave nothing running
                // and nothing scheduled.
                root.refresh();
                return;
            }
            if (code !== 0 || tooLarge) {
                root.consecutiveFailures += 1;
                root.state = tooLarge ? State.STALE : State.stateForExit(code);
                var kind = State.errorKindOf(err);
                console.warn("oxidone: poll failed, exit", code, kind !== "" ? "(" + kind + ")" : "");
                root.scheduleNext(code);
                return;
            }
            try {
                var payload = Today.parseToday(out);
                root.outstanding = Today.outstandingCount(payload);
                root.overdue = Today.hasOverdue(payload);
                root.payload = payload;
                root.state = State.OK;
                root.lastSuccess = Date.now();
                root.consecutiveFailures = 0;
                root.scheduleNext(0);
            } catch (error) {
                // A clean exit with an answer we cannot read is our bug, not
                // oxidone's failure. Keep the Snapshot and say so.
                root.consecutiveFailures += 1;
                root.state = State.STALE;
                console.warn("oxidone: unreadable answer:", error.message);
                root.scheduleNext(2);
            }
        }
    }

    // The two List reads. Neither is polled and neither is guarded by
    // `epoch`: they only ever run because the Pane asked for them just now,
    // against whichever binary `versionOk` already vetted, and a failure
    // here describes that one on-demand fetch rather than the widget's
    // overall health — it must not perturb `state` or the poll clock.
    BoundedProcess {
        id: listsProc
        command: [root.resolvedBinary, "json", "lists"]
        maxBytes: 65536
        deadlineMs: 15000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0 || tooLarge) {
                console.warn("oxidone: lists failed, exit", code);
                return;
            }
            try {
                var payload = JSON.parse(out);
                root.lists = Array.isArray(payload.lists) ? payload.lists.slice(0, 200) : [];
            } catch (error) {
                console.warn("oxidone: unreadable lists:", error.message);
            }
        }
    }

    BoundedProcess {
        id: tasksProc
        command: [root.resolvedBinary, "json", "tasks", "--list", root.listId]
        maxBytes: 262144
        deadlineMs: 30000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0 || tooLarge) {
                console.warn("oxidone: list load failed, exit", code);
                // Never retry the list that just failed — that would spin against
                // a broken binary. But a newer scope queued behind this request
                // was never sent, and dropping it strands the pane on the wrong
                // list with nothing to say so.
                if (root.listId !== root.listRequestedId) {
                    root.startListLoad();
                }
                return;
            }
            try {
                var payload = Today.parseList(out);
                if (payload.list !== root.listId) {
                    // The scope changed while this was in flight. Showing this
                    // would put one list's entries under another list's name.
                    root.listStaleDiscards += 1;
                    if (root.listStaleDiscards > 3) {
                        console.warn("oxidone: list answers keep naming a different list; giving up");
                        return;
                    }
                    root.startListLoad();
                    return;
                }
                root.listStaleDiscards = 0;
                root.listPayload = payload;
            } catch (error) {
                console.warn("oxidone: unreadable list:", error.message);
            }
        }
    }

    Timer {
        id: pollTimer
        interval: root.pollIntervalSec * 1000
        repeat: false
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()
}
