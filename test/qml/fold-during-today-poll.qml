import QtQuick
import Quickshell
import "src/state.js" as State

// Proves the Today generation guard (Service.qml:145, `todayApplyGeneration`,
// captured in `refresh()` beside `todayEpoch`; the discard itself is the
// `applyGeneration !== todayApplyGeneration` check inside `todayProc`'s
// `onFinishedWith`): an Apply that folds its Echo while a `json today` read
// is in flight must not have that Echo overwritten by that read's older
// answer, AND the discard branch must still run the bookkeeping after it —
// `state = OK`, `lastSuccess = Date.now()`, `consecutiveFailures = 0`,
// `scheduleNext(0)` — that keeps the poll clock alive. A regression that adds
// an early `return` right after the discard's `console.warn` (the dead-poll-
// timer failure this guard exists to catch) would still leave the Echo
// intact, so that half needs its own proof independent of the Echo check.
//
// Three `json today` calls, not two, get there:
//   1. Succeeds at once, giving the Service a Snapshot — the Apply below has
//      nothing to fold into otherwise (`_foldEcho` no-ops when `payload` is
//      still null). This is also why the read that puts the guard under test
//      cannot itself be the first one, however tempting that shortcut looks.
//   2. Deliberately fails (exit 4), purely to drive `state` to `stale` and
//      `consecutiveFailures` to 1 *before* the race — a known "bad" baseline
//      the bookkeeping either does or doesn't move off of. Answering this
//      one plainly instead is indistinguishable from never having exercised
//      the tail at all: it would already read `ok` / 0 from call 1, and the
//      assertion would pass whether or not the discard branch's tail ever
//      ran.
//   3. Slow (no fixed sleep — it waits on the Apply's own completion marker,
//      so nothing here is a timing guess) and stale relative to the Echo
//      that folds while it is out. This is the read the guard is for.
//
// The fake touches a "started" file the instant call 3 begins and a "done"
// file the instant it is about to answer; two small shell loops here wait on
// those rather than reaching into Service's private process state, which is
// none of this harness's business. Quickshell reaps them along with every
// other child when the harness exits, so a marker that never arrives leaves
// nothing orphaned — only the deadlines below firing late.
//
// The fake's `json apply` always answers with the entry completed; its slow
// `json today` always answers with that same entry still `needsAction` — so
// if the poll's answer ever won the race, the row would revert, and this
// harness would see it by reading `status` back out of the Snapshot.
//
// Loaded from a temp config folder test/qml-harness.js builds, with
// Service.qml, BoundedProcess.qml and src/ symlinked in beside this file —
// see that driver's header for why the symlinks exist only for one run.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string startedMarker: Quickshell.env("OXIDONE_HARNESS_STARTED") || "/nonexistent/started"
    readonly property string doneMarker: Quickshell.env("OXIDONE_HARNESS_DONE") || "/nonexistent/done"
    readonly property string entryId: "entry-1"
    readonly property string listId: "L1"

    // Constant script, never interpolated: the marker path travels as `$1`
    // (positional args after the fourth array element), not pasted into the
    // string itself. Shared by both waits below — only the marker differs.
    readonly property string markerWaitScript: 'until [ -f "$1" ]; do sleep 0.02; done'

    property bool failureAsked: false
    property bool raceAsked: false
    property bool applySent: false
    property bool reported: false

    // Captured the moment `state` first goes `stale` — i.e. `lastSuccess` as
    // call 1 left it, untouched by call 2's failure. The final report's own
    // `lastSuccess` must be strictly newer than this for the bookkeeping to
    // have actually run during the race read's discard, rather than these
    // fields simply having been left at call 1's values all along.
    property double lastSuccessBeforeRace: -1

    Service {
        id: service
        binaryPath: harness.binary
        // Never fires inside the ceiling below: `State.nextDelaySeconds`
        // floors every interval at 60s. Every read past the first here is
        // asked for by `settleToday()` — the same path a `set_due` chains
        // off — not by this clock.
        pollIntervalSec: 3600

        // Call 1 landing is what gives the Apply below something to fold
        // into. The moment it does, ask for call 2 — the deliberate failure
        // that sets up a "bad" baseline for the bookkeeping proof.
        onPayloadChanged: {
            if (!harness.failureAsked && service.payload !== null) {
                harness.failureAsked = true;
                service.settleToday();
            }
        }

        // Call 2's failure is what drives `state` to `stale`. The moment it
        // does, capture the baseline and ask for call 3 — the slow, stale
        // read the guard is actually for — and start waiting for its
        // "started" marker.
        onStateChanged: {
            if (!harness.raceAsked && service.state === State.STALE) {
                harness.raceAsked = true;
                harness.lastSuccessBeforeRace = service.lastSuccess;
                service.settleToday();
                startWait.start();
            }
        }
    }

    function currentEntry() {
        if (service.payload === null || service.payload === undefined || service.payload.entries.length === 0) {
            return null;
        }
        return service.payload.entries[0];
    }

    // Only one of these ever gets to exit the process; whichever runs first
    // wins and the rest are no-ops, so a ceiling firing alongside a marker
    // wait cannot print two HARNESS lines.
    function report(reason, code) {
        if (harness.reported) {
            return;
        }
        harness.reported = true;
        var entry = harness.currentEntry();
        console.log("HARNESS " + JSON.stringify({
            reason: reason,
            state: service.state,
            status: entry !== null ? entry.status : "",
            outstanding: service.outstanding,
            consecutiveFailures: service.consecutiveFailures,
            lastSuccess: service.lastSuccess,
            lastSuccessBeforeRace: harness.lastSuccessBeforeRace,
            applyGeneration: service.applyGeneration,
        }));
        Qt.exit(code);
    }

    // Waits for call 3 to have actually begun — its own wait for the Apply's
    // completion marker already under way — before the Apply is allowed to
    // fire. Firing any earlier would race call 1 or call 2 instead of the
    // stale read the guard exists for.
    BoundedProcess {
        id: startWait
        command: ["sh", "-c", harness.markerWaitScript, "sh", harness.startedMarker]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("started-marker-timed-out", 1);
                return;
            }
            harness.applySent = true;
            service.applyOp("complete", { list: harness.listId, task: harness.entryId });
        }
    }

    // Waits for call 3 to have fully answered — the read whose answer must
    // lose the race — so the report below is taken only once
    // `todayProc.onFinishedWith` has actually run its discard branch, not
    // merely once the Apply's own fold has landed.
    BoundedProcess {
        id: doneWait
        command: ["sh", "-c", harness.markerWaitScript, "sh", harness.doneMarker]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("done-marker-timed-out", 1);
                return;
            }
            harness.report("settled", 0);
        }
    }

    Timer {
        id: ceiling
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report(harness.applySent ? "timeout-after-apply" : "timeout-before-apply", 1)
    }

    Component.onCompleted: doneWait.start()
}
