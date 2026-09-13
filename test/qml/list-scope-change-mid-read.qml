import QtQuick
import Quickshell
import "src/state.js" as State

// Proves the List scope guard (Service.qml:229, `listRequestedId` vs
// `listId`; the discard/re-request lives in `tasksProc.onFinishedWith`'s
// `payload.list !== root.listId` check): changing scope while a
// `json tasks --list` read is out must discard that read's answer — it
// named the list that was asked for, not the one now wanted — and then
// actually request the list that is now wanted, rather than leaving the
// Pane stuck on stale data with no read in flight to fix it.
//
// The fake's one `json tasks --list L1` call holds open behind a marker file
// until released, so the scope change below happens while that read is
// genuinely still out, not merely queued up before it started.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"
    readonly property string l1Entered: Quickshell.env("OXIDONE_HARNESS_L1_ENTERED") || "/nonexistent/l1-entered"
    readonly property string l1Release: Quickshell.env("OXIDONE_HARNESS_L1_RELEASE") || "/nonexistent/l1-release"

    property bool started: false
    property bool scopeChanged: false
    property bool reported: false

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        onVersionOkChanged: {
            if (service.versionOk && !harness.started) {
                harness.started = true;
                service.loadList("L1");
                l1EnteredWait.start();
            }
        }

        onListPayloadChanged: harness.checkSettled()
    }

    function checkSettled() {
        if (harness.reported || !harness.scopeChanged) {
            return;
        }
        if (service.listPayload !== null && service.listPayload.list === "L2") {
            harness.report("settled", 0);
        }
    }

    function report(reason, code) {
        if (harness.reported) {
            return;
        }
        harness.reported = true;
        console.log("HARNESS " + JSON.stringify({
            reason: reason,
            listPayloadList: service.listPayload !== null ? service.listPayload.list : "",
            listStaleDiscards: service.listStaleDiscards,
            listId: service.listId,
        }));
        Qt.exit(code);
    }

    // Waits for the L1 read to have genuinely started, then changes scope
    // while it is still out there — the exact race the guard exists for —
    // and only after that releases it, so the answer that lands really was
    // gathered under the old scope.
    BoundedProcess {
        id: l1EnteredWait
        command: ["sh", "-c", "until [ -f \"" + harness.l1Entered + "\" ]; do sleep 0.02; done"]
        deadlineMs: 8000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("l1-entered-timed-out", 1);
                return;
            }
            harness.scopeChanged = true;
            service.loadList("L2");
            releaseL1.start();
        }
    }

    BoundedProcess {
        id: releaseL1
        command: ["touch", harness.l1Release]
        deadlineMs: 5000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0) {
                harness.report("l1-release-failed", 1);
            }
        }
    }

    Timer {
        id: ceiling
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report(harness.scopeChanged ? "timeout-after-scope-change" : "timeout-before-scope-change", 1)
    }
}
