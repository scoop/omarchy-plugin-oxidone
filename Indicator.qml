import QtQuick
import qs.Commons
import qs.Ui
import "src/state.js" as State

// The bar presence: absent when there is nothing outstanding.
//
// That absence is the point. A permanent count is wallpaper — you stop seeing
// it inside a week. A number that appears only when the day has something in it
// is worth looking at when it does, and an empty bar becomes the reward.
BarWidget {
    id: root

    property var service: bar && bar.shell ? bar.shell.serviceFor("scoop.oxidone") : null

    readonly property int outstanding: service ? service.outstanding : 0
    readonly property bool overdue: service ? service.overdue : false
    // The host injects bar/service via Qt.callLater, so service is null for at
    // least one event-loop turn on every shell start, theme change, monitor
    // hotplug and settings edit. That is "not wired yet", not "binary missing" —
    // defaulting to UNUSABLE would flash the attention glyph on every one of
    // those, which is the same cry-wolf mistake Service.qml's own OK-by-default
    // start exists to avoid.
    readonly property string state: service ? service.state : State.OK

    // Auth-needed and an unusable binary both need saying out loud: silence
    // there is indistinguishable from a clear day, which is the one thing the
    // bar must never get wrong.
    readonly property bool needsAttention: state === State.AUTH_NEEDED || state === State.UNUSABLE

    // Visible whenever there is something to say: work outstanding, or a state
    // that is not a clean answer. Silence has exactly one meaning — we asked,
    // and there is nothing due. A degraded widget that hides is indistinguishable
    // from a clear day, which is the one mistake this widget must not make.
    readonly property bool showing: state !== State.OK || outstanding > 0

    // One tone for the whole widget: the glyph and the count must never disagree
    // about what they are reporting.
    readonly property color tone: needsAttention || state === State.STALE ? Color.muted : (overdue ? Color.urgent : (bar ? bar.foreground : Color.foreground))

    implicitWidth: showing ? row.implicitWidth : 0
    implicitHeight: showing ? barSize : 0
    visible: showing

    function pushSettings() {
        if (!service) {
            return;
        }
        service.binaryPath = setting("binaryPath", "");
        service.pollIntervalSec = setting("pollIntervalSec", 300);
    }

    onSettingsChanged: pushSettings()
    onServiceChanged: pushSettings()
    Component.onCompleted: pushSettings()

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.xs

        Text {
            anchors.verticalCenter: parent.verticalCenter
            // nf-fa-tasks for the ordinary day; nf-fa-unlink when we cannot ask.
            // Not knowing is not the same alarm as having work to do, and must
            // never be mistaken for it.
            text: root.needsAttention ? "" : ""
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            color: root.tone
            textFormat: Text.PlainText
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.outstanding > 0 && !root.needsAttention
            text: String(root.outstanding)
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            // While the answer is Stale this count is the last thing we were
            // told, not what is true now. It should not look as certain as a
            // fresh one, and the glyph beside it already admits we cannot ask.
            color: root.tone
            textFormat: Text.PlainText
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.showing
        // Declaring the overlay kind moves this plugin off the bar-widget
        // summon path, so this resolves to Pane.qml rather than the widget.
        onClicked: if (bar && bar.shell) bar.shell.toggle("scoop.oxidone", "{}")
        onEntered: if (bar) bar.showTooltip(root, root.tooltipText())
        onExited: if (bar) bar.hideTooltip(root)
        hoverEnabled: true
    }

    function tooltipText() {
        if (state === State.UNUSABLE) {
            return "oxidone not found — needs 1.2.0 or newer";
        }
        if (state === State.AUTH_NEEDED) {
            return "oxidone is not authorized — click to open it";
        }
        if (state === State.STALE && service && service.lastSuccess > 0) {
            return outstanding + " due today — updated " + Qt.formatDateTime(new Date(service.lastSuccess), "HH:mm");
        }
        return outstanding + " due today";
    }
}
