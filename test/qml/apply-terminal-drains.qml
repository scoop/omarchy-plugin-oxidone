import QtQuick
import Quickshell
import "src/state.js" as State

// Proves that every distinct terminal branch of `applyProc.onFinishedWith`
// (Service.qml:840) still calls `drainApply()` before returning. A branch
// that forgets to is silent: the row it answered gets its own message (or
// none), but the row *behind* it in the queue never runs, is never marked
// failed, and just sits Pending forever.
//
// One reusable harness, driven by which op (and, for a capture, which real
// `capture()` call) the first Apply is sent through, plus which `list` tag
// it carries — the fake binary reads that tag out of the command on its
// stdin and answers however the scenario needs. A second, ordinary Apply is
// queued right behind the first in the same synchronous burst
// (`apply-queue-cap.qml` already leans on the fact that neither can have
// been answered before this script returns control to Quickshell); if the
// first's branch drains, the second runs for real and the fake logs it.
//
// What this file does NOT cover:
//   - Service.qml:845 (`sent === null`): defensive. `applyCurrent` is only
//     ever non-null between a `drainApply()` call setting it and this same
//     handler clearing it at its own top, on the same `applyProc` — nothing
//     else assigns it or fires `finishedWith` in between. Forcing this path
//     would mean reaching into the Service's private process state rather
//     than driving it as a caller would, so it is left untested and
//     admitted as such here.
//   - Service.qml:861 (the epoch-drift discard's own drain): proven in
//     `apply-epoch-discard-drains.test.js`. That one needs `versionOk` to
//     be true again by the time the stale Apply answers — a different, more
//     specific setup than this harness's single always-vetted binary — so
//     it is its own scenario rather than a case bolted onto this one.
//   - Service.qml:945 (the `chain === "captured"` success): proven in
//     `apply-captured-chain-drains.test.js`. Reaching it needs a real
//     two-step `create` → chained `set_due`, and the queued Apply behind it
//     has to be enqueued only once that chain is genuinely in flight (else
//     it would run ahead of the chain, on the earlier `create` step's own
//     drain, and prove the wrong thing) — its own harness, not a case here.
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
                if (harness.firstOp === "capture") {
                    // The real capture() path: op "create", capture: true,
                    // key "capture:1" (captureSeq starts at 0, and nothing
                    // else in this harness calls capture() first).
                    service.capture("A captured task", harness.firstList, false);
                } else {
                    service.applyOp(harness.firstOp, { list: harness.firstList, task: "task-first" });
                }
                service.applyOp("complete", { list: "L1", task: "task-second" });
            }
        }

        // Deferred, not called straight from the signal: `applyCurrent` is
        // set to null at the very top of `onFinishedWith`, before that same
        // call goes on to fold the answer and set whatever error the branch
        // reports. A direct call here would read the report's fields
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
            firstCaptureSettled: service.captures["capture:1"] === undefined,
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
