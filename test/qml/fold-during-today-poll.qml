import QtQuick
import Quickshell
import "src/state.js" as State

// Proves the Today generation guard (Service.qml:145, `todayApplyGeneration`,
// captured in `refresh()` beside `todayEpoch`; the discard itself is the
// `applyGeneration !== todayApplyGeneration` check inside `todayProc`'s
// `onFinishedWith`): an Apply that folds its Echo while a `json today` read
// is in flight must not have that Echo overwritten by that read's older
// answer.
//
// The fake binary answers `json today` at once on its first call — giving
// the Service a Snapshot for the Apply below to fold into — and slow (a
// `sleep`) on every call after, touching a "started" file the instant that
// call begins and a "done" file the instant it is about to answer. Two small
// shell loops here wait on those files rather than reaching into Service's
// private process state, which is none of this harness's business: one
// releases the Apply the moment the stale read is actually in flight, the
// other tells the harness when that read has been fully handled — payload,
// outstanding, state, lastSuccess and consecutiveFailures all take their
// final value inside `todayProc.onFinishedWith`, synchronously, so once its
// process has visibly finished there is nothing left to wait for.
//
// The fake's `json apply` always answers with the entry completed; its
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

    property bool secondPollAsked: false
    property bool applySent: false
    property bool reported: false

    Service {
        id: service
        binaryPath: harness.binary
        // Never fires inside the ceiling below: `State.nextDelaySeconds`
        // floors every interval at 60s. The second `json today` read is
        // asked for by `settleToday()` — the same path a `set_due` chains
        // off — not by this clock.
        pollIntervalSec: 3600

        // The first poll landing is what gives the Apply below something to
        // fold into. The moment it does, ask for a second read and start
        // waiting for that read's own "started" marker.
        onPayloadChanged: {
            if (!harness.secondPollAsked && service.payload !== null) {
                harness.secondPollAsked = true;
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
            applyGeneration: service.applyGeneration,
        }));
        Qt.exit(code);
    }

    // Waits for the second `json today` to have actually begun — its own
    // sleep already ticking — before the Apply is allowed to fire. Firing
    // any earlier would race an ordinary fast poll instead of the slow one
    // the guard exists for.
    BoundedProcess {
        id: startWait
        command: ["sh", "-c", "until [ -f \"" + harness.startedMarker + "\" ]; do sleep 0.02; done"]
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

    // Waits for the second `json today` to have fully answered — the read
    // whose answer must lose the race — so the report below is taken only
    // once `todayProc.onFinishedWith` has actually run its discard branch,
    // not merely once the Apply's own fold has landed.
    BoundedProcess {
        id: doneWait
        command: ["sh", "-c", "until [ -f \"" + harness.doneMarker + "\" ]; do sleep 0.02; done"]
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
