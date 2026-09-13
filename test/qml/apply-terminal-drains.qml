import QtQuick
import Quickshell
import "src/state.js" as State

// Proves that every terminal branch of `applyProc.onFinishedWith`
// (Service.qml:840) still calls `drainApply()` before returning. A branch
// that forgets to is silent: the row it answered gets its own message (or
// none), but the row *behind* it in the queue never runs, is never marked
// failed, and just sits Pending forever.
//
// One reusable harness, driven by which op and which `list` tag the first
// Apply carries — the fake binary reads that tag out of the command on its
// stdin and answers however the scenario needs. A second, ordinary Apply is
// queued right behind the first in the same synchronous burst
// (`apply-queue-cap.qml` already leans on the fact that neither can have
// been answered before this script returns control to Quickshell); if the
// first's branch drains, the second runs for real and the fake logs it.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string firstOp: Quickshell.env("OXIDONE_HARNESS_FIRST_OP") || "complete"
    readonly property string firstList: Quickshell.env("OXIDONE_HARNESS_FIRST_LIST") || "scn-success"

    property bool enqueued: false
    property bool reported: false

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        onVersionOkChanged: {
            if (service.versionOk && !harness.enqueued) {
                harness.enqueued = true;
                service.applyOp(harness.firstOp, { list: harness.firstList, task: "task-first" });
                service.applyOp("complete", { list: "L1", task: "task-second" });
            }
        }

        // Deferred, not called straight from the signal: `applyCurrent` is
        // set to null at the very top of `onFinishedWith`, before that same
        // call goes on to clear `applyPending` and set whatever error the
        // branch reports. A direct call here would read the report's fields
        // mid-way through that function, before its own tail (`drainApply()`
        // among it) has run. `Qt.callLater` waits for the current call stack
        // — that whole `onFinishedWith` invocation — to finish unwinding
        // first.
        onApplyCurrentChanged: Qt.callLater(harness.checkDrained)
        onApplyQueueChanged: Qt.callLater(harness.checkDrained)
    }

    function checkDrained() {
        if (!harness.enqueued || harness.reported) {
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
            state: service.state,
            firstError: service.applyErrors["task-first"] || "",
            firstPending: service.applyPending["task-first"] === true,
            secondPending: service.applyPending["task-second"] === true,
        }));
        Qt.exit(code);
    }

    Timer {
        id: ceiling
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report(harness.enqueued ? "timeout-after-enqueue" : "timeout-before-enqueue", 1)
    }
}
