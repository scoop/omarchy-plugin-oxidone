import QtQuick
import Quickshell
import "src/today.js" as Today
import "src/state.js" as State
import "src/version.js" as Version
import "src/apply.js" as Apply
import "src/rows.js" as Rows

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

    // The concrete id `@default` resolves to, from the same `json lists` answer.
    // Today is no List, so a capture made there needs a target, and this is the
    // one oxidone's own TUI uses for exactly that. Empty until `lists` has been
    // read, or when the answer named a List we did not keep.
    property string defaultList: ""

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

    // Which rows are Pending, as a set keyed by Entry id. Derived, never
    // written: it is exactly the rows the queue above is carrying, plus the one
    // whose date is being resolved, recomputed whenever any of the three
    // changes. A flag written at enqueue and deleted by the answering handler
    // could not survive two Applies against one row — the first answer cleared
    // what the second was still waiting on, and `drainApply` never wrote it
    // back, so the row read normal (and, with `enabled: !pending`, took further
    // presses) for the whole of the second's flight. That was issue #5.
    //
    // All three sources are assigned whole and read here in the binding itself,
    // which is what makes this re-evaluate at all: a `var` property does not
    // notify on mutation.
    readonly property var applyPending: Apply.pendingSet(root.applyCurrent, root.applyQueue, root.dueRequest)

    // Still a map this file writes, and so still assigned whole on every
    // change, never mutated — an in-place write would change the data and
    // update no binding in the Pane. Unlike Pending, a message outlives the
    // Apply that produced it, so there is nothing to derive it from.
    //
    // Null-prototype, like every map in this plugin whose keys come from
    // outside it. An Entry id is whatever oxidone printed, and the Pane asks
    // `applyErrors[row.id] !== undefined` — on a plain object an entry id of
    // `constructor` answers that with Object's constructor, and the row draws a
    // stringified function as its failure message.
    property var applyErrors: Object.create(null)

    // Captures, keyed one per capture rather than by Entry id — a `create` has
    // no Entry to be keyed by, and the Pane's strip stays open for a run, so two
    // can be in flight at once. A shared key would let the second capture's
    // enqueue clear the first's message and the first answer clear both rows'
    // Pending. Each value is { title, pending, message, seq }.
    //
    // Deliberately not `applyErrors`: that map is pruned by comparing its keys
    // against the entry ids in a fresh answer, and a capture key is never an
    // entry id, so a failure parked there would never be cleared at all.
    property var captures: Object.create(null)
    property int captureSeq: 0

    // Past any burst a person can type, small enough that "queue full" is a
    // path that can actually be reached and tested.
    readonly property int applyQueueMax: 32

    // How many settled capture failures are kept. A run against a dead network
    // must not grow this without end, and five is more than a strip can show.
    readonly property int captureFailureMax: 5

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

    // A date changed, and only oxidone can say what that did to Today's
    // membership and order. Set by `settleToday`, cleared by the poll it asks
    // for — so a request made while a poll is already in flight is honoured
    // after it rather than dropped, that poll being older than the fold.
    property bool todayRepollWanted: false

    // The `json due` resolution in flight: { list, task, expr, epoch }. One at a
    // time, because one editor is open at a time.
    property var dueRequest: null

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
            root.todayRepollWanted = false;
            todayProc.start();
            return;
        }
    }

    /**
     * Read Today again, because something just happened that only oxidone can
     * describe the consequences of.
     *
     * Two things ask for this. `set_due` may move an Entry out of Today or
     * leave it in, and only the `due <= today` rule decides — the rule
     * oxidone#137 made oxidone's alone; rather than keep a second copy of it
     * here, fold what the server said and then read Today again. An Apply told
     * its Entry is already gone asks for the same thing for a different reason:
     * an Entry that vanished underneath us is evidence the Snapshot was out of
     * date in ways beyond the one row the fold just dropped.
     *
     * The flag rather than a bare `refresh()`, because `refresh()` does nothing
     * while a poll is already running — which is exactly when the answer we
     * hold is most likely to be the one that went out of date. This gets the
     * re-read asked for once that poll lands instead of dropping it.
     */
    function settleToday() {
        root.todayRepollWanted = true;
        root.refresh();
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

    // Assign, never mutate: see the note on applyErrors.
    function _setApplyFlag(map, key, value) {
        var next = Object.create(null);
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

    // The title a List carries, for the one sentence that has to name one.
    // Sanitized on the way out: it is a Google string, and this is the only
    // route by which one reaches a message rather than a row.
    function listTitleFor(listId) {
        for (var i = 0; i < root.lists.length; i++) {
            if (root.lists[i].id === listId) {
                return Rows.plain(root.lists[i].title, 40);
            }
        }
        return "";
    }

    // Assign, never mutate — the same rule `applyErrors` follows, for the same
    // reason. `record` of null removes the capture.
    function _putCapture(key, record) {
        var next = Object.create(null);
        for (var existing in root.captures) {
            next[existing] = root.captures[existing];
        }
        if (record === null) {
            delete next[key];
        } else {
            next[key] = record;
        }
        root.captures = next;
    }

    // Keep the newest failures and drop the oldest, by the sequence each capture
    // was minted with. A capture still in flight is never dropped: it has an
    // answer coming that needs somewhere to land.
    function _pruneCaptureFailures() {
        var failed = [];
        for (var key in root.captures) {
            var record = root.captures[key];
            if (!record.pending && record.message !== "") {
                failed.push({ key: key, seq: record.seq });
            }
        }
        if (failed.length <= root.captureFailureMax) {
            return;
        }
        failed.sort(function (a, b) {
            return a.seq - b.seq;
        });
        var next = Object.create(null);
        for (var existing in root.captures) {
            next[existing] = root.captures[existing];
        }
        for (var i = 0; i < failed.length - root.captureFailureMax; i++) {
            delete next[failed[i].key];
        }
        root.captures = next;
    }

    /** Drop every capture that has finished. The Pane calls this when its strip closes. */
    function clearSettledCaptures() {
        var next = Object.create(null);
        for (var key in root.captures) {
            if (root.captures[key].pending) {
                next[key] = root.captures[key];
            }
        }
        root.captures = next;
    }

    function _settleCapture(key) {
        root._putCapture(key, null);
    }

    // One place both stores are written from, so a queue entry's `capture` flag
    // is the only thing that decides which one a message lands in.
    function _reportFailure(entry, message) {
        if (!entry.capture) {
            root.applyErrors = root._setApplyFlag(root.applyErrors, entry.key, message);
            return;
        }
        var record = root.captures[entry.key];
        root._putCapture(entry.key, {
            title: record ? record.title : "",
            pending: false,
            message: message,
            seq: record ? record.seq : root.captureSeq
        });
        root._pruneCaptureFailures();
    }

    /**
     * Capture one new entry into `listId`.
     *
     * `dateToday` mirrors what oxidone's TUI does on its own Today pane: a
     * dateless capture there is dated today, so the entry stays on the page it
     * was created on. `apply create` has no `due` field, so that costs a second
     * Apply — chained off the first's Echo, under this capture's own key, so the
     * strip stays Pending across both and a failure between them is reported as
     * the half-capture it is.
     */
    function capture(title, listId, dateToday) {
        root.captureSeq += 1;
        var key = Apply.captureKey(root.captureSeq);
        root._putCapture(key, { title: title, pending: true, message: "", seq: root.captureSeq });
        root.applyOp("create", { list: listId, title: title }, {
            capture: true,
            key: key,
            chain: dateToday ? "dueToday" : ""
        });
    }

    /**
     * Resolve a date phrase, then set it.
     *
     * `apply set_due` takes ISO and only ISO; `json due` is what turns
     * `tomorrow` or `+3d` into one — pure, no network, no credentials. The row
     * is marked Pending here rather than at the Apply, so it stays muted across
     * both steps instead of blinking back to normal in between.
     */
    function resolveAndSetDue(listId, taskId, expr) {
        // First, before the request can even take the one-at-a-time slot: this
        // is the only string this plugin puts in an argument list, and whether
        // it is shaped like a date phrase is a question about the string alone,
        // not about the binary or about what else is in flight.
        if (!Rows.isDueExpr(expr)) {
            root.applyErrors = root._setApplyFlag(root.applyErrors, taskId, "not a date phrase");
            return;
        }
        if (!versionOk) {
            root.applyErrors = root._setApplyFlag(root.applyErrors, taskId, "no usable oxidone");
            return;
        }
        if (root.dueRequest !== null || dueProc.running) {
            root.applyErrors = root._setApplyFlag(root.applyErrors, taskId, "one date at a time");
            return;
        }
        root.clearApplyError(taskId);
        // The assignment below is what marks the row Pending: `applyPending` is
        // derived from `dueRequest` among others, so the row stays muted across
        // both steps instead of blinking back to normal between them.
        root.dueRequest = { list: listId, task: taskId, expr: expr, epoch: root.epoch };
        // Assigned, not bound. A `command` binding on `dueRequest` and this
        // function are both dependents of the same property, and issue #2 is the
        // record of what happens when the order between them is assumed: the
        // process ran against the value the binding had not caught up to yet.
        // One read of the expression, into the argv and the request together.
        dueProc.command = [root.resolvedBinary, "json", "due", expr];
        dueProc.start();
    }

    function clearApplyError(entryId) {
        if (root.applyErrors[entryId] !== undefined) {
            root.applyErrors = root._setApplyFlag(root.applyErrors, entryId, undefined);
        }
    }

    /**
     * Enqueue one Apply. `op` is one of Apply.OPS, `params` exactly the fields
     * that op's row in the contract names.
     *
     * `options.capture` decides which store this entry's Pending and message
     * live in: an Entry-keyed one for a row op, the capture-keyed one for a
     * `create` and for the `set_due` chained off it, which has no row of its own
     * on screen to carry either. `options.chain` is "dueToday" on a create that
     * must be dated, "captured" on the set_due that answers one.
     *
     * Nothing is predicted here: the row is marked Pending and the Snapshot is
     * left exactly as it was until the Echo arrives.
     */
    function applyOp(op, params, options) {
        var opts = options || {};
        var entry = {
            op: op,
            params: params,
            key: opts.capture === true ? opts.key : params.task,
            capture: opts.capture === true,
            chain: opts.chain || "",
            command: ""
        };
        if (!versionOk) {
            root._reportFailure(entry, root._chainAware(entry, "no usable oxidone"));
            return;
        }
        if (root.applyQueueDepth >= root.applyQueueMax) {
            root._reportFailure(entry, root._chainAware(entry, "too many changes at once"));
            return;
        }
        try {
            entry.command = Apply.buildCommand(op, params);
        } catch (error) {
            // Our bug, not oxidone's refusal: a row without a list id, an op
            // this release does not send, or a field that op does not take.
            console.warn("oxidone: refusing to send", op, "-", error.message);
            root._reportFailure(entry, root._chainAware(entry, Apply.messageForExit(1)));
            return;
        }
        if (entry.capture) {
            // The capture's own record was made by `capture()` and is already
            // Pending; the chained set_due inherits it and keeps it that way.
            root._markCapturePending(entry.key);
        } else {
            root.clearApplyError(entry.key);
        }
        // A row op's Pending needs no write of its own: `applyPending` is
        // derived from this queue, so the push below is what raises it — and
        // keeps it raised while anything else here names the same row.
        root.applyQueue = root.applyQueue.concat([entry]);
        root.drainApply();
    }

    // A failure on the second half of a capture is not "could not reach Google"
    // — the entry exists by then, and saying only that would leave someone
    // looking for it in a Today it is not in.
    function _chainAware(entry, message) {
        if (entry.chain === "captured") {
            return Apply.halfCaptureMessage(root.listTitleFor(entry.params.list));
        }
        return message;
    }

    function _markCapturePending(key) {
        var record = root.captures[key];
        if (record === undefined) {
            return;
        }
        root._putCapture(key, { title: record.title, pending: true, message: "", seq: record.seq });
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

    // An Entry the Snapshot does not carry yet.
    //
    // `intoToday` is derived from what the op did, never from a `due <= today`
    // test here: a `create` is undated and so is in no Today at all, while the
    // `set_due` a Today capture chains sets the Snapshot's own date, putting the
    // Entry in Today by construction. The `settleToday` that follows is what
    // makes either reading self-correcting inside one read.
    function _foldInsert(echo, intoToday) {
        if (intoToday && root.payload !== null && root.payload !== undefined) {
            var today = {
                today: root.payload.today,
                entries: Apply.insertEntry(root.payload.entries, echo)
            };
            root.payload = today;
            root.outstanding = Today.outstandingCount(today);
            root.overdue = Today.hasOverdue(today);
        }
        // Only into the List the Entry is actually in: `patchEntries` can be
        // handed any Echo because it matches by id, but an insert would put one
        // List's new Entry under another List's name.
        if (root.listPayload !== null && root.listPayload !== undefined && root.listPayload.list === echo.list) {
            root.listPayload = {
                list: root.listPayload.list,
                entries: Apply.insertEntry(root.listPayload.entries, echo)
            };
        }
        root.applyGeneration += 1;
    }

    // The second half of a Today capture: date the Entry the `create` just made
    // with the Snapshot's own `today`, so it stays on the page it was typed on.
    function _chainCaptureDate(sent, echo) {
        if (root.payload === null || root.payload === undefined || typeof root.payload.today !== "string") {
            // No Today Snapshot to take a date from. The Entry is real and
            // undated, which is exactly what a half-capture is.
            console.warn("oxidone: captured with no today to date it by");
            root._reportFailure(sent, Apply.halfCaptureMessage(root.listTitleFor(echo.list)));
            return;
        }
        root.applyOp("set_due", { list: echo.list, task: echo.id, due: root.payload.today }, {
            capture: true,
            key: sent.key,
            chain: "captured"
        });
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
        // Every path out of the poll handler ends here, which makes this the one
        // place a deferred settle can be picked up.
        //
        // Cleared BEFORE the call, not by the poll it hopes to start: two of
        // `refresh`'s paths — a non-absolute path, and a binary that failed its
        // version check — come straight back here without starting anything, and
        // a flag still set on the way back in calls `refresh` again, forever.
        // That is a stack overflow inside the desktop shell. Dropping the settle
        // when there is no usable binary to ask costs nothing: there is no
        // answer to be had, and the next good poll is what supplies one.
        if (root.todayRepollWanted && !todayProc.running) {
            root.todayRepollWanted = false;
            root.refresh();
        }
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
                var answer = Today.parseLists(out);
                if (answer === null) {
                    // Refused whole. The selector keeps what it last knew and
                    // always keeps Today; a half-read list of lists would be a
                    // guess, and the Pane dereferences these inside a binding.
                    console.warn("oxidone: lists answer refused, keeping the selector as it was");
                    return;
                }
                root.lists = answer.lists;
                root.defaultList = answer.default_list;
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

    // The date Bridge. `json due` is a read — pure, no network, no credentials,
    // and refused before anything authorizes — so it costs a process and
    // nothing else.
    //
    // This is the one user-typed string this plugin puts in argv, because `json
    // due` takes its expression as an argument and there is no other route. A
    // date phrase is not a task title, the process lives milliseconds, and
    // oxidone's `json` arg parsing joins everything after the subcommand
    // verbatim, so a leading `-` is data rather than a flag. Nothing here runs
    // through a shell.
    BoundedProcess {
        id: dueProc
        // No `command` binding: `resolveAndSetDue` assigns it immediately before
        // starting, so the argv and the request it is guarded by come from one
        // read. See the note there.
        maxBytes: 4096
        deadlineMs: 10000
        onFinishedWith: function (out, err, code, tooLarge) {
            var asked = root.dueRequest;
            // Clearing this drops the row out of `applyPending` unless an Apply
            // still names it. On the success path below the row is put straight
            // back by the `set_due` this enqueues; both happen in one JS turn,
            // with no frame between them for the gap to be rendered in.
            root.dueRequest = null;
            if (asked === null) {
                return;
            }
            if (asked.epoch !== root.epoch) {
                console.warn("oxidone: due answered from a binary we no longer use");
                root.applyErrors = root._setApplyFlag(root.applyErrors, asked.task, Apply.messageForExit(1));
                return;
            }
            if (code !== 0 || tooLarge) {
                var kind = State.errorKindOf(err);
                console.warn("oxidone: due failed, exit", code, kind !== "" ? "(" + kind + ")" : "");
                // Exit 2 here is `invalid_due` and nothing else, which is worth
                // saying: the phrase was not a date, not malformed a request.
                root.applyErrors = root._setApplyFlag(root.applyErrors, asked.task, Apply.messageForExit(tooLarge ? 1 : code, "due"));
                return;
            }
            var due = Today.parseDue(out);
            if (due === null) {
                console.warn("oxidone: due answered with something unreadable");
                root.applyErrors = root._setApplyFlag(root.applyErrors, asked.task, Apply.messageForExit(1));
                return;
            }
            root.applyOp("set_due", { list: asked.list, task: asked.task, due: due });
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
            // This is also what stops a row op waiting: it leaves
            // `applyPending`, unless something still queued names the same row,
            // in which case the row stays Pending until that one answers too. A
            // capture is not in that set at all — its record may still have the
            // second half of a chain to run, and is settled where the chain is,
            // below.
            root.applyCurrent = null;
            applyProc.stdinPayload = "";
            if (sent === null) {
                // Defensive, and unreachable from outside this file: only
                // `drainApply` starts this process, and it sets `applyCurrent`
                // in the same breath. Kept anyway, because what it guards is
                // dereferencing null inside the desktop shell's own process —
                // and left untested on purpose, since a test would have to fake
                // a start the code has no way to perform.
                root.drainApply();
                return;
            }
            if (root.applyEpoch !== root.epoch) {
                // Started against a different binary. Whatever this answered, it
                // is not a word from the binary we talk to now: fold nothing and
                // say the change did not land.
                console.warn("oxidone: apply", sent.op, "answered from a binary we no longer use");
                root._reportFailure(sent, root._chainAware(sent, Apply.messageForExit(1)));
                root.drainApply();
                return;
            }

            if (code !== 0 || tooLarge) {
                // `tooLarge` reaches the message and stops there. The exit code
                // is oxidone's verdict on the request and stays true whether or
                // not its answer fit our buffer, so the branches below read it
                // raw: an overflowed exit 3 is still a grant that is gone, and
                // an overflowed exit 6 is still an Entry that is. Only what we
                // say is downgraded, because an overflowed body is one we could
                // not read.
                var kind = State.errorKindOf(err);
                // oxidone's own message goes here and nowhere else: it is
                // serde's sentence or Google's, not one to show a person.
                console.warn("oxidone: apply", sent.op, "failed, exit", code, kind !== "" ? "(" + kind + ")" : "");
                if (code === 6 && !sent.capture) {
                    // The row is gone from both Snapshots by the time
                    // _foldDeletion returns, so there is no row left to carry a
                    // message: the Pane looks errors up by row id, and this id no
                    // longer names one. The row's disappearance is the feedback.
                    // A capture has no such row — exit 6 there is a List that
                    // went, and it needs saying.
                    //
                    // `settleToday`, not `refresh`: the re-read has to survive a
                    // poll already being in flight, or "drop the row and read
                    // again" is only what happens when nothing else is running.
                    //
                    // That re-read is then a poll like any other, and one that
                    // fails raises `consecutiveFailures` and can set STALE. Not
                    // a contradiction of the note below: what went stale is the
                    // Today poll, genuinely, and this write is only what made it
                    // run now rather than on the clock.
                    root._foldDeletion(sent.params.task);
                    root.settleToday();
                } else {
                    root._reportFailure(sent, root._chainAware(sent, Apply.messageForExit(tooLarge ? 1 : code)));
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
                    root.applyErrors = root._setApplyFlag(root.applyErrors, sent.key, Apply.messageForExit(1));
                    root.drainApply();
                    return;
                }
                if (deleted.id !== sent.params.task || deleted.list !== sent.params.list) {
                    // Answered for an Entry we did not send. Folding this would
                    // remove the wrong row from both Snapshots — fail closed.
                    console.warn("oxidone: apply delete answered for a different entry than sent");
                    root.applyErrors = root._setApplyFlag(root.applyErrors, sent.key, Apply.messageForExit(1));
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
                root._reportFailure(sent, root._chainAware(sent, Apply.messageForExit(1)));
                root.drainApply();
                return;
            }

            if (sent.op === "create") {
                // Undated, so in no Today — into the open List only, if this is
                // the one. The chain, or the poll below, is what puts a Today
                // capture on screen.
                root._foldInsert(echo, false);
                if (sent.chain === "dueToday") {
                    root._chainCaptureDate(sent, echo);
                } else {
                    root._settleCapture(sent.key);
                }
                root.drainApply();
                return;
            }

            if (sent.chain === "captured") {
                // The date this set: the Snapshot's own `today`, chosen here.
                // So the Entry is in Today by construction rather than by a
                // local membership test, and the settle below confirms it.
                root._foldInsert(echo, true);
                root._settleCapture(sent.key);
                root.settleToday();
                root.drainApply();
                return;
            }

            // Migrate moves the due date to max(today, due) + 1 day, which is
            // always strictly after today — so a migrated Entry is always out of
            // Today. An Entry with no due date is never in Today at all, so
            // `clear_due` leaves it too. Both derived from what the op does,
            // deliberately not from a local `due <= today` test: that would put a
            // second definition of Today in the plugin, which is the thing
            // oxidone#137 removed.
            root._foldEcho(echo, sent.op === "migrate" || sent.op === "clear_due");
            if (sent.op === "set_due" || sent.op === "clear_due") {
                // Where a dated Entry belongs in Today, and in what order, is the
                // rule we do not keep a copy of. Ask.
                root.settleToday();
            }
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
