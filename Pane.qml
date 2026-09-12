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

    // An argv array through execDetached — no shell at all. The panel-injected
    // `shell` facade has no `run()` (that is the bar's API, and it wraps
    // everything in `bash -lc`), which turns out for the better: this names the
    // launcher by absolute path and passes its argument as its own element, so
    // nothing is ever parsed as a command.
    function openTui() {
        Quickshell.execDetached(["/usr/bin/omarchy-launch-or-focus-tui", "oxidone"]);
        root.close();
    }

    // Not `state`: QQuickItem already has one, for its States/Transitions
    // machinery, and shadowing it would misbehave the moment anything here grew
    // a states block.
    readonly property string serviceState: service ? service.state : "ok"

    readonly property var rows: service && service.payload ? Rows.buildRows(service.payload) : []

    // An answer has arrived, as distinct from an answer being "ok". The Service
    // starts at ok deliberately, so state alone cannot tell the difference
    // between a clear day and a question nobody has asked yet.
    readonly property bool hasAnswer: service !== null && service.payload !== null && service.payload !== undefined

    // Summoned surfaces honour OMARCHY_MENU_FONT; the bar font is for the bar.
    readonly property string fontFamily: Style.font.menuFamily

    // Which row the keyboard is on, held as the entry's id rather than its
    // position. `rows` is rebuilt wholesale on every poll, so an index survives
    // the rebuild while pointing at a different task — the cursor would appear
    // to jump on its own. An id either still exists or does not.
    property string selectedId: ""

    readonly property int selectedIndex: {
        if (root.selectedId === "") {
            return -1;
        }
        for (var i = 0; i < root.rows.length; i++) {
            if (root.rows[i].kind === "entry" && root.rows[i].id === root.selectedId) {
                return i;
            }
        }
        return -1;
    }

    readonly property var selectable: Rows.selectableIndexes(root.rows)

    function moveCursor(delta) {
        if (root.selectable.length === 0) {
            return;
        }
        var at = root.selectable.indexOf(root.selectedIndex);
        // From nowhere, a step down lands on the first row and a step up on
        // the last, so either key opens the list rather than doing nothing.
        var next = at < 0 ? (delta > 0 ? 0 : root.selectable.length - 1) : at + delta;
        next = Math.max(0, Math.min(root.selectable.length - 1, next));
        root.selectedId = root.rows[root.selectable[next]].id;
        list.positionViewAtIndex(root.selectable[next], ListView.Contain);
    }

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
                onMoveRequested: function (dx, dy) {
                    if (dy !== 0) {
                        root.moveCursor(dy);
                    }
                }
                // Enter opens the place where things can actually be changed.
                // This release reads; the TUI is where the day gets worked.
                onReturnRequested: root.openTui()
            }

            PointerMoveGate {
                id: pointerGate
                referenceItem: card
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
                    text: root.hasAnswer ? "Nothing due today." : "No answer from oxidone yet."
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
                    text: "j/k move · enter open oxidone · esc close"
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
                    //
                    // A plain Text, not a second PanelSectionHeader: that component
                    // darkens whatever colour it is handed by 1.4, which takes the
                    // muted count from 4.16:1 against the card to 2.48:1 — below
                    // even the large-text threshold. Every other muted glyph in
                    // this pane is a plain Text at Color.muted; the count matches.
                    Text {
                        visible: row.count > 0
                        text: String(row.count)
                        color: row.urgent ? Color.urgent : Color.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        textFormat: Text.PlainText
                    }
                }
            }

            Component {
                id: entryDelegate

                CursorSurface {
                    height: Math.max(Style.space(22), titleText.implicitHeight)
                    hasCursor: rowIndex === root.selectedIndex
                    current: rowIndex === root.selectedIndex

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        // A list that moves under a still pointer would
                        // otherwise hand the cursor to whatever slid beneath it.
                        onPositionChanged: function (mouse) {
                            if (pointerGate.moved(this, mouse)) {
                                root.selectedId = row.id;
                            }
                        }
                        onClicked: {
                            root.selectedId = row.id;
                            root.openTui();
                        }
                    }

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
