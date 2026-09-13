import QtQuick
import Quickshell
import "src/state.js" as State

// Proves the queue cap (Service.qml:97, `applyQueueMax`; the check itself is
// `applyQueueDepth >= applyQueueMax` inside `applyOp`): the 33rd Apply queued
// while 32 are already accounted for (queued or in flight) must be refused
// with its row's error set, and the 32 that were accepted must still drain to
// completion — a refusal at the cap must not stop the drain, and must not
// itself count as a 33rd real invocation.
//
// All 33 `applyOp` calls happen inside one JS function, in one Quickshell
// event-loop turn: `drainApply` starts at most one real child per call, and
// that child cannot report back (there is no `onStarted`/`onFinishedWith`)
// until this function returns and the Qt event loop runs again. So the queue
// depth this loop sees is exactly what synchronous enqueuing built, not a
// race against anything — no marker file is needed to hold the count still.
//
// Loaded from a temp config folder test/qml-harness.js builds, with
// Service.qml, BoundedProcess.qml and src/ symlinked in beside this file.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string listId: "L1"
    // One past the cap: Service.qml:97's `applyQueueMax`.
    readonly property int totalOps: 33

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
                harness.checkDrained();
            }
        }

        onApplyCurrentChanged: harness.checkDrained()
        onApplyQueueChanged: harness.checkDrained()
    }

    // Drained means: nothing left in the queue, nothing in flight. Reachable
    // only through real signal handlers on the Service's own properties, so
    // there is nothing here to guess the timing of.
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
            capError: service.applyErrors["task-32"] || "",
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
