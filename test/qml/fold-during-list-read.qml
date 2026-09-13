import QtQuick
import Quickshell
import "src/state.js" as State

// Proves the List generation guard (Service.qml:150, `tasksApplyGeneration`,
// captured in `startListLoad()`; the discard itself is the
// `applyGeneration !== tasksApplyGeneration` check inside `tasksProc`'s
// `onFinishedWith`): an Apply that folds its Echo while a `json tasks --list`
// read is in flight must not have that Echo overwritten by that read's older
// answer. Unlike Today's twin, there is no clock behind a List read — a row
// this guard failed to protect would stay reverted until the scope changes
// or the pane reopens, not just for one poll cycle.
//
// Same shape as fold-during-today-poll.qml: the fake's `json tasks --list`
// answers at once on its first call — giving the Service a listPayload to
// fold into — and slow on every call after, touching a "started" file the
// instant that call begins and waiting on the Apply's own completion marker
// (not a fixed sleep — nothing about this race's timing is a guess) before
// touching a "done" file and answering. Two shell loops here wait on those
// files rather than reaching into Service's private process state; Quickshell
// reaps them along with every other child when the harness exits, so a
// marker that never arrives leaves nothing orphaned — only the deadlines
// below firing late. `json apply` always answers with the entry completed
// and marks its own completion; the slow `json tasks --list` always answers
// with that same entry still `needsAction` — the stale, pre-fold answer the
// guard must discard.
//
// `json today` is answered too (emptily) because `Component.onCompleted`
// inside Service.qml starts the ordinary poll regardless of what this test
// cares about; left unhandled it would just be a harmless STALE poll cycle,
// but answering it keeps the log free of noise this test does not assert on.
//
// Loaded from a temp config folder test/qml-harness.js builds, with
// Service.qml, BoundedProcess.qml and src/ symlinked in beside this file.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string startedMarker: Quickshell.env("OXIDONE_HARNESS_STARTED") || "/nonexistent/started"
    readonly property string doneMarker: Quickshell.env("OXIDONE_HARNESS_DONE") || "/nonexistent/done"
    readonly property string entryId: "entry-1"
    readonly property string listId: "L1"

    property bool firstLoadAsked: false
    property bool secondLoadAsked: false
    property bool applySent: false
    property bool reported: false

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        // List reads are on-demand, never polled — see `loadList`'s own
        // comment — so nothing asks for one until this harness does.
        onVersionOkChanged: {
            if (service.versionOk && !harness.firstLoadAsked) {
                harness.firstLoadAsked = true;
                service.loadList(harness.listId);
            }
        }

        // The first List read landing is what gives the Apply below
        // something to fold into. The moment it does, ask for a second read
        // of the same List — `loadList` starts a fresh one because
        // `tasksProc` is no longer running — and start waiting for that
        // read's own "started" marker.
        onListPayloadChanged: {
            if (!harness.secondLoadAsked && service.listPayload !== null) {
                harness.secondLoadAsked = true;
                service.loadList(harness.listId);
                startWait.start();
            }
        }
    }

    function currentEntry() {
        if (
            service.listPayload === null ||
            service.listPayload === undefined ||
            service.listPayload.entries.length === 0
        ) {
            return null;
        }
        return service.listPayload.entries[0];
    }

    // Only one of these ever gets to exit the process; whichever runs first
    // wins and the rest are no-ops.
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
            applyGeneration: service.applyGeneration,
        }));
        Qt.exit(code);
    }

    // Waits for the second `json tasks --list` to have actually begun —
    // its own sleep already ticking — before the Apply is allowed to fire.
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

    // Waits for the second `json tasks --list` to have fully answered — the
    // read whose answer must lose the race — so the report below is taken
    // only once `tasksProc.onFinishedWith` has actually run its discard
    // branch, not merely once the Apply's own fold has landed.
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
