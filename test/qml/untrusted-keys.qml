import QtQuick
import Quickshell

// Proves that the Service's id-keyed maps answer for the key that was put in
// them and for no other.
//
// Every key in `applyErrors`, `applyPending` and `captures` is a string
// oxidone printed. On a plain object `applyErrors["constructor"]` is Object's
// constructor and `applyErrors["__proto__"]` is Object's prototype, so the
// Pane's `applyErrors[row.id] !== undefined` reads true for a row nothing has
// failed on and draws a stringified function as its failure message. The maps
// are `Object.create(null)`; this is what says so under a real Quickshell,
// after the maps have been rebuilt by the real `_setApplyFlag`.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"

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

    // A refused date phrase is the shortest route to a recorded failure: it
    // writes through `_setApplyFlag`, the same function every other message
    // goes through, without needing a process to answer first.
    function probe() {
        service.resolveAndSetDue("L1", "t-real", "");

        var before = {
            constructorKey: service.applyErrors["constructor"] === undefined,
            protoKey: service.applyErrors["__proto__"] === undefined,
            toStringKey: service.applyErrors["toString"] === undefined,
            pendingConstructorKey: service.applyPending["constructor"] === undefined,
            capturesConstructorKey: service.captures["constructor"] === undefined
        };

        // And the other direction: an entry really called `constructor` must
        // still be able to carry a message, and to have it cleared again.
        service.resolveAndSetDue("L1", "constructor", "");
        before.constructorCarriesItsOwn = service.applyErrors["constructor"] === "not a date phrase";
        before.realOneUntouched = service.applyErrors["t-real"] === "not a date phrase";
        service.clearApplyError("constructor");
        before.constructorClears = service.applyErrors["constructor"] === undefined;
        before.realOneStillThere = service.applyErrors["t-real"] === "not a date phrase";

        harness.findings = before;
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
