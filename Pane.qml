import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The overlay: a full-screen scrim with a card in the middle, summoned by the
// Indicator's click or by `omarchy-shell shell toggle scoop.oxidone`.
//
// The root is a plain Item, not the window. The manifest keeps this component
// loaded for the life of the shell, so the surface below is created once and
// only shown and hidden — closing is not a teardown, and the Service's poll
// carries on regardless of whether anyone is looking.
Item {
    id: root

    // Injected by the shell's panel loader when the properties exist.
    property var service: null
    property var shell: null
    property var manifest: null

    // The three members the shell's summon path is defined in terms of.
    property bool opened: false

    function open(payloadJson) {
        root.opened = true;
        // The window and its content need a layout pass before focus will
        // land, which is why this is deferred rather than called outright.
        Qt.callLater(function () {
            keys.forceActiveFocus();
        });
    }

    function close() {
        root.opened = false;
    }

    function toggle() {
        if (root.opened) {
            root.close();
        } else {
            root.open("{}");
        }
    }

    readonly property string state: service ? service.state : "ok"

    PanelWindow {
        id: panel
        visible: root.opened
        color: "transparent"

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        // Exclusive keyboard focus: while the pane is up it owns the keyboard,
        // so a keystroke meant for a row can never land in the window behind.
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Rectangle {
            anchors.fill: parent
            color: Color.menu.scrim
        }

        // Clicking away closes. The card swallows its own clicks below, so this
        // only ever sees the space around it.
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        BorderSurface {
            id: card
            anchors.centerIn: parent
            // A target size, clamped so it never overflows a small display.
            width: Math.min(Style.space(460), panel.width - Style.space(40))
            height: Math.min(Style.space(540), panel.height - Style.space(40))
            color: Color.menu.background
            borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

            MouseArea {
                anchors.fill: parent
                // Present only to stop a click on the card reaching the
                // dismiss handler behind it.
                onClicked: {}
            }

            PanelKeyCatcher {
                id: keys
                anchors.fill: parent
                onCloseRequested: root.close()
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Style.spacing.panelPadding
                spacing: Style.spacing.panelGap

                PanelSectionHeader {
                    Layout.fillWidth: true
                    text: "Today"
                    textFormat: Text.PlainText
                }

                Item {
                    id: content
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }

                PanelSeparator {
                    Layout.fillWidth: true
                }

                Text {
                    Layout.fillWidth: true
                    text: "esc close"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
            }
        }
    }
}
