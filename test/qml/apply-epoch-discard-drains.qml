import QtQuick
import Quickshell
import "src/state.js" as State

// Proves that the epoch-drift discard's OWN `drainApply()` call
// (Service.qml:861) is load-bearing — not `apply-epoch-binary-swap.qml`'s
// job, which proves the discard itself (nothing folds) and the version-gate
// hold, but deliberately leaves `versionOk` false the whole time, which
// makes line 861's call a no-op there (blocked by drainApply's own
// `!versionOk` check) and the real release come from `versionProc` instead.
//
// Line 861 only does something while `versionOk` is back to true by the
// time the stale Apply's answer lands — epoch drift and an unvetted binary
// are two different facts that happen to coincide right after a swap, not
// the same fact. So: swap to the new binary, let ITS version check pass
// first, and only then let the OLD binary's still-in-flight Apply answer.
// By that point `applyEpoch !== epoch` (it was sent before the swap) AND
// `versionOk === true` (the new binary already passed), so the discard
// branch's own `drainApply()` is the only thing that can start what is
// queued behind it — nothing else runs between the swap and this point to
// do it first.
ShellRoot {
    id: harness

    readonly property string first: Quickshell.env("OXIDONE_HARNESS_FIRST") || "/nonexistent/oxidone-first"
    readonly property string second: Quickshell.env("OXIDONE_HARNESS_SECOND") || "/nonexistent/oxidone-second"
    readonly property string aEntered: Quickshell.env("OXIDONE_HARNESS_A_ENTERED") || "/nonexistent/a-entered"
    readonly property string aRelease: Quickshell.env("OXIDONE_HARNESS_A_RELEASE") || "/nonexistent/a-release"
    readonly property string listId: "L1"

    // Constant script, never interpolated: the marker path travels as `$1`
    // (positional args after the fourth array element), not pasted into the
    // string itself.
    readonly property string markerWaitScript: 'until [ -f "$1" ]; do sleep 0.02; done'

    property bool aVetted: false
    property bool swapped: false
    property bool bVetted: false
    property bool reported: false

    Service {
        id: service
        binaryPath: harness.first
        pollIntervalSec: 3600

        onVersionOkChanged: {
            if (!service.versionOk) {
                return;
            }
            if (!harness.aVetted) {
                // The first binary is vetted: queue three Applies against
                // it. The first starts immediately and holds open; the
                // other two just queue up behind it.
                harness.aVetted = true;
                service.applyOp("complete", { list: harness.listId, task: "task-1" });
                service.applyOp("complete", { list: harness.listId, task: "task-2" });
                service.applyOp("complete", { list: harness.listId, task: "task-3" });
                aEnteredWait.start();
            } else if (harness.swapped && !harness.bVetted) {
                // The second binary is vetted, and `versionProc`'s own
                // `drainApply()` call just ran — a no-op, since `task-1` is
                // still the one running, still against the first binary,
                // still blocked on its release marker. `versionOk` is now
                // true, and nothing else will touch the queue again except
                // whatever `task-1`'s own eventual answer triggers.
                harness.bVetted = true;
                releaseA.start();
            }
        }

        onApplyCurrentChanged: Qt.callLater(harness.checkDrained)
        onApplyQueueChanged: Qt.callLater(harness.checkDrained)
    }

    function checkDrained() {
        if (!harness.bVetted || harness.reported) {
            return;
        }
        if (service.applyCurrent === null && service.applyQueue.length === 0) {
            harness.report("drained", 0);
        }
    }

    function report(reason, code) {
        if (harness.reported) {
            return;
        }
        harness.reported = true;
        console.log("HARNESS " + JSON.stringify({
            reason: reason,
            versionOk: service.versionOk,
            queueLength: service.applyQueue.length,
            currentNull: service.applyCurrent === null,
        }));
        Qt.exit(code);
    }

    // Waits for `task-1` to have genuinely started against the first
    // binary, then swaps — the epoch bump and `versionOk = false` both
    // happen synchronously, inside this same handler.
    BoundedProcess {
        id: aEnteredWait
        command: ["sh", "-c", harness.markerWaitScript, "sh", harness.aEntered]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("a-entered-timed-out", 1);
                return;
            }
            harness.swapped = true;
            service.binaryPath = harness.second;
        }
    }

    // Only touched once the second binary's own version check has already
    // succeeded — see the note on `onVersionOkChanged`.
    BoundedProcess {
        id: releaseA
        command: ["touch", harness.aRelease]
        deadlineMs: 5000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("a-release-failed", 1);
            }
        }
    }

    Timer {
        id: ceiling
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report(harness.bVetted ? "timeout-after-b-vetted" : (harness.swapped ? "timeout-after-swap" : "timeout-before-swap"), 1)
    }
}
