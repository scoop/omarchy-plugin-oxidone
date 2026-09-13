import QtQuick
import Quickshell
import "src/state.js" as State

// Proves the one-in-flight property (Service.qml:472, `drainApply`): it must
// start nothing new while `applyCurrent !== null` or `applyProc.running`.
// Everything else in the ordering argument — the cap, the terminal-branch
// drain, the version-gate hold — depends on this being true, so it gets its
// own harness rather than being taken on faith from the others.
//
// Five Applies are queued in one synchronous burst, before any of them can
// possibly have been answered — Quickshell's Process cannot report
// `finishedWith` back into this script until the current JS turn ends and the
// event loop runs again, the same fact `apply-queue-cap.qml` leans on. The
// fake holds each real invocation open behind a marker file (`entered-N`)
// until the harness explicitly releases it (`release-N`) — not a sleep, and
// not merely "fast enough that nothing could overlap by luck": the fake is
// deliberately kept alive so a broken guard has time to attempt a second
// start while the first is still up, and the log would show it.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string enteredPrefix: Quickshell.env("OXIDONE_HARNESS_ENTERED_PREFIX") || "/nonexistent/entered-"
    readonly property string releasePrefix: Quickshell.env("OXIDONE_HARNESS_RELEASE_PREFIX") || "/nonexistent/release-"
    readonly property string listId: "L1"
    readonly property int totalOps: 5

    property bool enqueued: false
    property bool reported: false

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        onVersionOkChanged: {
            if (service.versionOk && !harness.enqueued) {
                harness.enqueued = true;
                for (var i = 0; i < harness.totalOps; i++) {
                    service.applyOp("complete", { list: harness.listId, task: "task-" + i });
                }
                step1.start();
            }
        }

        onApplyCurrentChanged: harness.checkDrained()
        onApplyQueueChanged: harness.checkDrained()
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
            queueLength: service.applyQueue.length,
            currentNull: service.applyCurrent === null,
        }));
        Qt.exit(code);
    }

    // Waits for real invocation N to have logged its "entered" marker, then
    // releases it. Chained rather than parallel, so invocation N+1's release
    // is never even attempted until N is confirmed to have started — which
    // is only observable, per invocation, one at a time.
    function waitAndRelease(n) {
        return "until [ -f \"" + harness.enteredPrefix + n + "\" ]; do sleep 0.02; done; touch \"" + harness.releasePrefix + n + "\"";
    }

    BoundedProcess {
        id: step1
        command: ["sh", "-c", harness.waitAndRelease(1)]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step1-timed-out", 1); return; }
            step2.start();
        }
    }
    BoundedProcess {
        id: step2
        command: ["sh", "-c", harness.waitAndRelease(2)]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step2-timed-out", 1); return; }
            step3.start();
        }
    }
    BoundedProcess {
        id: step3
        command: ["sh", "-c", harness.waitAndRelease(3)]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step3-timed-out", 1); return; }
            step4.start();
        }
    }
    BoundedProcess {
        id: step4
        command: ["sh", "-c", harness.waitAndRelease(4)]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step4-timed-out", 1); return; }
            step5.start();
        }
    }
    BoundedProcess {
        id: step5
        command: ["sh", "-c", harness.waitAndRelease(5)]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step5-timed-out", 1); }
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
