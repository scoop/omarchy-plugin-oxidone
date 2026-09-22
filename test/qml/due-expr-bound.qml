import QtQuick
import Quickshell

// Proves the bound on the one string this plugin puts in an argument list.
//
// `Rows.isDueExpr` can say what a date phrase may look like; only the running
// Service can say whether a phrase it refuses really fails to reach
// `dueProc.command`. So this drives the real Service against a fake binary that
// logs every invocation, asks it to set three dates, and the driver reads the
// log for which of them actually ran.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"

    property bool asked: false
    property string longError: ""
    property string controlError: ""
    property string validError: ""

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600

        onVersionOkChanged: {
            if (!service.versionOk || harness.asked) {
                return;
            }
            harness.asked = true;
            harness.ask();
        }
    }

    // All three in one pass: `resolveAndSetDue` refuses a bad phrase before it
    // reaches the one-at-a-time gate, so a refusal must not consume the slot
    // the third call needs. Firing them back to back is what proves that.
    function ask() {
        // Well past the 128-character cap.
        var long = "";
        for (var i = 0; i < 200; i++) {
            long += "a";
        }
        service.resolveAndSetDue("L1", "t-long", long);
        harness.longError = service.applyErrors["t-long"] || "";

        // An escape, never a literal: a raw control byte in a source file is
        // what stops the marketplace's baseline scanner.
        service.resolveAndSetDue("L1", "t-control", "tomorrow\u0007rm");
        harness.controlError = service.applyErrors["t-control"] || "";

        // Legitimate oxidone syntax, and the case the review's `--` and
        // leading-`-` recommendation would have broken. It must still run.
        service.resolveAndSetDue("L1", "t-valid", "-3d");
        harness.validError = service.applyErrors["t-valid"] || "";
    }

    function report(reason, code) {
        console.log("HARNESS " + JSON.stringify({
            reason: reason,
            longError: harness.longError,
            controlError: harness.controlError,
            validError: harness.validError,
            askedAtAll: harness.asked
        }));
        Qt.exit(code);
    }

    // Long enough for the valid phrase's own `json due` to have run and been
    // logged; the driver's assertion is about what is in that log.
    Timer {
        interval: 4000
        repeat: false
        running: true
        onTriggered: harness.report(harness.asked ? "asked" : "never-vetted", 0)
    }
}
