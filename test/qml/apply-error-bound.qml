import QtQuick
import Quickshell

// Proves `applyErrors` is bounded. The Service is `keepLoaded: true` — it runs
// for the life of the shell — and the only other thing that prunes this map is
// `retainErrorsAbsentFrom`, which clears a message when its Entry id comes back
// in a fresh answer. A message against an id that never comes back is kept
// until the shell stops, so a long run against a dead network must not be able
// to park one per row forever.
//
// Twelve failures against twelve ids, then read what is left: five, the newest,
// and the oldest gone. A refused date phrase is the shortest route to a
// recorded failure — it writes through `_putApplyError`, the same function
// every other message goes through, without needing a process to answer.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"

    readonly property int failures: 12

    property bool asked: false
    property var findings: ({})

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        onVersionOkChanged: {
            if (!service.versionOk || harness.asked) {
                return;
            }
            harness.asked = true;
            harness.probe();
            harness.report();
        }
    }

    function probe() {
        for (var i = 0; i < harness.failures; i++) {
            // An empty phrase is refused by `Rows.isDueExpr`, so each of these
            // records a message and starts no process.
            service.resolveAndSetDue("L1", "t" + i, "");
        }

        var kept = [];
        for (var id in service.applyErrors) {
            kept.push(id);
        }
        kept.sort();

        harness.findings = {
            kept: kept,
            keptCount: kept.length,
            max: service.applyErrorMax,
            orderLength: service.applyErrorOrder.length,
            oldestGone: service.applyErrors["t0"] === undefined,
            newestKept: service.applyErrors["t" + (harness.failures - 1)] === "not a date phrase"
        };
    }

    function report() {
        console.log("HARNESS " + JSON.stringify({
            reason: harness.asked ? "probed" : "never-vetted",
            findings: harness.findings
        }));
        Qt.exit(0);
    }

    Timer {
        interval: 15000
        repeat: false
        running: true
        onTriggered: harness.report()
    }
}
