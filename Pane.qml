import QtQuick

// Placeholder for the real overlay (Tasks 3-7). It already satisfies the
// shell's contract — open/close/opened — so `toggle` resolves rather than
// logging "no live bar widget", and so the manifest validates.
Item {
    id: root

    property var service: null
    property var shell: null
    property var manifest: null

    property bool opened: false

    function open(payloadJson) {
        root.opened = true;
    }

    function close() {
        root.opened = false;
    }
}
