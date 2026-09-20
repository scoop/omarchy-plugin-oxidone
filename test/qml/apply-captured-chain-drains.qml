import QtQuick
import Quickshell
import "src/state.js" as State

// Proves that the `chain === "captured"` success branch (Service.qml:945 —
// the second half of a Today capture, the `set_due` chained off a `create`)
// still calls `drainApply()`. Not a case in `apply-terminal-drains.qml`:
// reaching it needs a genuine two-step `create` → chained `set_due`, and the
// third, independently-queued Apply has to be enqueued only once that
// chained `set_due` is actually in flight — enqueued any earlier, it would
// sit ahead of the chain in FIFO order (the chain's own `applyOp()` call
// appends after) and run on the `create` step's drain instead, proving the
// wrong call site.
//
// One binary throughout — no swap needed here. The fake tells `create` from
// the chained `set_due` by the `op` field on stdin, answers `create` at
// once, and holds `set_due` open behind a marker file so the harness can
// enqueue the third Apply while the chain is genuinely still out.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string setDueEntered: Quickshell.env("OXIDONE_HARNESS_SET_DUE_ENTERED") || "/nonexistent/set-due-entered"
    readonly property string setDueRelease: Quickshell.env("OXIDONE_HARNESS_SET_DUE_RELEASE") || "/nonexistent/set-due-release"
    readonly property string listId: "L1"

    // Constant script, never interpolated: the marker path travels as `$1`
    // (positional args after the fourth array element), not pasted into the
    // string itself.
    readonly property string markerWaitScript: 'until [ -f "$1" ]; do sleep 0.02; done'

    property bool captured: false
    property bool thirdEnqueued: false
    property bool reported: false

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        // The first Today poll landing gives `_chainCaptureDate` a date to
        // use — without a Snapshot it refuses the chain and reports a
        // half-capture instead of reaching line 945 at all.
        onPayloadChanged: {
            if (!harness.captured && service.payload !== null) {
                harness.captured = true;
                service.capture("Dated capture", harness.listId, true);
                setDueEnteredWait.start();
            }
        }

        onApplyCurrentChanged: Qt.callLater(harness.checkDrained)
        onApplyQueueChanged: Qt.callLater(harness.checkDrained)
    }

    function checkDrained() {
        if (!harness.thirdEnqueued || harness.reported) {
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
            captureSettled: service.captures["capture:1"] === undefined,
        }));
        Qt.exit(code);
    }

    // Waits for the chained `set_due` to have genuinely started, then
    // enqueues the third, independent Apply while it is still out — behind
    // the chain in the queue, since the chain's own `set_due` is already
    // `applyCurrent` by this point.
    BoundedProcess {
        id: setDueEnteredWait
        command: ["sh", "-c", harness.markerWaitScript, "sh", harness.setDueEntered]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("set-due-entered-timed-out", 1);
                return;
            }
            harness.thirdEnqueued = true;
            service.applyOp("complete", { list: harness.listId, task: "task-third" });
            releaseSetDue.start();
        }
    }

    BoundedProcess {
        id: releaseSetDue
        command: ["touch", harness.setDueRelease]
        deadlineMs: 5000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("release-failed", 1);
            }
        }
    }

    Timer {
        id: ceiling
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report(harness.thirdEnqueued ? "timeout-after-third-enqueued" : "timeout-before-third-enqueued", 1)
    }
}
