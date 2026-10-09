import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

// Live view and settings for the webcam presence sensor. Opened in its own
// window (plasmawindowed asus-presence), or shown as a pair of eyes in the
// system tray. The full view only polls while shown; the tray icon long-polls
// (`asus-presence-ctl wait`), which blocks until the status changes.
PlasmoidItem {
    id: root

    readonly property string ctl: "/usr/local/bin/asus-presence-ctl"
    readonly property int historySeconds: 120

    property var st: ({})
    property var history: []        // [{t, distance, present, attention}]
    property bool busy: false
    property string lastError: ""
    property string trayStatus: "off"   // looking, present, away, starting, paused, standby, off
    property string trayEnabled: ""     // "on"/"off" once known; whether the tray shows us

    readonly property var sensor: st.sensor || {}
    readonly property var agent: st.agent || {}
    readonly property var cfg: agent.config || {}
    readonly property bool serviceOn: st.service === "active"
    readonly property bool ready: serviceOn && sensor.sensor_ready === true

    // Own window (plasmawindowed: Application) or on the desktop (Planar): the full
    // view. In a panel or the system tray: the eyes.
    readonly property bool inWindow: Plasmoid.formFactor === PlasmaCore.Types.Application
                                     || Plasmoid.formFactor === PlasmaCore.Types.Planar
    readonly property var statusTexts: ({
        looking: "Looking at the screen", present: "Present, looking away", away: "Away",
        starting: "Starting sensor…", paused: "Paused while you use the computer",
        standby: "Sensor in standby", off: "Sensor off"
    })

    preferredRepresentation: inWindow ? fullRepresentation : compactRepresentation
    Plasmoid.icon: "view-visible-symbolic"
    Plasmoid.status: PlasmaCore.Types.ActiveStatus   // always visible once added to the tray
    toolTipMainText: "Presence Sensor"
    toolTipSubText: statusTexts[trayStatus] || ""

    // Tray icon: wait for the next status change, then wait again.
    function watch() {
        if (!inWindow) {
            watcher.connectSource(ctl + " wait " + trayStatus);
        }
    }
    Component.onCompleted: watch()
    onInWindowChanged: watch()

    Plasma5Support.DataSource {
        id: watcher
        engine: "executable"
        interval: 0
        onNewData: function(source, data) {
            disconnectSource(source);
            const word = (data["stdout"] || "").toString().trim();
            if (word.length > 0 && !data["exit code"]) {
                root.trayStatus = word;
                root.watch();
            } else {
                retry.start();   // e.g. not installed yet: try again later
            }
        }
    }
    Timer {
        id: retry
        interval: 30000
        onTriggered: root.watch()
    }

    compactRepresentation: MouseArea {
        id: compact
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        // Two eyes: open and looking at you, glancing aside, or closed (away);
        // faded while the sensor is not reporting (open while paused: you are here).
        readonly property bool open: root.trayStatus === "looking" || root.trayStatus === "present"
                                     || root.trayStatus === "starting" || root.trayStatus === "paused"
        readonly property real glance: root.trayStatus === "present" ? 1 : 0
        readonly property real s: Math.min(width, height) * 0.9
        opacity: root.trayStatus === "looking" || root.trayStatus === "present" || root.trayStatus === "away" ? 1 : 0.45

        Row {
            anchors.centerIn: parent
            spacing: compact.s * 0.1
            Repeater {
                model: 2
                Item {
                    width: compact.s * 0.4
                    height: compact.s * 0.62
                    Rectangle {   // eye
                        anchors.fill: parent
                        visible: compact.open
                        radius: width / 2
                        color: "transparent"
                        border.width: Math.max(1, compact.s * 0.07)
                        border.color: Kirigami.Theme.textColor
                        Rectangle {   // pupil; glancing aside keeps it inside the outline
                            width: parent.width * 0.4
                            height: width
                            radius: width / 2
                            color: Kirigami.Theme.textColor
                            y: parent.height * 0.5 - height * 0.35
                            x: (parent.width - width) / 2
                               + compact.glance * ((parent.width - width) / 2 - parent.border.width * 1.5)
                            Behavior on x { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                        }
                    }
                    Rectangle {   // closed lid
                        visible: !compact.open
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: Math.max(1, compact.s * 0.07)
                        radius: height / 2
                        color: Kirigami.Theme.textColor
                    }
                }
            }
        }
    }

    function refresh() {
        runner.connectSource(ctl + " get");
    }

    function refreshTray() {
        runner.connectSource(ctl + " tray get");
    }

    function run(command) {
        busy = true;
        runner.connectSource(command);
    }

    function setting(key, value) {
        run(ctl + " set " + key + " " + value);
    }

    function ago(t) {
        if (!t) {
            return "";
        }
        const s = Math.max(0, Math.round(Date.now() / 1000 - t));
        return s < 60 ? s + " s ago" : s < 3600 ? Math.round(s / 60) + " min ago" : Math.round(s / 3600) + " h ago";
    }

    function statusText() {
        if (!serviceOn) {
            return "Sensor service is off";
        }
        if (sensor.mode === "standby") {
            return "Sensor in standby";
        }
        if (sensor.mode === "paused") {
            return "Paused while you use the computer";
        }
        if (!sensor.sensor_ready) {
            return "Starting sensor…";
        }
        if (!sensor.present) {
            return "Away";
        }
        return sensor.attention ? "Present · looking at the screen" : "Present · looking away";
    }

    function since() {
        if (!ready) {
            return "";
        }
        if (!sensor.present) {
            return "since " + ago(sensor.away_since);
        }
        return sensor.attention ? "since " + ago(sensor.attention_since) : "since " + ago(sensor.looking_away_since);
    }

    Plasma5Support.DataSource {
        id: runner
        engine: "executable"
        interval: 0
        onNewData: function(source, data) {
            runner.disconnectSource(source);
            const out = (data["stdout"] || "").toString();
            if (source === root.ctl + " tray get") {
                root.trayEnabled = data["exit code"] ? "" : out.trim();
            } else if (source === root.ctl + " get") {
                try {
                    root.st = JSON.parse(out);
                    const s = root.st.sensor || {};
                    const now = Date.now() / 1000;
                    const h = root.history.filter(p => now - p.t < root.historySeconds);
                    h.push({ t: now, distance: s.sensor_ready && s.present ? s.distance_mm : null,
                             present: !!(s.sensor_ready && s.present), attention: !!(s.sensor_ready && s.attention),
                             dimmed: !!(root.st.agent && root.st.agent.dimmed) });
                    root.history = h;
                } catch (e) {
                    root.lastError = "Could not read state: " + e;
                }
            } else {
                root.busy = false;
                root.lastError = data["exit code"] ? (data["stderr"] || "").toString().trim() : "";
                root.refresh();
                if (source.indexOf(root.ctl + " tray ") === 0) {
                    root.refreshTray();
                }
            }
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.preferredWidth: Kirigami.Units.gridUnit * 26
        Layout.minimumHeight: content.implicitHeight + header.implicitHeight + Kirigami.Units.largeSpacing * 2
        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            id: header
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Heading {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    text: "Presence Sensor"
                    level: 1
                }
                PlasmaComponents3.BusyIndicator {
                    visible: root.busy
                    running: root.busy
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
                PlasmaComponents3.Switch {
                    Layout.rightMargin: Kirigami.Units.smallSpacing
                    text: "Sensor service"
                    checked: root.serviceOn
                    enabled: !root.busy
                    // Enabling a system service asks for authentication (polkit).
                    onToggled: root.run("systemctl " + (checked ? "enable --now" : "disable --now")
                                        + " asus-presence.service")
                }
            }
        }

        // Test tool: poll only while this view is actually shown.
        Timer {
            interval: 500
            repeat: true
            running: content.visible && content.Window.window !== null && content.Window.window.visible
            triggeredOnStart: true
            onTriggered: root.refresh()
            onRunningChanged: if (running) root.refreshTray()
        }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing * 2

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.lastError.length > 0
                type: Kirigami.MessageType.Error
                text: root.lastError
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.st.agent_service !== undefined && root.st.agent_service !== "active"
                type: Kirigami.MessageType.Warning
                text: "The presence agent is not running, so nothing will lock or dim. Start it with: systemctl --user enable --now asus-presence-agent"
            }

            // Live status -------------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.gridUnit

                Kirigami.Icon {
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    source: !root.ready ? "camera-web-symbolic"
                          : !root.sensor.present ? "user-away-symbolic"
                          : root.sensor.attention ? "view-visible-symbolic" : "view-hidden-symbolic"
                    opacity: root.ready ? 1 : 0.5
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing / 2

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: root.statusText()
                            font.weight: Font.DemiBold
                        }
                        PlasmaComponents3.Label {
                            visible: root.ready && root.sensor.present
                            text: root.sensor.distance_mm ? Math.round(root.sensor.distance_mm / 10) + " cm" : ""
                            opacity: 0.7
                        }
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: [root.since(),
                               root.sensor.sensor ? root.sensor.sensor + " · " + root.sensor.rate_hz + " Hz · " + root.sensor.mode : ""]
                              .filter(t => t.length > 0).join("  ·  ")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        elide: Text.ElideRight
                    }
                }
            }

            // History -----------------------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Canvas {
                    id: graph
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 6
                    readonly property real maxMm: 1500
                    readonly property var points: root.history
                    onPointsChanged: requestPaint()

                    onPaint: {
                        const ctx = getContext("2d");
                        const w = width, h = height, band = Kirigami.Units.smallSpacing * 1.5;
                        const plotH = h - 2 * band - 2;
                        ctx.reset();
                        const now = Date.now() / 1000;
                        const x = t => w - (now - t) / root.historySeconds * w;
                        const tc = Kirigami.Theme.textColor;
                        // frame and 50 cm / 100 cm guides
                        ctx.strokeStyle = Qt.rgba(tc.r, tc.g, tc.b, 0.15);
                        ctx.lineWidth = 1;
                        for (const mm of [500, 1000]) {
                            const y = plotH - mm / maxMm * plotH;
                            ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
                        }
                        const pts = root.history;
                        // presence / attention / dimmed bands along the bottom
                        for (let i = 1; i < pts.length; i++) {
                            const x0 = x(pts[i - 1].t), x1 = x(pts[i].t);
                            if (pts[i].present) {
                                ctx.fillStyle = Qt.rgba(Kirigami.Theme.positiveTextColor.r, Kirigami.Theme.positiveTextColor.g, Kirigami.Theme.positiveTextColor.b, 0.6);
                                ctx.fillRect(x0, plotH + 2, x1 - x0, band);
                            }
                            if (pts[i].attention) {
                                ctx.fillStyle = Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.6);
                                ctx.fillRect(x0, plotH + 2 + band, x1 - x0, band);
                            }
                        }
                        // distance line
                        ctx.strokeStyle = Kirigami.Theme.highlightColor;
                        ctx.lineWidth = 2;
                        ctx.beginPath();
                        let drawing = false;
                        for (const p of pts) {
                            if (p.distance === null || p.distance === undefined) { drawing = false; continue; }
                            const y = plotH - Math.min(p.distance, maxMm) / maxMm * plotH;
                            if (drawing) { ctx.lineTo(x(p.t), y); } else { ctx.moveTo(x(p.t), y); drawing = true; }
                        }
                        ctx.stroke();
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: "Distance (lines at 50 and 100 cm) · green: present · blue: looking"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        elide: Text.ElideRight
                    }
                    PlasmaComponents3.Label {
                        text: "last 2 min"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                    }
                }
            }

            // Sample rate --------------------------------------------------
            // Applied live by the sensor service (through the agent). Presence and
            // attention must hold for two samples, so the rate sets how fast it reacts.
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.gridUnit

                Kirigami.Icon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    source: "speedometer"
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing / 2

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: "Sensor updates"
                        }
                        PlasmaComponents3.ComboBox {
                            id: rateBox
                            enabled: !root.busy
                            textRole: "text"
                            valueRole: "value"
                            model: [
                                { text: "Every 2 s (0.5 Hz)", value: 0.5 },
                                { text: "Every second (1 Hz)", value: 1 },
                                { text: "2 per second (2 Hz)", value: 2 },
                                { text: "5 per second (5 Hz)", value: 5 },
                                { text: "10 per second (10 Hz)", value: 10 }
                            ]
                            readonly property real configured: root.cfg.sample_rate || 2
                            // Not indexOfValue(): it runs before the model is loaded and is not re-evaluated.
                            currentIndex: Math.max(0, model.findIndex(r => r.value === configured))
                            onActivated: root.setting("sample_rate", currentValue)
                        }
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        readonly property real rate: rateBox.configured
                        readonly property bool pending: root.serviceOn && root.sensor.mode === "active"
                                                        && root.sensor.rate_hz !== undefined
                                                        && Math.abs(root.sensor.rate_hz - rate) > 0.01
                        text: (pending ? "Applying… · " : "")
                              + "Reacts in about " + (Math.round(20 / rate) / 10) + " s"
                              + (rate > 2 ? " · uses more power" : rate < 2 ? " · saves a little power" : "")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        elide: Text.ElideRight
                    }
                    RowLayout {
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        enabled: !root.busy
                        PlasmaComponents3.CheckBox {
                            text: "Only when idle: turn it on after"
                            checked: root.cfg.only_when_idle === true
                            onToggled: root.setting("only_when_idle", checked)
                        }
                        PlasmaComponents3.SpinBox {
                            from: 5; to: 300; stepSize: 5
                            enabled: root.cfg.only_when_idle === true
                            value: root.cfg.idle_after || 30
                            onValueModified: root.setting("idle_after", value)
                        }
                        PlasmaComponents3.Label { text: "s without input" }
                    }
                    PlasmaComponents3.CheckBox {
                        text: "Show the status in the system tray"
                        visible: root.trayEnabled !== ""
                        enabled: !root.busy
                        checked: root.trayEnabled === "on"
                        onToggled: root.run(root.ctl + " tray " + (checked ? "on" : "off"))
                    }
                }
            }

            // Agent -------------------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.gridUnit

                Kirigami.Icon {
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    source: "system-lock-screen-symbolic"
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: "Adaptive lock and dimming"
                        }
                        PlasmaComponents3.Switch {
                            checked: root.cfg.enabled !== false
                            enabled: !root.busy
                            onToggled: root.setting("enabled", checked)
                        }
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: [root.agent.screen_off ? "Screen turned off (you are away)" : "",
                               root.agent.dimmed ? "Screen dimmed by presence" : "",
                               root.agent.screen_held ? "Keeping the screen on"
                                   : root.agent.sleep_held ? "Preventing sleep" : "",
                               root.agent.last_action ? "Last: " + root.agent.last_action + " (" + root.ago(root.agent.last_action_at) + ")" : "No actions yet",
                               root.agent.inhibited ? "Paused: an app is inhibiting idle" : ""]
                              .filter(t => t.length > 0).join("  ·  ")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        wrapMode: Text.Wrap
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        columns: 3
                        columnSpacing: Kirigami.Units.smallSpacing
                        rowSpacing: Kirigami.Units.smallSpacing
                        enabled: root.cfg.enabled !== false && !root.busy

                        PlasmaComponents3.CheckBox {
                            text: "Lock when away for"
                            checked: root.cfg.lock !== false
                            onToggled: root.setting("lock", checked)
                        }
                        PlasmaComponents3.SpinBox {
                            from: 10; to: 3600; stepSize: 10
                            value: root.cfg.lock_after || 60
                            onValueModified: root.setting("lock_after", value)
                        }
                        PlasmaComponents3.Label { text: "seconds" }

                        PlasmaComponents3.CheckBox {
                            text: "Turn the screen off when away for"
                            checked: root.cfg.screen_off !== false
                            onToggled: root.setting("screen_off", checked)
                        }
                        PlasmaComponents3.SpinBox {
                            from: 10; to: 3600; stepSize: 10
                            value: root.cfg.screen_off_after || 60
                            onValueModified: root.setting("screen_off_after", value)
                        }
                        PlasmaComponents3.Label { text: "seconds" }

                        PlasmaComponents3.CheckBox {
                            text: "Dim when looking away for"
                            checked: root.cfg.dim !== false
                            onToggled: root.setting("dim", checked)
                        }
                        PlasmaComponents3.SpinBox {
                            from: 3; to: 600
                            value: root.cfg.dim_after || 10
                            onValueModified: root.setting("dim_after", value)
                        }
                        PlasmaComponents3.Label { text: "seconds" }

                        PlasmaComponents3.Label {
                            Layout.alignment: Qt.AlignRight
                            text: "Dim to"
                        }
                        PlasmaComponents3.SpinBox {
                            from: 5; to: 90; stepSize: 5
                            value: root.cfg.dim_level || 30
                            onValueModified: root.setting("dim_level", value)
                        }
                        PlasmaComponents3.Label { text: "% brightness" }

                        PlasmaComponents3.CheckBox {
                            Layout.columnSpan: 3
                            text: "Keep the screen on while I'm looking at it"
                            checked: root.cfg.keep_screen_on !== false
                            onToggled: root.setting("keep_screen_on", checked)
                        }

                        // Keeping the screen on also blocks sleep (Plasma ties the two),
                        // so this only matters on its own.
                        PlasmaComponents3.CheckBox {
                            Layout.columnSpan: 3
                            readonly property bool implied: root.cfg.keep_screen_on !== false
                            text: implied ? "Don't sleep while I'm looking at the screen (included above)"
                                          : "Don't sleep while I'm looking at the screen"
                            enabled: !implied
                            checked: implied || root.cfg.prevent_sleep !== false
                            onToggled: root.setting("prevent_sleep", checked)
                        }

                        PlasmaComponents3.CheckBox {
                            Layout.columnSpan: 3
                            text: "Wake the screen when I return (keeps the sensor on while locked)"
                            checked: root.cfg.wake_on_return === true
                            onToggled: root.setting("wake_on_return", checked)
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }
    }
}
