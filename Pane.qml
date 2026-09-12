import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "src/rows.js" as Rows

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

    // Not `state`: QQuickItem already has one, for its States/Transitions
    // machinery, and shadowing it would misbehave the moment anything here grew
    // a states block.
    readonly property string serviceState: service ? service.state : "ok"

    readonly property var rows: service && service.payload ? Rows.buildRows(service.payload) : []

    // Summoned surfaces honour OMARCHY_MENU_FONT; the bar font is for the bar.
    readonly property string fontFamily: Style.font.menuFamily

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
            // Follow the compositor's own rounding rather than picking a number:
            // Style.cornerRadius mirrors Hyprland's decoration:rounding live, so
            // the card is square on a square desktop and round on a round one.
            radius: Style.cornerRadius
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

                Text {
                    Layout.fillWidth: true
                    visible: root.rows.length === 0
                    text: root.serviceState === "ok" ? "Nothing due today." : "No answer from oxidone yet."
                    color: Color.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    textFormat: Text.PlainText
                }

                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.rows
                    spacing: Style.spacing.rowGap
                    // The list owns its scroll position across model updates;
                    // a Flickable would lose it on every poll.
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Loader {
                        width: ListView.view.width
                        sourceComponent: modelData.kind === "header" ? headerDelegate : entryDelegate
                        property var row: modelData
                        property int rowIndex: index
                    }
                }

                PanelSeparator {
                    Layout.fillWidth: true
                }

                Text {
                    Layout.fillWidth: true
                    text: "esc close"
                    color: Color.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
            }

            Component {
                id: headerDelegate

                Row {
                    spacing: Style.spacing.xs

                    PanelSectionHeader {
                        text: row.label
                        textFormat: Text.PlainText
                    }

                    // The count drops away at zero outstanding, along with its
                    // colour: a group with nothing left to move is just a
                    // heading over what already happened.
                    PanelSectionHeader {
                        visible: row.count > 0
                        text: String(row.count)
                        foreground: row.urgent ? Color.urgent : Color.muted
                        textFormat: Text.PlainText
                    }
                }
            }

            Component {
                id: entryDelegate

                Item {
                    // A fixed height, not one that grows with its content: a
                    // title can carry a long run of combining marks, and a row
                    // sized to fit them would bleed over its neighbours. The
                    // cap in rows.js bounds the code units, not the ink.
                    height: Style.space(22)
                    clip: true

                    Row {
                        anchors.left: parent.left
                        anchors.right: dueText.left
                        anchors.rightMargin: Style.spacing.xs
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.xs

                        // The Entry type's signifier, in the gutter the TUI
                        // gives it. Blank for a Task, which is most of them.
                        Text {
                            width: Style.space(10)
                            text: row.signifier
                            color: Color.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            textFormat: Text.PlainText
                        }

                        Text {
                            id: titleText
                            width: parent.width - Style.space(10) - Style.spacing.xs * 2 - notesText.width
                            text: row.title
                            color: row.completed ? Color.muted : (row.overdue ? Color.urgent : Color.menu.text)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.strikeout: row.completed
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }

                        // Says the entry carries a notes body; the body itself
                        // is not in this contract and is not drawn.
                        Text {
                            id: notesText
                            text: row.hasNotes ? "≡" : ""
                            color: Color.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            textFormat: Text.PlainText
                        }
                    }

                    Text {
                        id: dueText
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.dueLabel
                        color: row.overdue ? Color.urgent : Color.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                    }
                }
            }
        }
    }
}
