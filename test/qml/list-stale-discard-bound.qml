import QtQuick
import Quickshell
import "src/state.js" as State

// Proves the bounded retry (Service.qml:754, `listStaleDiscards > 3`): a
// binary that keeps answering for the wrong list must stop being retried
// after 3 discards, not spin forever. Nothing in this harness ever calls
// `loadList` a second time — the only thing that can start another
// `json tasks --list` read here is `tasksProc.onFinishedWith`'s own retry —
// so once `listStaleDiscards` stops advancing, it structurally cannot
// advance again, and reporting the moment it crosses the bound needs no
// further wait to be a sound proof that it really has stopped.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"

    property bool started: false
    property bool reported: false

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        onVersionOkChanged: {
            if (service.versionOk && !harness.started) {
                harness.started = true;
                service.loadList("L1");
            }
        }

        // Deferred: `listStaleDiscards` is incremented before the
        // `> 3` check inside the same `onFinishedWith` call decides whether
        // to retry — a direct read here could observe the count mid-flight,
        // before that same call has finished deciding (and, for the
        // in-bound cases, before its own retry has actually started).
        onListStaleDiscardsChanged: Qt.callLater(harness.checkBound)
    }

    function checkBound() {
        if (harness.reported) {
            return;
        }
        if (service.listStaleDiscards > 3) {
            harness.report("gave-up", 0);
        }
    }

    function report(reason, code) {
        if (harness.reported) {
            return;
        }
        harness.reported = true;
        console.log("HARNESS " + JSON.stringify({
            reason: reason,
            listStaleDiscards: service.listStaleDiscards,
            listPayloadIsNull: service.listPayload === null,
        }));
        Qt.exit(code);
    }

    Timer {
        id: ceiling
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report("timeout", 1)
    }
}
