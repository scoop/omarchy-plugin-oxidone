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
        // A pane that has just been summoned has nothing armed, by
        // definition — whatever the shell's toggle path did before this
        // call, a stale arm must not carry into the newly-opened pane.
        root.armedId = "";
        // Defensive, not load-bearing: a freshly-summoned pane has no popup
        // open by definition. It costs nothing to say so here too, and it
        // keeps the invariant true no matter how the previous appearance
        // ended, rather than resting on close() alone getting it right.
        scopeDropdown.close();
        // Same reasoning for the editor: an open strip holds the key catcher
        // blocked, so one left behind would come back deaf.
        root.editorMode = "";
        root.editorNotice = "";
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
        root.armedId = "";
        // Before `opened` goes false: the strip's `blocked` binding follows
        // `editorMode`, and a strip left open would hold the keys on the next
        // appearance exactly as the scope popup once did.
        root.closeEditor();
        // `blocked` (below) is bound to the popup, not to `opened` — closing
        // the pane while the scope selector is open leaves that binding
        // true, and it stays true across the next open() too, since nothing
        // else ever closes the popup. The result is a pane that comes back
        // deaf to j/k, h/l, space, m and x, with focus otherwise perfectly
        // fine — which reads as a flaky key catcher rather than a stuck
        // popup. It looks intermittent for a second reason: Dropdown's own
        // trigger handles Escape-while-open by closing the popup itself, so
        // the first Escape after a reopen silently clears the latch instead
        // of closing the pane, and everything starts working again. Closing
        // the popup here, unconditionally, is what actually breaks the latch.
        scopeDropdown.close();
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
            out.push({ value: String(lists[i].id), label: Rows.hostText(lists[i].title, 60) });
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
        // The row armed under the old scope is not on screen any more.
        root.armedId = "";
        // Neither is the row being renamed or dated, and a capture's target
        // just changed underneath the placeholder naming it.
        root.closeEditor();
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

    // The row asked to be deleted, waiting for its confirming second press.
    // Delete is the only op with a gate, because it is the only one with no
    // inverse: the CLI has no undelete, and Google's soft delete is reachable
    // only from Google's own client.
    property string armedId: ""

    // Consumed by onActivateRequested; see the comment on onReturnRequested.
    property bool _enterLatch: false

    // Which text op the strip is serving: "", "capture", "retitle" or "due".
    // One field, three jobs — one geometry, one focus path, and the row being
    // edited stays visible and cursored below it rather than behind it.
    property string editorMode: ""
    property string editorTargetId: ""
    property string editorTargetList: ""

    // The strip's own sentence, for a refusal that never became an Apply: no
    // default list to capture into, an empty title. Not an Entry's failure, so
    // not `applyErrors`.
    property string editorNotice: ""

    readonly property string editorLabel: {
        if (root.editorMode === "capture") {
            return "New";
        }
        if (root.editorMode === "retitle") {
            return "Rename";
        }
        return "Due";
    }

    readonly property string editorPlaceholder: {
        if (root.editorMode === "capture") {
            // Today is no List, so a capture there lands somewhere the pane does
            // not otherwise name. In a List the selector directly above already
            // says where, and repeating it would be noise.
            var where = root.scope === "" ? root.captureListTitle : "";
            return where !== "" ? "New entry in " + where + "…" : "New entry…";
        }
        if (root.editorMode === "retitle") {
            return "Title";
        }
        return "tomorrow, +3d, 25, or a date — empty clears it";
    }

    // Where a capture goes: the List on screen, or the default one in Today.
    readonly property string captureListId: root.scope !== "" ? root.scope : (service ? service.defaultList : "")

    readonly property string captureListTitle: {
        var lists = service && service.lists ? service.lists : [];
        for (var i = 0; i < lists.length; i++) {
            if (String(lists[i].id) === root.captureListId) {
                // This one ends up in `editorPlaceholder`, and a placeholder is
                // drawn by the style's own Text, which pins no format. Nothing
                // on this side can, either — so `hostText`, not `plain`.
                return Rows.hostText(lists[i].title, 40);
            }
        }
        return "";
    }

    // The captures that failed, oldest first, each named by the title it
    // carried so two failures in one run are told apart.
    readonly property var captureFailures: {
        var out = [];
        var map = service ? service.captures : null;
        if (!map) {
            return out;
        }
        for (var key in map) {
            var record = map[key];
            if (record && !record.pending && record.message !== "") {
                out.push({
                    key: key,
                    seq: record.seq,
                    label: Rows.plain(record.title, 40) + " — " + record.message
                });
            }
        }
        out.sort(function (a, b) {
            return a.seq - b.seq;
        });
        return out;
    }

    readonly property int capturesPending: {
        var count = 0;
        var map = service ? service.captures : null;
        if (!map) {
            return 0;
        }
        for (var key in map) {
            if (map[key] && map[key].pending) {
                count += 1;
            }
        }
        return count;
    }

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
        // The row you were about to delete is not the row under the cursor any
        // more.
        root.armedId = "";
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

    // The row the cursor names, or null. Header rows are never selectable, so a
    // non-negative selectedIndex always points at an entry.
    readonly property var selectedRow: root.selectedIndex >= 0 ? root.rows[root.selectedIndex] : null

    function applySelected(op) {
        var row = root.selectedRow;
        if (row === null || !root.service) {
            return;
        }
        root.service.applyOp(op, { list: row.list, task: row.id });
    }

    function _openEditor(mode, seed) {
        // Whatever was armed is not what is being typed at.
        root.armedId = "";
        root.editorNotice = "";
        root.editorMode = mode;
        editor.text = seed;
        // The content needs a layout pass before focus will land, the same
        // reason open() defers its own.
        Qt.callLater(function () {
            editor.forceActiveFocus();
            // Seeded and selected, so the first keystroke replaces it — what
            // the TUI's own due editor does, and what makes `d` quick.
            editor.selectAll();
        });
    }

    function openCapture() {
        if (root.captureListId === "") {
            // Today with no default list resolved. oxidone's TUI refuses the
            // same capture in the same situation; say so rather than open a
            // field whose Enter could only fail.
            root.editorNotice = "No list to capture into yet — open oxidone once, or pick a list.";
            return;
        }
        root._openEditor("capture", "");
    }

    function openRetitle() {
        var row = root.selectedRow;
        if (row === null) {
            return;
        }
        root.editorTargetId = row.id;
        root.editorTargetList = row.list;
        // The raw title, not the drawn one: `retitle` sends a Display title back
        // and oxidone re-applies the type, so seeding from the elided,
        // control-stripped version would save that mangling as the new name.
        root._openEditor("retitle", row.rawTitle);
    }

    function openDue() {
        var row = root.selectedRow;
        if (row === null) {
            return;
        }
        root.editorTargetId = row.id;
        root.editorTargetList = row.list;
        root._openEditor("due", row.due);
    }

    function closeEditor() {
        root.editorMode = "";
        root.editorTargetId = "";
        root.editorTargetList = "";
        root.editorNotice = "";
        // The strip is where a capture's failure is shown, so closing it is what
        // dismisses one. A capture still in flight keeps its record.
        if (root.service) {
            root.service.clearSettledCaptures();
        }
        keys.forceActiveFocus();
    }

    function commitEditor() {
        var text = editor.text.trim();
        if (!root.service) {
            return;
        }
        if (root.editorMode === "capture") {
            // An empty submit creates nothing and says nothing, exactly as the
            // TUI's does — it is how you leave a capture you thought better of.
            if (text === "") {
                return;
            }
            root.service.capture(text, root.captureListId, root.scope === "");
            // Stays open, cleared: a capture run is type, Enter, type, Enter.
            editor.text = "";
            return;
        }
        if (root.editorMode === "retitle") {
            if (text === "") {
                root.editorNotice = "A title cannot be empty.";
                return;
            }
            root.service.applyOp("retitle", { list: root.editorTargetList, task: root.editorTargetId, title: text });
        } else if (root.editorMode === "due") {
            // An emptied field is the clear. `set_due` and `clear_due` are
            // separate commands on the wire, exactly as the contract requires —
            // this is one key reaching both, not one op with a nullable field.
            if (text === "") {
                root.service.applyOp("clear_due", { list: root.editorTargetList, task: root.editorTargetId });
            } else {
                root.service.resolveAndSetDue(root.editorTargetList, root.editorTargetId, text);
            }
        }
        root.closeEditor();
    }

    // Space is its own undo: on an outstanding row it completes, on a completed
    // one it reopens. That pairing is why this slice needs no undo stack.
    function toggleComplete() {
        var row = root.selectedRow;
        if (row === null) {
            return;
        }
        root.applySelected(row.completed ? "uncomplete" : "complete");
    }

    // The delete gate, for both the `x` key and the row's trash button. It lives
    // here rather than in each caller so the `armedId === id` equality is written
    // once: that comparison is what bounds every armed-state defect to "one lost
    // confirmation on the same row" instead of "deleted a different row", and a
    // second copy of it is a second place for that bound to be got wrong.
    //
    // Selecting first is load-bearing twice over. applySelected() reads
    // `selectedRow`, so it is what makes the id being deleted the id that was
    // armed rather than whatever the cursor sat on before the click — and the
    // action buttons are revealed on the selected-or-hovered row, while a
    // pointer resting on a button leaves `rowHover.containsMouse` false. Arming
    // without selecting would therefore hide the very button being pressed,
    // which is the defect this whole change exists to close.
    function armOrDelete(id) {
        root.selectedId = id;
        if (root.armedId === id) {
            root.armedId = "";
            root.applySelected("delete");
            return;
        }
        root.armedId = id;
    }

    onRowsChanged: {
        pointerGate.reset();
        // A refresh landed underneath the arm. The id may still exist, but the
        // person armed what was on screen a moment ago, not what is now.
        root.armedId = "";
        // A rename or a date being typed for a row that has since gone — deleted
        // elsewhere, or migrated out of Today — has nothing left to apply to.
        if (root.editorMode === "retitle" || root.editorMode === "due") {
            var stillThere = false;
            for (var i = 0; i < root.rows.length; i++) {
                if (root.rows[i].kind === "entry" && root.rows[i].id === root.editorTargetId) {
                    stillThere = true;
                    break;
                }
            }
            if (!stillThere) {
                root.closeEditor();
            }
        }
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
                // The popup owns j/k and Enter while it is open, and the
                // editor owns every printable key while it is; the pane's
                // cursor must hold still rather than move underneath either.
                // Bound to `editorMode` rather than the field's focus, so a
                // click that takes focus elsewhere cannot hand `x` back to a
                // row while a rename is half-typed above it.
                blocked: scopeDropdown.popupOpen || root.editorMode !== ""
                onCloseRequested: {
                    // Esc cancels the arm before it closes the pane: the person
                    // who armed by accident reaches for Esc, and having it close
                    // instead would read as the key doing the wrong thing.
                    if (root.armedId !== "") {
                        root.armedId = "";
                        return;
                    }
                    root.close();
                }
                onDeleteRequested: {
                    var row = root.selectedRow;
                    if (row === null) {
                        return;
                    }
                    root.armOrDelete(row.id);
                }
                onMoveRequested: function (dx, dy) {
                    if (dy !== 0) {
                        root.moveCursor(dy);
                    } else if (dx !== 0) {
                        root.cycleScope(dx);
                    }
                }
                // Enter opens the place where the day gets worked.
                //
                // PanelKeyCatcher emits returnRequested AND activateRequested
                // for Enter, in that order, in one synchronous handler — while
                // Space emits activateRequested alone. Without this latch, every
                // Enter would open the TUI *and* complete the row under the
                // cursor. The latch is set here and consumed immediately below.
                onReturnRequested: {
                    root._enterLatch = true;
                    root.openTui();
                }
                onActivateRequested: {
                    if (root._enterLatch) {
                        root._enterLatch = false;
                        return;
                    }
                    // Space is a key like any other: it is a change of mind
                    // when a row is armed. Enter needs no handling here —
                    // openTui() calls close(), which already clears the arm.
                    root.armedId = "";
                    root.toggleComplete();
                }
                onTextKey: function (text) {
                    // Any key is a change of mind, `m` included: a migrate that
                    // does not fold leaves `rows` untouched, so nothing else
                    // would disarm, and the armed prompt would go on hiding the
                    // migrate's own failure message until an `x` deleted the row.
                    root.armedId = "";
                    // The TUI's own three: `a` adds, `e` edits the title, `d`
                    // the due date.
                    if (text === "m") {
                        root.applySelected("migrate");
                    } else if (text === "a") {
                        root.openCapture();
                    } else if (text === "e") {
                        root.openRetitle();
                    } else if (text === "d") {
                        root.openDue();
                    }
                }

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

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.spacing.xs

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

                        // Capture is the one op with no row to hover, so its
                        // way in for the mouse lives beside the selector that
                        // names where it will land.
                        PanelActionButton {
                            iconText: ""
                            tooltipText: "New entry"
                            focusable: false
                            fontFamily: root.fontFamily
                            onClicked: root.openCapture()
                        }
                    }

                    // The editor. One field, three jobs — see `editorMode`.
                    RowLayout {
                        Layout.fillWidth: true
                        visible: root.editorMode !== ""
                        spacing: Style.spacing.xs

                        Text {
                            text: root.editorLabel
                            color: Color.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            textFormat: Text.PlainText
                        }

                        TextField {
                            id: editor
                            Layout.fillWidth: true
                            placeholderText: root.editorPlaceholder
                            font.family: root.fontFamily
                            // A bound on the widget, not a rule about titles:
                            // Google owns how long one may be, and says so with
                            // an exit code. This only stops a pasted novel from
                            // growing the field without end.
                            //
                            // Set far above Google's own 1024-character limit on
                            // purpose. `maximumLength` truncates on assignment
                            // and counts UTF-16 units, so a cap at that limit
                            // would silently shorten a seeded title made of
                            // astral characters — which is the very destruction
                            // seeding from `rawTitle` exists to avoid.
                            maximumLength: 4096
                            Keys.onEscapePressed: function (event) {
                                root.closeEditor();
                                event.accepted = true;
                            }
                            // Not `onAccepted`. A QQC TextField emits that
                            // signal without accepting the event, so the Return
                            // goes on up to the key catcher — which by then is
                            // unblocked, because committing closed the editor,
                            // and answers it by opening the TUI. Every rename
                            // and every date landed and then launched a
                            // terminal over the pane. Accepting it here is what
                            // stops the key at the field it was typed into.
                            Keys.onReturnPressed: function (event) {
                                root.commitEditor();
                                event.accepted = true;
                            }
                            Keys.onEnterPressed: function (event) {
                                root.commitEditor();
                                event.accepted = true;
                            }
                        }
                    }

                    // What the strip has to say for itself: a refusal that never
                    // became an Apply, the captures still in flight, and the ones
                    // that failed — each named by its own title, because a run of
                    // captures can have more than one answer outstanding.
                    Column {
                        Layout.fillWidth: true
                        spacing: Style.spacing.xs
                        visible: root.editorNotice !== "" || root.capturesPending > 0 || root.captureFailures.length > 0

                        Text {
                            width: parent.width
                            visible: root.editorNotice !== ""
                            text: root.editorNotice
                            color: Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                        }

                        Text {
                            width: parent.width
                            visible: root.capturesPending > 0
                            text: root.capturesPending === 1 ? "sending…" : root.capturesPending + " sending…"
                            color: Color.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            textFormat: Text.PlainText
                        }

                        Repeater {
                            model: root.captureFailures

                            Text {
                                width: parent.width
                                text: modelData.label
                                color: Color.urgent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                                textFormat: Text.PlainText
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
                        // Each key is bound to its verb with U+00A0, written as
                        // an escape because a literal one is invisible in source
                        // and the next person would delete it by accident. The
                        // wrap below is deliberate; what it must not do is break
                        // a pair, which it did — leaving a line ending in a bare
                        // "m" and the next starting "migrate", reading as two
                        // hints that are one.
                        text: "j/k\u00a0move · h/l\u00a0scope · space\u00a0done · a\u00a0add · e\u00a0rename · d\u00a0due · m\u00a0migrate · x\u00a0delete · esc\u00a0close"
                        color: Color.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        // Nine verbs do not fit one line at the card's clamped
                        // width, and eliding one would hide a key rather than
                        // shorten a sentence. Breaks now fall only on the
                        // separators.
                        wrapMode: Text.WordWrap
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
                    id: entrySurface
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

                    readonly property bool pending: root.service !== null && root.service.applyPending[row.id] === true
                    readonly property bool armed: root.armedId === row.id
                    readonly property string failure: root.service !== null && root.service.applyErrors[row.id] !== undefined ? root.service.applyErrors[row.id] : ""
                    // The whole of the title's colour decision, taken in
                    // `src/rows.js` where it can be read as a table and tested.
                    // Neither `armed` nor `failure` is an input to it — see the
                    // rule at `Rows.titleRole`.
                    readonly property string titleRole: Rows.titleRole(row, entrySurface.pending)

                    MouseArea {
                        id: rowHover
                        anchors.fill: parent
                        hoverEnabled: true
                        // A row waiting on an answer is not a row to act on.
                        enabled: !entrySurface.pending
                        onPositionChanged: function (mouse) {
                            if (pointerGate.moved(this, mouse)) {
                                // Only a *different* row disarms. This handler is
                                // the row's own MouseArea, so `row` is by
                                // construction the row under the pointer, and the
                                // test reads as written: the row you were about to
                                // delete is not the row under the pointer any more.
                                //
                                // Movement inside the armed row has to be survivable
                                // now that the trash button is the mouse's confirm.
                                // It is a 22px target, and disarming on any motion
                                // at all would let a few pixels of drift cancel an
                                // arm the person is still reaching to confirm.
                                if (root.armedId !== row.id) {
                                    root.armedId = "";
                                }
                                root.selectedId = row.id;
                            }
                        }
                        onClicked: {
                            // Backing out of a delete is not a request to open the
                            // TUI. Clicking the armed row cancels and stops there,
                            // the same reading onCloseRequested gives Esc — and for
                            // the same reason, since a pane that vanished into the
                            // TUI would read as the click doing the wrong thing.
                            var cancelling = root.armedId === row.id;
                            root.armedId = "";
                            root.selectedId = row.id;
                            if (!cancelling) {
                                root.openTui();
                            }
                        }
                    }

                    Row {
                        anchors.left: parent.left
                        // A Subtask nests one level under its parent; Today's
                        // rows carry no depth at all, hence the fallback.
                        anchors.leftMargin: (row.depth || 0) * Style.space(14)
                        anchors.right: rightEdge.left
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
                            // Roles, not colours, come out of `src/`: it holds
                            // no QML types, and `Color.menu.text` exists only
                            // here. This line is the whole of the mapping.
                            color: entrySurface.titleRole === "urgent" ? Color.urgent : (entrySurface.titleRole === "muted" ? Color.muted : Color.menu.text)
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

                    // Everything that lives at the row's right edge, laid out
                    // rather than stacked. These used to anchor to parent.right
                    // independently, and a selected row that also carried a
                    // failure drew its message and its buttons on top of each
                    // other. A positioner skips invisible children, so each
                    // state composes here without the others knowing about it.
                    Row {
                        id: rightEdge
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.xs

                        // The armed prompt says where a delete is recoverable,
                        // because we cannot offer it ourselves: the CLI has no
                        // undelete, and Google keeps a soft-deleted task in its own
                        // client.
                        //
                        // It names both routes because both commit. Naming only the
                        // key is what stranded a mouse-only person mid-delete: the
                        // button they had just pressed was gone, and the prompt that
                        // replaced it sent them to the keyboard to finish.
                        Text {
                            id: armedText
                            visible: entrySurface.armed
                            text: "click or x again to delete · recoverable in Google"
                            color: Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            textFormat: Text.PlainText
                        }

                        Text {
                            id: failureText
                            visible: !entrySurface.armed && entrySurface.failure !== ""
                            // Our sentence, chosen by exit code. oxidone's own
                            // message never reaches a QML sink.
                            text: entrySurface.failure
                            color: Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            textFormat: Text.PlainText
                        }

                        Text {
                            id: dueText
                            // Five buttons and a date do not both fit once the
                            // card is clamped to a narrow display. The date
                            // yields, because the actions are only ever on the
                            // one row being looked at, and it comes straight
                            // back when the cursor moves on.
                            //
                            // The swap also changes how much room is left for
                            // the title, so the title re-elides as the cursor
                            // steps. Left that way on purpose: holding the width
                            // steady means reserving five buttons' worth on
                            // every row in every state, paying in title width
                            // everywhere to settle the one row being looked at.
                            //
                            // `!armed` is not covered by `!actions.visible`, which
                            // is why it stays: a row that is Pending *and* armed —
                            // reachable by pressing `x` on a row waiting on some
                            // other op, since the gate does not check Pending —
                            // hides the actions for being Pending, and would
                            // otherwise draw its date beside the armed prompt.
                            visible: !entrySurface.armed && entrySurface.failure === "" && !actions.visible
                            text: row.dueLabel
                            color: row.overdue ? Color.urgent : Color.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            textFormat: Text.PlainText
                        }

                        // The mouse's way to the same five ops the keyboard has.
                        // Revealed on the focused or hovered row, per the spec.
                        //
                        // The four that are not the delete each move the cursor,
                        // so each disarms first, exactly as the row's own
                        // MouseArea does: a prompt left standing on the row the
                        // cursor walked away from is a question about nothing.
                        // They disarm whatever was armed *anywhere* — their own
                        // row hides them while it is armed, but the row the
                        // pointer is resting on is not always the armed one.
                        //
                        // Delete is the exception, and this Row's shape is built
                        // around it. Arming used to hide the whole Row, which took
                        // the trash button away the instant it was pressed and left
                        // the keyboard as the only way to finish. The gate moved
                        // onto the other four: an armed row keeps its trash button,
                        // and that button is the confirm.
                        Row {
                            id: actions
                            spacing: Style.spacing.xs
                            visible: !entrySurface.pending && (rowIndex === root.selectedIndex || rowHover.containsMouse)

                            PanelActionButton {
                                visible: !entrySurface.armed
                                iconText: row.completed ? "" : ""
                                tooltipText: row.completed ? "Reopen" : "Complete"
                                focusable: false
                                fontFamily: root.fontFamily
                                onClicked: {
                                    root.armedId = "";
                                    root.selectedId = row.id;
                                    root.toggleComplete();
                                }
                            }

                            PanelActionButton {
                                visible: !entrySurface.armed
                                iconText: ""
                                tooltipText: "Rename"
                                focusable: false
                                fontFamily: root.fontFamily
                                onClicked: {
                                    root.armedId = "";
                                    root.selectedId = row.id;
                                    root.openRetitle();
                                }
                            }

                            PanelActionButton {
                                visible: !entrySurface.armed
                                iconText: ""
                                tooltipText: "Due date"
                                focusable: false
                                fontFamily: root.fontFamily
                                onClicked: {
                                    root.armedId = "";
                                    root.selectedId = row.id;
                                    root.openDue();
                                }
                            }

                            PanelActionButton {
                                visible: !entrySurface.armed
                                iconText: ""
                                tooltipText: "Migrate to tomorrow"
                                focusable: false
                                fontFamily: root.fontFamily
                                onClicked: {
                                    root.armedId = "";
                                    root.selectedId = row.id;
                                    root.applySelected("migrate");
                                }
                            }

                            // Stays through the arm, and does not move when it does.
                            // A positioner skips invisible children, so with the four
                            // above hidden this is still the last visible child of a
                            // right-anchored Row — the same pixels it occupied when it
                            // was pressed. Nothing to travel to, and so nothing the
                            // pointer can slip off on the way.
                            PanelActionButton {
                                iconText: ""
                                tooltipText: entrySurface.armed ? "Click again to delete" : "Delete"
                                focusable: false
                                // An armed row wears the hover fill and border this
                                // button would have under the pointer, in urgent. The
                                // glyph itself does not change: the second press is on
                                // the same affordance as the first, which is what
                                // "again" in the prompt means.
                                hasCursor: entrySurface.armed
                                bordered: entrySurface.armed
                                fontFamily: root.fontFamily
                                hoverColor: Color.urgent
                                // The same gate the keyboard has, because it is the
                                // same function: the first press arms, and a second
                                // on the armed row commits.
                                onClicked: root.armOrDelete(row.id)
                            }
                        }
                    }
                }
            }
        }
    }
}
