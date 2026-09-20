import QtQuick
import Quickshell
import "src/state.js" as State

// Proves a child whose stderr outgrows its ceiling is refused, not shortened.
//
// stdout has always refused at the cap: an answer that outgrew its budget is
// not a value to salvage. stderr used to be truncated instead, which handed the
// caller a partial error envelope that looks whole and reads `tooLarge` as
// false — so an answer arriving alongside a runaway stderr was accepted as if
// nothing had gone wrong. The fake here writes a sound `json today` payload on
// stdout and far past `maxErrBytes` on stderr, and exits 0: with truncation the
// Snapshot fills, with a refusal the Service goes Stale and keeps nothing.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.
ShellRoot {
    id: harness

    readonly property string binary: Quickshell.env("OXIDONE_HARNESS_BIN") || "/nonexistent/oxidone"

    property bool reported: false

    Service {
        id: service
        binaryPath: harness.binary
        pollIntervalSec: 3600
    }

    function report(reason, code) {
        if (harness.reported) {
            return;
        }
        harness.reported = true;
        console.log("HARNESS " + JSON.stringify({
            reason: reason,
            state: service.state,
            payloadIsNull: service.payload === null,
            outstanding: service.outstanding
        }));
        Qt.exit(code);
    }

    // The poll is the only thing that can move `state` off OK here, and it runs
    // once: `pollIntervalSec` is an hour and nothing else asks for a read. So
    // Stale is terminal, and a ceiling that expires with the state still OK is
    // the truncating behaviour rather than a race.
    Timer {
        interval: 6000
        repeat: false
        running: true
        onTriggered: harness.report(service.state === State.STALE ? "refused" : "accepted", 0)
    }
}
