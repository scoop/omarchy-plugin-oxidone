import QtQuick
import Quickshell
import Quickshell.Io

// A child process whose output cannot outgrow a budget, whose environment is
// the one we chose rather than the one we inherited, and which cannot outlive
// its deadline.
//
// StdioCollector keeps everything the child writes and only then lets you
// measure it — by the time a length check runs the bytes are already in the
// shell's heap. This counts each chunk as it arrives, stops at the ceiling and
// kills the child rather than truncating: an answer that outgrew its budget is
// a refusal, not a value to salvage.
//
// The environment matters for the same reason the argv does. An inherited
// environment carries BASH_ENV, LD_PRELOAD and the proxy variables into every
// child, each of which lets another process running as this user decide what
// code runs or where a request goes. oxidone reads its config and token from
// under HOME and talks to Google over TLS; it needs nothing else from us.
Process {
    id: root

    /** Ceiling for everything the child writes to stdout, in characters. */
    property int maxBytes: 65536
    /** Ceiling for stderr. An error envelope is small; a crash dump is not. */
    property int maxErrBytes: 8192
    /** How long the child may run before it is taken down. */
    property int deadlineMs: 30000

    /** Emitted once per run, after the child has exited. */
    signal finishedWith(string stdoutText, string stderrText, int code, bool tooLarge)

    property string _out: ""
    property string _err: ""
    property bool _overflowed: false
    property bool _started: false
    property bool _finished: false
    property bool _wanted: false

    // Every termination path funnels through here, so `finishedWith` is emitted
    // exactly once per run however the run ended.
    function _finish(code) {
        if (_finished) {
            return;
        }
        _finished = true;
        _wanted = false;
        deadlineTimer.stop();
        killTimer.stop();
        root.finishedWith(_out, _err, code, _overflowed);
        _out = "";
        _err = "";
        _overflowed = false;
        _started = false;
    }

    function start() {
        _out = "";
        _err = "";
        _overflowed = false;
        _started = false;
        _finished = false;
        _wanted = true;
        deadlineTimer.restart();
        running = true;
    }

    clearEnvironment: true
    environment: ({
            // Fixed, absolute and short: nothing here resolves through a
            // directory another process can prepend to.
            PATH: "/usr/bin:/bin",
            HOME: Quickshell.env("HOME"),
            // oxidone reads XDG_CONFIG_HOME for its config and token when set.
            XDG_CONFIG_HOME: Quickshell.env("XDG_CONFIG_HOME"),
            // Byte semantics, and dates that do not depend on the shell's locale.
            LC_ALL: "C",
        })

    onStarted: {
        _started = true;
        _out = "";
        _err = "";
        _overflowed = false;
    }

    // Quickshell reports a failed exec by returning to not-running without ever
    // emitting `started` — verified empirically: a missing or non-executable
    // binary produces no `started` and no `exited` at all, so a caller waiting on
    // `finishedWith` would wait forever. Treat that transition as the failure it is.
    onRunningChanged: {
        if (!running && _wanted && !_started) {
            _finish(-1);
        }
    }

    stdout: SplitParser {
        // No marker: raw chunks. A line-delimited parser has to buffer until the
        // delimiter before it can hand anything over, so the ceiling would
        // arrive after the allocation it exists to prevent.
        splitMarker: ""
        onRead: function (chunk) {
            if (root._overflowed) {
                return;
            }
            if (root._out.length + chunk.length > root.maxBytes) {
                root._overflowed = true;
                root._out = "";
                root.signal(15);
                killTimer.restart();
                return;
            }
            root._out += chunk;
        }
    }

    stderr: SplitParser {
        splitMarker: ""
        onRead: function (chunk) {
            if (root._err.length >= root.maxErrBytes) {
                return;
            }
            root._err += chunk.slice(0, root.maxErrBytes - root._err.length);
        }
    }

    onExited: function (code) {
        _finish(code);
    }

    // Declared as properties rather than children: Process has no default
    // property, so it cannot hold one.

    // A poll nobody is waiting on still does not get to run forever.
    property Timer deadlineTimer: Timer {
        interval: root.deadlineMs
        repeat: false
        onTriggered: {
            if (!root._started) {
                root.running = false;
                root._finish(-1);
                return;
            }
            root.signal(15);
            killTimer.restart();
        }
    }

    // A child that ignores TERM does not get to keep running.
    property Timer killTimer: Timer {
        interval: 2000
        repeat: false
        onTriggered: root.signal(9)
    }
}
