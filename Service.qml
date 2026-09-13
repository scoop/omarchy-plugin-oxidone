import QtQuick
import Quickshell
import "src/today.js" as Today
import "src/state.js" as State
import "src/version.js" as Version
import "src/apply.js" as Apply

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

    // The Apply queue. One in flight at a time: each Apply is its own request to
    // Google, `rate_limited` is a real exit, and one-at-a-time keeps the
    // ordering reasoning tractable — slice 2 is the record of what concurrency
    // costs here. Writes are sub-second, so at human keying speed the queue is
    // invisible.
    //
    // Held in memory only. Persisting it would mean writing a file at a
    // predictable path on every keystroke, which is the surface slice 1 refused
    // for the Snapshot, for a queue that drains in under a second.
    property var applyQueue: []
    property var applyCurrent: null

    // Used as sets keyed by Entry id. Assigned whole on every change, never
    // mutated: a `var` property does not notify on mutation, so an in-place
    // write would change the data and update no binding in the Pane.
    property var applyPending: ({})
    property var applyErrors: ({})

    // Past any burst a person can type, small enough that "queue full" is a
    // path that can actually be reached and tested.
    readonly property int applyQueueMax: 32

    readonly property int applyQueueDepth: applyQueue.length + (applyCurrent !== null ? 1 : 0)

    // Bumped by every fold. Mirrors `epoch`: a Today poll captures this before
    // it starts, and if a fold happens while that poll is in flight, the poll's
    // answer is older than the fold and must not overwrite it — the fold is the
    // server's own, newer word on that row.
    property int applyGeneration: 0

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

    // The binary epoch this Apply was started against. `applyProc.command`
    // binds live to `resolvedBinary`, so without this a write queued for one
    // binary could run against, and be answered by, another.
    property int applyEpoch: 0

    // The Apply generation this Today poll was started against. Captured in
    // the same breath as `todayEpoch`, immediately before the process starts.
    property int todayApplyGeneration: 0

    // The same, for the List read. The List has no clock behind it, so an
    // answer that predates a fold would revert a confirmed write for as long
    // as the scope stays put — longer than Today's one poll cycle.
    property int tasksApplyGeneration: 0

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
                // Captured here rather than bound on the process, because
                // `onResolvedBinaryChanged` calls refresh() in the same turn the
                // path changed and a binding on `command` has not re-evaluated
                // by then — the check would run against the binary we just moved
                // away from, and `versionEpoch === epoch` would make that stale
                // answer authoritative. Epoch and argv now come from one read of
                // `resolvedBinary`, so the guard and the process cannot disagree
                // about which binary this is.
                versionProc.command = [root.resolvedBinary, "--version"];
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
            root.todayApplyGeneration = root.applyGeneration;
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
        root.tasksApplyGeneration = root.applyGeneration;
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

    // Assign, never mutate: see the note on applyPending.
    function _setApplyFlag(map, key, value) {
        var next = {};
        for (var existing in map) {
            next[existing] = map[existing];
        }
        if (value === undefined) {
            delete next[key];
        } else {
            next[key] = value;
        }
        return next;
    }

    function clearApplyError(entryId) {
        if (root.applyErrors[entryId] !== undefined) {
            root.applyErrors = root._setApplyFlag(root.applyErrors, entryId, undefined);
        }
    }

    /**
     * Enqueue one Apply. `op` is one of Apply.OPS.
     *
     * Nothing is predicted here: the row is marked Pending and the Snapshot is
     * left exactly as it was until the Echo arrives.
     */
    function applyOp(op, listId, taskId) {
        if (!versionOk) {
            root.applyErrors = root._setApplyFlag(root.applyErrors, taskId, "no usable oxidone");
            return;
        }
        if (root.applyQueueDepth >= root.applyQueueMax) {
            root.applyErrors = root._setApplyFlag(root.applyErrors, taskId, "too many changes at once");
            return;
        }
        var command;
        try {
            command = Apply.buildCommand(op, listId, taskId);
        } catch (error) {
            // Our bug, not oxidone's refusal: a row without a list id, or an op
            // this release does not send.
            console.warn("oxidone: refusing to send", op, "-", error.message);
            root.applyErrors = root._setApplyFlag(root.applyErrors, taskId, Apply.messageForExit(1));
            return;
        }
        root.clearApplyError(taskId);
        root.applyPending = root._setApplyFlag(root.applyPending, taskId, true);
        root.applyQueue = root.applyQueue.concat([{ op: op, list: listId, task: taskId, command: command }]);
        root.drainApply();
    }

    function drainApply() {
        if (root.applyCurrent !== null || root.applyQueue.length === 0 || applyProc.running) {
            return;
        }
        if (!versionOk) {
            // The binary was replaced or failed its check while this sat in the
            // queue. Hold the queue rather than sending to something unvetted;
            // the next passing version check drains it.
            return;
        }
        root.applyCurrent = root.applyQueue[0];
        root.applyQueue = root.applyQueue.slice(1);
        applyProc.stdinPayload = root.applyCurrent.command;
        root.applyEpoch = root.epoch;
        applyProc.start();
    }

    // Fold one Echo into both Snapshots. Today and the open List can each hold
    // the same Entry, and neither is authoritative over the other.
    function _foldEcho(echo, leavesToday) {
        if (root.payload !== null && root.payload !== undefined) {
            var today = {
                today: root.payload.today,
                entries: leavesToday
                    ? Apply.removeEntry(root.payload.entries, echo.id)
                    : Apply.patchEntries(root.payload.entries, echo),
            };
            root.payload = today;
            // Recomputed from the same functions the poll uses, so the bar can
            // never disagree with the Pane about what the Snapshot means.
            root.outstanding = Today.outstandingCount(today);
            root.overdue = Today.hasOverdue(today);
        }
        if (root.listPayload !== null && root.listPayload !== undefined) {
            root.listPayload = {
                list: root.listPayload.list,
                entries: Apply.patchEntries(root.listPayload.entries, echo),
            };
        }
        // Every fold is a write the Snapshot now carries that a poll started
        // earlier cannot know about.
        root.applyGeneration += 1;
    }

    function _foldDeletion(entryId) {
        if (root.payload !== null && root.payload !== undefined) {
            var today = { today: root.payload.today, entries: Apply.removeEntry(root.payload.entries, entryId) };
            root.payload = today;
            root.outstanding = Today.outstandingCount(today);
            root.overdue = Today.hasOverdue(today);
        }
        if (root.listPayload !== null && root.listPayload !== undefined) {
            root.listPayload = {
                list: root.listPayload.list,
                entries: Apply.removeEntry(root.listPayload.entries, entryId),
            };
        }
        // Every fold is a write the Snapshot now carries that a poll started
        // earlier cannot know about.
        root.applyGeneration += 1;
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
        // No `command` binding: refresh() assigns it immediately before start,
        // so the path this asks about is the path the epoch was captured from.
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
            // A write held back for want of a usable binary now has one.
            root.drainApply();
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
                if (root.applyGeneration !== root.todayApplyGeneration) {
                    // An Apply folded its Echo into the Snapshot while this read
                    // was in flight. That Echo is the server's own, newer word on
                    // its row; this answer was gathered before it and would
                    // silently revert it (a completed task un-completing itself)
                    // if written. Keep the fold; still take the parts of a
                    // successful poll that do not touch the Snapshot's rows.
                    console.warn("oxidone: today answer predates a write in flight, not folding it in");
                } else {
                    root.outstanding = Today.outstandingCount(payload);
                    root.overdue = Today.hasOverdue(payload);
                    root.payload = payload;
                    // A poll supersedes only the failures it actually describes: an
                    // Entry absent from this answer (a List-scope row with no Today
                    // date, say) keeps its message until something speaks to that row.
                    // An answer too old to render is too old to erase a message with.
                    root.applyErrors = Apply.retainErrorsAbsentFrom(root.applyErrors, payload.entries);
                }
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
                var lists = Today.parseLists(out);
                if (lists === null) {
                    // Refused whole. The selector keeps what it last knew and
                    // always keeps Today; a half-read list of lists would be a
                    // guess, and the Pane dereferences these inside a binding.
                    console.warn("oxidone: lists answer refused, keeping the selector as it was");
                    return;
                }
                root.lists = lists;
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
                if (root.applyGeneration !== root.tasksApplyGeneration) {
                    // An Apply folded its Echo into this List while the read was
                    // in flight. The fold is the server's own, newer word on that
                    // row; this answer was gathered before it and would revert it
                    // — and nothing re-reads a List on a clock, so the reverted
                    // row would stay wrong until the scope changes.
                    console.warn("oxidone: list answer predates a write in flight, not folding it in");
                    return;
                }
                root.listPayload = payload;
                // A read speaks to the rows it carries: a row that failed in
                // this scope has been answered for afresh, so its message has
                // had its say and must not outlive the answer that replaced it.
                root.applyErrors = Apply.retainErrorsAbsentFrom(root.applyErrors, payload.entries);
            } catch (error) {
                console.warn("oxidone: unreadable list:", error.message);
            }
        }
    }

    // The write Bridge. The command goes on stdin, never in argv: /proc's
    // cmdline is readable by every process running as this user, and these
    // carry the ids of the person's own tasks.
    BoundedProcess {
        id: applyProc
        command: [root.resolvedBinary, "json", "apply"]
        // One Entry back, or one small error envelope. Anything larger is a
        // fault, not an answer.
        maxBytes: 65536
        // A person is waiting on this one, unlike a poll.
        deadlineMs: 10000
        onFinishedWith: function (out, err, code, tooLarge) {
            var sent = root.applyCurrent;
            root.applyCurrent = null;
            applyProc.stdinPayload = "";
            if (sent === null) {
                root.drainApply();
                return;
            }
            root.applyPending = root._setApplyFlag(root.applyPending, sent.task, undefined);

            if (root.applyEpoch !== root.epoch) {
                // Started against a different binary. Whatever this answered, it
                // is not a word from the binary we talk to now: fold nothing and
                // say the change did not land.
                console.warn("oxidone: apply", sent.op, "answered from a binary we no longer use");
                root.applyErrors = root._setApplyFlag(root.applyErrors, sent.task, Apply.messageForExit(1));
                root.drainApply();
                return;
            }

            if (code !== 0 || tooLarge) {
                var kind = State.errorKindOf(err);
                // oxidone's own message goes here and nowhere else: it is
                // serde's sentence or Google's, not one to show a person.
                console.warn("oxidone: apply", sent.op, "failed, exit", code, kind !== "" ? "(" + kind + ")" : "");
                if (code === 6) {
                    // The row is gone from both Snapshots by the time
                    // _foldDeletion returns, so there is no row left to carry a
                    // message: the Pane looks errors up by row id, and this id no
                    // longer names one. The row's disappearance is the feedback.
                    root._foldDeletion(sent.task);
                    root.refresh();
                } else {
                    root.applyErrors = root._setApplyFlag(root.applyErrors, sent.task, Apply.messageForExit(tooLarge ? 1 : code));
                    if (code === 3) {
                        // A fact about the grant, not about this row.
                        root.state = State.AUTH_NEEDED;
                    }
                }
                // Deliberately not STALE on exit 4: `stale` is a fact about a
                // Today poll, and a failed write is not a failed poll.
                root.drainApply();
                return;
            }

            if (sent.op === "delete") {
                var deleted = Apply.parseDeleted(out);
                if (deleted === null) {
                    console.warn("oxidone: apply delete answered with something unreadable");
                    root.applyErrors = root._setApplyFlag(root.applyErrors, sent.task, Apply.messageForExit(1));
                    root.drainApply();
                    return;
                }
                if (deleted.id !== sent.task || deleted.list !== sent.list) {
                    // Answered for an Entry we did not send. Folding this would
                    // remove the wrong row from both Snapshots — fail closed.
                    console.warn("oxidone: apply delete answered for a different entry than sent");
                    root.applyErrors = root._setApplyFlag(root.applyErrors, sent.task, Apply.messageForExit(1));
                    root.drainApply();
                    return;
                }
                root._foldDeletion(deleted.id);
                root.drainApply();
                return;
            }

            var echo = Apply.parseEcho(out);
            if (echo === null) {
                // Exit 0 with an answer we cannot read is our bug. Keep the
                // Snapshot untouched and say the change did not land, rather
                // than claiming a success we cannot show.
                console.warn("oxidone: apply", sent.op, "answered with something unreadable");
                root.applyErrors = root._setApplyFlag(root.applyErrors, sent.task, Apply.messageForExit(1));
                root.drainApply();
                return;
            }
            // Migrate moves the due date to max(today, due) + 1 day, which is
            // always strictly after today — so a migrated Entry is always out of
            // Today. Derived from what the op does, deliberately not from a
            // local `due <= today` test: that would put a second definition of
            // Today in the plugin, which is the thing oxidone#137 removed.
            root._foldEcho(echo, sent.op === "migrate");
            root.drainApply();
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
