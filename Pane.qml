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
        // Populated ahead of being looked at: by the time anyone opens the
        // selector, Today is already showing, so there is no spinner state
        // to design for.
        if (root.service) {
            root.service.loadLists();
            // A List scope outlives close(), and `onScopeChanged` is the only
            // other caller — so without this the pane reopens on a List hours
            // later still showing the entries it read then, unstruck and with
            // nothing saying so (`stale` is a Today-poll fact). Same route as
            // a scope change: the Service's in-flight and identity guards own
            // the rest of it.
            if (root.scope !== "") {
                root.service.loadList(root.scope);
            }
        }
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

    // "" is Today; anything else is a List id.
    property string scope: ""

    readonly property var scopeOptions: {
        // Today first: it is what the bar counts and what the pane opens
        // on. The Lists follow in the CLI's own order.
        var out = [{ value: "", label: "Today" }];
        var lists = service && service.lists ? service.lists : [];
        for (var i = 0; i < lists.length; i++) {
            // A List title is a string from Google, reaching a Dropdown —
            // a host component this plugin cannot pin to PlainText.
            out.push({ value: String(lists[i].id), label: Rows.plain(lists[i].title, 60) });
        }
        return out;
    }

    // A scope naming a list that is no longer offered is clamped back to Today.
    // `Dropdown.currentLabel()` renders the value verbatim when it is not among
    // the options (Ui/Dropdown.qml:59), and the value is a raw Google id — the
    // one string here that never goes through `Rows.plain`. It is also a scope
    // no answer can ever arrive for. Today is the fail-closed place to land.
    onScopeOptionsChanged: {
        if (root.scope === "") {
            return;
        }
        for (var i = 0; i < root.scopeOptions.length; i++) {
            if (root.scopeOptions[i].value === root.scope) {
                return;
            }
        }
        root.scope = "";
    }

    onScopeChanged: {
        scopeDropdown.value = root.scope;
        // selectedIndex is derived from selectedId, so the cursor resets by
        // clearing the id rather than the (read-only) derived index.
        root.selectedId = "";
        if (root.scope !== "" && service) {
            service.loadList(root.scope);
        }
    }

    readonly property var rows: {
        if (root.scope === "") {
            return service && service.payload ? Rows.buildRows(service.payload) : [];
        }
        var listPayload = service ? service.listPayload : null;
        // Only this list's answer may be drawn under this list's name. A failed
        // load leaves the previous list's answer cached, and rendering it here
        // is the same lie the Service's own guard prevents upstream — the
        // fetcher checks identity, and so must the renderer.
        return listPayload && listPayload.list === root.scope ? Rows.buildListRows(listPayload) : [];
    }

    // An answer has arrived, as distinct from an answer being "ok". The Service
    // starts at ok deliberately, so state alone cannot tell the difference
    // between a clear day and a question nobody has asked yet.
    readonly property bool hasAnswer: service !== null && service.payload !== null && service.payload !== undefined

    // Whether the scope on screen has an answer of its own. `hasAnswer` speaks
    // for Today; a List has its own load, which can be absent or stale while
    // Today's is perfectly fine.
    readonly property bool hasScopeAnswer: root.scope === "" ? root.hasAnswer : (service !== null && service.listPayload !== null && service.listPayload !== undefined && service.listPayload.list === root.scope)

    readonly property bool needsAttention: root.serviceState === "auth-needed" || root.serviceState === "unusable"

    readonly property string message: {
        if (root.serviceState === "unusable") {
            return "No usable oxidone was found at the configured path. This plugin needs oxidone 1.2.0 or newer, installed separately.";
        }
        if (root.serviceState === "auth-needed") {
            return "oxidone has no usable Google authorization. Run it once to authorize; this plugin never asks for consent itself.";
        }
        // `stale` is set only by the Today poll — tasksProc never touches state
        // — so it says nothing about a List that loaded a moment ago. Scoped to
        // Today, a List falls through to its own hasScopeAnswer logic below.
        if (root.serviceState === "stale" && root.scope === "") {
            return root.hasAnswer ? "Showing the last answer — oxidone could not be reached." : "No answer from oxidone yet.";
        }
        if (!root.hasScopeAnswer) {
            return "No answer from oxidone yet.";
        }
        return root.scope === "" ? "Nothing due today." : "Nothing in this list.";
    }

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
        // The gate's own contract: reset after a keyboard or list mutation, so
        // the rows sliding under a stationary pointer are not mistaken for the
        // pointer moving. Without this the scroll this line just caused could
        // hand the cursor straight back to whatever landed under the mouse.
        pointerGate.reset();
    }

    // h/l and left/right walk between scopes, the way the TUI's sidebar does.
    // The Dropdown is the mouse's way in; this is the keyboard's. Without it a
    // pane that is keyboard-first everywhere else has one control a keyboard
    // cannot reach, because PanelKeyCatcher consumes Tab before it gets there.
    function cycleScope(delta) {
        var options = root.scopeOptions;
        if (options.length < 2) {
            return;
        }
        var at = 0;
        for (var i = 0; i < options.length; i++) {
            if (options[i].value === root.scope) {
                at = i;
                break;
            }
        }
        // Clamped, not wrapped — the same rule the row cursor follows.
        var next = Math.max(0, Math.min(options.length - 1, at + delta));
        root.scope = options[next].value;
    }

    onRowsChanged: pointerGate.reset()

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

            PointerMoveGate {
                id: pointerGate
                referenceItem: card
            }

            // The catcher is the ANCESTOR of the content, not its sibling.
            // `Keys.priority: Keys.BeforeItem` preempts DESCENDANTS only, and a
            // sibling never sees a key a focused child already took — so with
            // the content outside, one click on the selector (which calls
            // `trigger.forceActiveFocus()`, Ui/Dropdown.qml:138) left the whole
            // pane deaf, Esc included, on a surface holding exclusive keyboard
            // focus. This is the nesting Ui/PanelKeyCatcher.qml documents and
            // the one the host's own dev-gallery panel uses.
            PanelKeyCatcher {
                id: keys
                anchors.fill: parent
                // The popup owns j/k and Enter while it is open; the pane's
                // cursor must hold still rather than move underneath it.
                blocked: scopeDropdown.popupOpen
                onCloseRequested: root.close()
                onMoveRequested: function (dx, dy) {
                    if (dy !== 0) {
                        root.moveCursor(dy);
                    } else if (dx !== 0) {
                        root.cycleScope(dx);
                    }
                }
                // Enter opens the place where things can actually be changed.
                // This release reads; the TUI is where the day gets worked.
                onReturnRequested: root.openTui()

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.spacing.panelPadding
                    spacing: Style.spacing.panelGap

                    // The pane's own name, not the scope.
                    //
                    // This said "Today" until it was seen with a List selected:
                    // the title, the selector under it and the first group header
                    // all read "Today" at once, and the moment the scope changed
                    // the title contradicted the selector directly below it. The
                    // selector already names the scope; this names the pane, which
                    // is what a keyboard-summoned overlay needs to say.
                    PanelSectionHeader {
                        Layout.fillWidth: true
                        text: "oxidone"
                        textFormat: Text.PlainText
                    }

                    Dropdown {
                        id: scopeDropdown
                        Layout.fillWidth: true
                        options: root.scopeOptions
                        // Deliberately NOT `value: root.scope`. Dropdown assigns to
                        // its own `value` when a selection is made, and an
                        // imperative assignment destroys a declarative binding for
                        // good — so after the first mouse use the trigger label
                        // would stop tracking the scope, and h/l would change the
                        // list while the selector kept naming the old one.
                        onChanged: function (value) {
                            root.scope = value;
                        }
                        // Clicking the trigger takes active focus and nothing
                        // ever hands it back, so the keys have to be taken
                        // back explicitly the moment the popup lets go of them.
                        onPopupOpenChanged: {
                            if (!scopeDropdown.popupOpen) {
                                keys.forceActiveFocus();
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: root.rows.length === 0 || root.needsAttention || (root.scope === "" && root.serviceState === "stale")
                        spacing: Style.spacing.xs

                        Text {
                            Layout.fillWidth: true
                            text: root.message
                            color: Color.menu.text
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                        }

                        Button {
                            visible: root.needsAttention
                            text: "Open oxidone"
                            onClicked: root.openTui()
                        }
                    }

                    ListView {
                        id: list
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        // The list shows whenever there is one, whatever the state:
                        // auth-needed and unusable describe a fetch that failed, not
                        // data that became false, and hiding a real list loses
                        // information the message block is already explaining. The
                        // message says whether it can be trusted; the list says what
                        // it was.
                        visible: root.rows.length > 0
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
                        text: "j/k move · h/l scope · enter open oxidone · esc close"
                        color: Color.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                    }
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
                    // Fixed, and clipped to it — the condition the Task 2 ruling
                    // accepted combining-mark titles on. Bounding code units
                    // cannot bound ink: glyphs that stack out of their line box
                    // are cut at this row's own edge instead of drawing over the
                    // rows either side. controlHeight is the height every other
                    // control row in the kit stands at, the Dropdown included.
                    height: Style.spacing.controlHeight
                    clip: true
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
                        // A Subtask nests one level under its parent; Today's
                        // rows carry no depth at all, hence the fallback.
                        anchors.leftMargin: (row.depth || 0) * Style.space(14)
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
