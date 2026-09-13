import QtQuick
import Quickshell
import "src/state.js" as State

// Drives the real Service through a binaryPath change and reports what it ended
// up believing. Run by test/service-version-gate.test.js, never by the shell —
// it is not part of the installable tree.
//
// It is loaded from a config folder the driver assembles in a temp directory,
// because `qs` refuses QML imports that resolve outside the folder it was given
// and the marketplace validator refuses symlinks anywhere in a plugin. So the
// symlinks that put Service.qml next to this file exist only while a test runs.
//
// The two binaries come from the environment. Everything else the test needs to
// know is in the log those fakes append to: which binary was asked what.
ShellRoot {
    id: harness

    // Never empty: an empty binaryPath sends the Service to the real installed
    // oxidone, and a test must not reach outside the directory the driver made
    // for it. A path that cannot exist fails the gate loudly instead.
    readonly property string first: Quickshell.env("OXIDONE_HARNESS_FIRST") || "/nonexistent/oxidone-first"
    readonly property string second: Quickshell.env("OXIDONE_HARNESS_SECOND") || "/nonexistent/oxidone-second"

    // Every fake answers `json today` with one entry named after itself, so the
    // Snapshot says which binary filled it without the harness reading the log.
    readonly property string firstEntry: "entry-first"
    readonly property string secondEntry: "entry-second"

    property bool swapped: false
    property int waitedMs: 0

    // Past any plausible process spawn, and far short of a wedged test sitting
    // in `bun test` until someone notices.
    readonly property int ceilingMs: 15000

    Service {
        id: service
        binaryPath: harness.first
        // The five-minute clock has no part in this: `State.nextDelaySeconds`
        // floors every interval at 60s, so nothing re-polls inside the ceiling.
        pollIntervalSec: 3600
    }

    // Which binary's answer the Snapshot is currently carrying, or "" for none.
    function snapshotEntry() {
        if (service.payload === null || service.payload === undefined) {
            return "";
        }
        if (service.payload.entries.length === 0) {
            return "";
        }
        return service.payload.entries[0].id;
    }

    function report(reason, code) {
        console.log("HARNESS " + JSON.stringify({
            reason: reason,
            state: service.state,
            versionOk: service.versionOk,
            entry: harness.snapshotEntry(),
        }));
        Qt.exit(code);
    }

    Timer {
        id: tick
        interval: 25
        repeat: true
        running: true
        onTriggered: {
            harness.waitedMs += tick.interval;
            if (harness.waitedMs > harness.ceilingMs) {
                harness.report(harness.swapped ? "timeout-after-swap" : "timeout-before-swap", 1);
                return;
            }
            if (!harness.swapped) {
                // Swap only once the first binary has been vetted *and* read
                // from: that is the state the defect needs to be reached from.
                if (harness.snapshotEntry() === harness.firstEntry) {
                    harness.swapped = true;
                    service.binaryPath = harness.second;
                }
                return;
            }
            // Either the replacement failed the gate, or it passed and its own
            // answer reached the Snapshot. Both are terminal; which one is
            // correct depends on the replacement, and the driver decides that.
            if (service.state === State.UNUSABLE) {
                harness.report("unusable", 0);
            } else if (harness.snapshotEntry() === harness.secondEntry) {
                harness.report("polled", 0);
            }
        }
    }
}
