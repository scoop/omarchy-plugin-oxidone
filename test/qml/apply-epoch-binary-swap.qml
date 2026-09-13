import QtQuick
import Quickshell
import "src/state.js" as State

// One scenario, three guards. All three are facets of the same story — the
// binary gets replaced while an Apply is out — so this is one harness rather
// than three near-identical ones:
//
//   - `applyEpoch` vs `epoch` (Service.qml:141, the epoch-drift discard in
//     `applyProc.onFinishedWith`): the in-flight Apply's answer, once it
//     finally lands, must not be folded — it was sent to a binary we no
//     longer use.
//   - The queue held by `!versionOk` (Service.qml:476, inside `drainApply`):
//     the discard's own `drainApply()` call runs into that hold immediately,
//     since the new binary has not been vetted yet, so the two Applies
//     still queued behind the swapped one must sit untouched.
//   - `versionProc`'s success path (Service.qml:636) is the only thing that
//     calls `drainApply()` again afterwards — proven by releasing the new
//     binary's version check only once the held state above has actually
//     been observed, and watching the held Applies run only then.
//
// Three Applies are queued against the first binary while it is still
// vetted: the first is held open behind a marker file so the swap can happen
// while it is genuinely in flight, and the other two just queue up behind
// it — same synchronous-burst fact `apply-queue-cap.qml` and
// `apply-terminal-drains.qml` already lean on. The second binary's own
// version check is held open the same way, so "queue held" and "queue
// released" are each observed at a moment this script chose, not guessed at.
ShellRoot {
    id: harness

    readonly property string first: Quickshell.env("OXIDONE_HARNESS_FIRST") || "/nonexistent/oxidone-first"
    readonly property string second: Quickshell.env("OXIDONE_HARNESS_SECOND") || "/nonexistent/oxidone-second"
    readonly property string aEntered: Quickshell.env("OXIDONE_HARNESS_A_ENTERED") || "/nonexistent/a-entered"
    readonly property string aRelease: Quickshell.env("OXIDONE_HARNESS_A_RELEASE") || "/nonexistent/a-release"
    readonly property string bVersionRelease: Quickshell.env("OXIDONE_HARNESS_B_VERSION_RELEASE") || "/nonexistent/b-version-release"
    readonly property string listId: "L1"

    property bool enqueued: false
    property bool swapped: false
    property bool heldChecked: false
    property bool reported: false

    // Facts captured the instant the swap happens and the instant the held
    // state is confirmed — the report's proof that this actually went
    // through the sequence it claims to, not just that the end state happens
    // to look right.
    property int queueLengthAtSwap: -1
    property int queueLengthWhileHeld: -1
    property bool versionOkWhileHeld: true
    property string task1StatusWhileHeld: ""
    property string task1ErrorWhileHeld: ""

    Service {
        id: service
        binaryPath: harness.first
        pollIntervalSec: 3600

        // The first Today poll landing gives the Snapshot a `task-1` entry
        // to (not) fold into. Only then are the three Applies queued.
        onPayloadChanged: {
            if (!harness.enqueued && service.payload !== null) {
                harness.enqueued = true;
                service.applyOp("complete", { list: harness.listId, task: "task-1" });
                service.applyOp("complete", { list: harness.listId, task: "task-2" });
                service.applyOp("complete", { list: harness.listId, task: "task-3" });
                aEnteredWait.start();
            }
        }

        // `applyCurrent` going back to null is `onFinishedWith` having
        // started running for whatever was in flight — task-1's answer,
        // discarded or (if this guard is broken) folded. Deferred, not read
        // straight from the signal: `applyCurrent` is set to null at the
        // very top of `onFinishedWith`, before that same call goes on to
        // fold or discard and then call its own `drainApply()` — a direct
        // read here would observe things mid-flight rather than after that
        // whole call has settled. One dispatcher handles both checkpoints,
        // since which one is still pending is exactly what `heldChecked`
        // records.
        onApplyCurrentChanged: Qt.callLater(harness.onServiceSettled)
        onApplyQueueChanged: Qt.callLater(harness.onServiceSettled)
    }

    function onServiceSettled() {
        if (!harness.heldChecked) {
            harness.checkHeld();
        } else {
            harness.checkDrained();
        }
    }

    function currentTask1Status() {
        if (service.payload === null || service.payload === undefined) {
            return "";
        }
        for (var i = 0; i < service.payload.entries.length; i++) {
            if (service.payload.entries[i].id === "task-1") {
                return service.payload.entries[i].status;
            }
        }
        return "";
    }

    function checkHeld() {
        // Not yet swapped: this is `applyCurrent`/`applyQueue` settling from
        // ordinary enqueue traffic, not from task-1's answer landing.
        if (!harness.swapped || harness.heldChecked) {
            return;
        }
        // task-1 is still out there (still running, or its own
        // `onFinishedWith` has not reached this point yet).
        if (service.applyCurrent !== null) {
            return;
        }
        harness.heldChecked = true;
        harness.queueLengthWhileHeld = service.applyQueue.length;
        harness.versionOkWhileHeld = service.versionOk;
        harness.task1StatusWhileHeld = harness.currentTask1Status();
        harness.task1ErrorWhileHeld = service.applyErrors["task-1"] || "";
        // Now that the held state has actually been observed, let the new
        // binary's version check answer — its success path is the only
        // thing that releases the held queue.
        releaseB.start();
        // If the hold is broken, the queue may already have fully drained
        // by the time this runs (nothing left to hold back with) — in
        // which case no further `applyCurrent`/`applyQueue` change will
        // ever come along to trigger `checkDrained` on its own.
        harness.checkDrained();
    }

    function checkDrained() {
        if (!harness.heldChecked || harness.reported) {
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
            queueLengthAtSwap: harness.queueLengthAtSwap,
            queueLengthWhileHeld: harness.queueLengthWhileHeld,
            versionOkWhileHeld: harness.versionOkWhileHeld,
            task1StatusWhileHeld: harness.task1StatusWhileHeld,
            task1ErrorWhileHeld: harness.task1ErrorWhileHeld,
            finalTask1Status: harness.currentTask1Status(),
            versionOk: service.versionOk,
            state: service.state,
        }));
        Qt.exit(code);
    }

    // Waits for the first Apply to have genuinely started against the first
    // binary, then swaps `binaryPath` while it is still out there running —
    // the epoch bump and `versionOk = false` both happen synchronously,
    // inside this same handler, before anything else gets a chance to run.
    BoundedProcess {
        id: aEnteredWait
        command: ["sh", "-c", "until [ -f \"" + harness.aEntered + "\" ]; do sleep 0.02; done"]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("a-entered-timed-out", 1);
                return;
            }
            harness.queueLengthAtSwap = service.applyQueue.length;
            harness.swapped = true;
            service.binaryPath = harness.second;
            releaseA.start();
        }
    }

    // Lets the first binary's Apply finish and answer — an Echo that would
    // complete `task-1` if it were ever folded.
    BoundedProcess {
        id: releaseA
        command: ["touch", harness.aRelease]
        deadlineMs: 5000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("a-release-failed", 1);
            }
            // `checkHeld` is wired to `applyErrors`, not to this process.
        }
    }

    // Only touched once `checkHeld` has already read the held state back out
    // of the Service — see the note on `onApplyErrorsChanged`.
    BoundedProcess {
        id: releaseB
        command: ["touch", harness.bVersionRelease]
        deadlineMs: 5000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("b-release-failed", 1);
            }
        }
    }

    Timer {
        id: ceiling
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report(harness.heldChecked ? "timeout-after-held" : (harness.swapped ? "timeout-after-swap" : "timeout-before-swap"), 1)
    }
}
