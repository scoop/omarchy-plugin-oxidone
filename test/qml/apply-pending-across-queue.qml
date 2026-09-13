import QtQuick
import Quickshell

// Proves that a row stays Pending for as long as *any* Apply naming it is
// outstanding — issue #5, deferred from slice 3.
//
// Two Applies are enqueued against the same task id in one synchronous burst,
// before either can have been answered (Quickshell's Process cannot report
// `finishedWith` back into this script until the current JS turn ends, the
// same fact `apply-queue-cap.qml` and `apply-one-in-flight.qml` lean on). The
// first is answered at once; the second's real invocation is held open behind
// a marker file until this harness releases it — not a sleep — so Pending can
// be sampled while it is genuinely in flight.
//
// Three observations, because the failure has two distinct faces:
//
//   - `clearedEarly` watches every value `applyPending` takes and records the
//     defect itself: the set losing this row while an Apply naming it is still
//     queued or in flight. That is exactly what the old hand-written flag did
//     the moment the first Apply was answered, and it is a fact about the
//     transition rather than about any one reading of it.
//   - `pendingWhileSecondInFlight` is read from an independent turn of the
//     event loop, once the second invocation has been observed to start and
//     before it is released. Nothing of the Service's is on the stack, so this
//     is what the Pane would actually render.
//   - `pendingAfterDrain` is read from a turn of its own too, after the queue
//     has emptied. It must be false: a flag that is never cleared would satisfy
//     both checks above and strand the row muted and non-interactive.
//
// Both readings are deliberately taken outside the Service's own signal
// handlers. Whether a binding has already been re-evaluated partway through
// the handler that invalidated it is a question about notification order, not
// about this fix, and a sample that depends on the answer proves nothing.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string enteredSecond: Quickshell.env("OXIDONE_HARNESS_ENTERED_SECOND") || "/nonexistent/entered-2"
    readonly property string releaseSecond: Quickshell.env("OXIDONE_HARNESS_RELEASE_SECOND") || "/nonexistent/release-2"
    readonly property string listId: "L1"
    readonly property string taskId: "task-dup"

    property bool enqueued: false
    property bool reported: false
    property bool clearedEarly: false

    // Null until sampled, so a sample that never happened cannot be mistaken
    // for one that came back false.
    property var pendingWhileSecondInFlight: null
    property var pendingAfterDrain: null

    function pendingNow() {
        return service.applyPending[harness.taskId] === true;
    }

    function outstanding() {
        return service.applyCurrent !== null || service.applyQueue.length > 0;
    }

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        onVersionOkChanged: {
            if (service.versionOk && !harness.enqueued) {
                harness.enqueued = true;
                // One burst, same row: the second is still queued when the
                // first is answered.
                service.applyOp("complete", { list: harness.listId, task: harness.taskId });
                service.applyOp("migrate", { list: harness.listId, task: harness.taskId });
            }
        }

        onApplyPendingChanged: {
            if (harness.enqueued && !harness.pendingNow() && harness.outstanding()) {
                harness.clearedEarly = true;
            }
        }

        onApplyCurrentChanged: {
            if (service.applyCurrent !== null) {
                // Started once, on the first Apply: the marker it waits for is
                // only touched by the *second* real invocation, so this fires
                // exactly when that one is up and blocked.
                if (!waitForSecond.running && harness.pendingWhileSecondInFlight === null) {
                    waitForSecond.start();
                }
                return;
            }
            harness.checkDrained();
        }

        onApplyQueueChanged: harness.checkDrained()
    }

    function checkDrained() {
        if (!harness.enqueued || harness.reported || settle.running) {
            return;
        }
        if (service.applyCurrent === null && service.applyQueue.length === 0) {
            settle.start();
        }
    }

    // A turn of its own, so the last reading is not taken from inside the
    // handler that emptied the queue.
    Timer {
        id: settle
        interval: 1
        repeat: false
        onTriggered: {
            harness.pendingAfterDrain = harness.pendingNow();
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
            clearedEarly: harness.clearedEarly,
            pendingWhileSecondInFlight: harness.pendingWhileSecondInFlight,
            pendingAfterDrain: harness.pendingAfterDrain,
            queueLength: service.applyQueue.length,
            currentNull: service.applyCurrent === null,
        }));
        Qt.exit(code);
    }

    BoundedProcess {
        id: waitForSecond
        command: ["sh", "-c", "until [ -f \"" + harness.enteredSecond + "\" ]; do sleep 0.02; done"]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("second-never-started", 1);
                return;
            }
            // Still blocked in the fake, and nothing of the Service's is on the
            // stack: this is the reading the Pane would get.
            harness.pendingWhileSecondInFlight = harness.pendingNow();
            releaseSecondProc.start();
        }
    }

    BoundedProcess {
        id: releaseSecondProc
        command: ["touch", harness.releaseSecond]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("release-failed", 1);
            }
            // Success falls through to `checkDrained`, already wired to the
            // Service's own signals.
        }
    }

    Timer {
        id: ceiling
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report(harness.enqueued ? "timeout-after-enqueue" : "timeout-before-enqueue", 1)
    }
}
