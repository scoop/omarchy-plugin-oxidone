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
// until the harness explicitly releases it (`release-N`) — not a sleep — so
// the log has real timing in it rather than being an artifact of everything
// running too fast to tell anything apart.
//
// A broken guard here does not make two real processes overlap: `applyProc`
// is one `Process` instance, and its own `start()` no-ops while `running` is
// already true, so nothing can make a second child actually spawn while the
// first is still up. What it does instead — hand-traced against a scratch
// mutation that dropped the guard to just the empty-queue check — is
// silently reassign `applyCurrent`/`stdinPayload` to a later entry while an
// earlier one is still in flight, dropping the earlier entry outright. See
// the test file for which checks that failure mode actually trips.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string enteredPrefix: Quickshell.env("OXIDONE_HARNESS_ENTERED_PREFIX") || "/nonexistent/entered-"
    readonly property string releasePrefix: Quickshell.env("OXIDONE_HARNESS_RELEASE_PREFIX") || "/nonexistent/release-"
    readonly property string listId: "L1"
    readonly property int totalOps: 5

    // Constant script, never interpolated: the entered/release paths travel
    // as `$1`/`$2` (positional args after the fourth array element), not
    // pasted into the string itself. Shared by all five waits below.
    readonly property string releaseScript: 'until [ -f "$1" ]; do sleep 0.02; done; touch "$2"'

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
    // is only observable, per invocation, one at a time. Returns the two
    // positional arguments for `releaseScript` ($1, $2), not a script.
    function waitAndRelease(n) {
        return [harness.enteredPrefix + n, harness.releasePrefix + n];
    }

    BoundedProcess {
        id: step1
        command: ["sh", "-c", harness.releaseScript, "sh"].concat(harness.waitAndRelease(1))
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step1-timed-out", 1); return; }
            step2.start();
        }
    }
    BoundedProcess {
        id: step2
        command: ["sh", "-c", harness.releaseScript, "sh"].concat(harness.waitAndRelease(2))
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step2-timed-out", 1); return; }
            step3.start();
        }
    }
    BoundedProcess {
        id: step3
        command: ["sh", "-c", harness.releaseScript, "sh"].concat(harness.waitAndRelease(3))
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step3-timed-out", 1); return; }
            step4.start();
        }
    }
    BoundedProcess {
        id: step4
        command: ["sh", "-c", harness.releaseScript, "sh"].concat(harness.waitAndRelease(4))
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) { harness.report("step4-timed-out", 1); return; }
            step5.start();
        }
    }
    BoundedProcess {
        id: step5
        command: ["sh", "-c", harness.releaseScript, "sh"].concat(harness.waitAndRelease(5))
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
