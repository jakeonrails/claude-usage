import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

// KDE frontend for the shared claude-usage CLI: polls `claude-usage --json`
// (cache-first — see CLI.swift) and renders the same 5-hour/weekly windows
// and color gradient as the macOS menubar app.
PlasmoidItem {
    id: root

    // Parsed --json report (see CLI.swift Report), or null before first poll.
    property var report: null
    property bool notConnected: false
    property string lastError: ""

    // MARK: Color — mirrors UsageColor.swift's HSL gradient stops.
    readonly property bool darkTheme: {
        const bg = Kirigami.Theme.backgroundColor
        return (0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b) < 0.5
    }

    function usageColor(pct) {
        const yellow = darkTheme ? { h: 52, s: 0.95, l: 0.50 }
                                 : { h: 48, s: 0.95, l: 0.38 }
        const stops = [
            [0,   { h: 120, s: 0.65, l: 0.42 }],  // green
            [50,  yellow],                        // yellow / amber
            [70,  { h: 32,  s: 0.95, l: 0.50 }],  // orange
            [90,  { h: 0,   s: 0.90, l: 0.50 }],  // red
            [100, { h: 0,   s: 0.80, l: 0.32 }],  // dark red
        ]
        const p = Math.max(0, Math.min(100, pct))
        let lo = stops[0], hi = stops[stops.length - 1]
        for (let i = 0; i < stops.length - 1; i++) {
            if (p >= stops[i][0] && p <= stops[i + 1][0]) {
                lo = stops[i]; hi = stops[i + 1]; break
            }
        }
        const span = hi[0] - lo[0]
        const t = span === 0 ? 0 : (p - lo[0]) / span
        const mix = (a, b) => a + (b - a) * t
        return Qt.hsla(mix(lo[1].h, hi[1].h) / 360,
                       mix(lo[1].s, hi[1].s),
                       mix(lo[1].l, hi[1].l), 1)
    }

    // MARK: Derived state (mirrors UsageStore.menubarLabel semantics)
    readonly property var fiveHour: report ? report.five_hour : null
    readonly property bool fiveHourActive: fiveHour !== null && fiveHour.active
    readonly property real usedPercent: fiveHourActive ? fiveHour.used_percent : 0

    readonly property string compactText: {
        if (notConnected) return "🔗"
        if (fiveHourActive) return Math.round(usedPercent) + "%"
        if (report) return "0%"
        if (lastError) return "!"
        return "…"
    }
    readonly property color compactColor: {
        if (notConnected) return Kirigami.Theme.disabledTextColor
        if (fiveHourActive && Math.round(usedPercent) > 0) return usageColor(usedPercent)
        if (!report && lastError) return Kirigami.Theme.negativeTextColor
        return Kirigami.Theme.textColor
    }

    function fmtDuration(seconds) {
        if (seconds === null || seconds === undefined) return ""
        const s = Math.max(0, Math.round(seconds))
        const d = Math.floor(s / 86400)
        const h = Math.floor((s % 86400) / 3600)
        const m = Math.floor((s % 3600) / 60)
        if (d > 0) return d + "d " + h + "h"
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }

    function windowSubtitle(w) {
        if (!w) return ""
        if (!w.active) return i18n("No active window")
        return i18n("resets in %1", fmtDuration(w.remaining_seconds))
    }

    // MARK: Calendar grid marks — the QML port of PopoverView.calendarMarks.
    // Session bar: a mark at every whole top-of-hour inside the window, plus
    // the reset instant labeling the right edge (snapped to the plain hour
    // within 5 min, minute-precise otherwise). Weekly bars: a mark at every
    // local midnight, labeled with the short weekday.
    function fmtHour(d) {
        const h = d.getHours()
        let hh = h % 12
        if (hh === 0) hh = 12
        return hh + (h < 12 ? "a" : "p")
    }

    function fmtClock(d) {
        const m = d.getMinutes()
        if (m <= 5) return fmtHour(d)
        if (m >= 55) return fmtHour(new Date(d.getTime() + 3600 * 1000))
        return fmtHour(d).slice(0, -1) + ":" + (m < 10 ? "0" : "") + m
            + (d.getHours() < 12 ? "a" : "p")
    }

    function calendarMarks(w) {
        if (!w || !w.active || !w.resets_at) return []
        const reset = new Date(w.resets_at)
        if (isNaN(reset.getTime())) return []
        const durMs = w.window_seconds * 1000
        const start = new Date(reset.getTime() - durMs)
        const marks = []

        if (w.window_seconds <= 6 * 3600) {
            // Right edge always labels the reset instant (no hash: the bar's
            // own edge is the mark).
            marks.push({ frac: 1, label: fmtClock(reset), hash: false })
            // Left edge labels the start when it sits on/near a whole hour.
            const startIsWhole = start.getMinutes() <= 5 || start.getMinutes() >= 55
            if (startIsWhole) marks.push({ frac: 0, label: fmtClock(start), hash: false })

            const t = new Date(start)
            t.setMinutes(0, 0, 0)
            if (t <= start) t.setHours(t.getHours() + 1)
            for (; t < reset; t.setHours(t.getHours() + 1)) {
                const frac = (t.getTime() - start.getTime()) / durMs
                // Drop interior marks that would crowd an edge label.
                if (frac > 0.9 || (startIsWhole && frac < 0.1)) continue
                marks.push({ frac: frac, label: fmtHour(t), hash: true })
            }
        } else {
            const t = new Date(start)
            t.setHours(0, 0, 0, 0)
            if (t <= start) t.setDate(t.getDate() + 1)
            for (; t < reset; t.setDate(t.getDate() + 1)) {
                const frac = (t.getTime() - start.getTime()) / durMs
                marks.push({
                    frac: frac,
                    label: Qt.locale().dayName(t.getDay(), Locale.ShortFormat),
                    hash: true,
                })
            }
        }
        return marks
    }

    // MARK: Polling
    readonly property string pollCommand: {
        const conf = Plasmoid.configuration.binaryPath
        const pick = conf && conf.length > 0
            ? 'BIN=' + '"' + conf + '"'
            : 'BIN="$HOME/.local/bin/claude-usage"; [ -x "$BIN" ] || BIN="$(command -v claude-usage || true)"'
        return 'sh -c \'' + pick + '; if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then echo "claude-usage binary not found" >&2; exit 127; fi; exec "$BIN" --json --max-age 360\''
    }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            const code = data["exit code"]
            const stdout = data.stdout || ""
            const stderr = data.stderr || ""
            if (code === 2) {
                root.notConnected = true
                root.report = null
                root.lastError = ""
                return
            }
            root.notConnected = false
            // Exit 3 = stale cache + error; stdout still carries a report.
            if (stdout.trim().startsWith("{")) {
                try {
                    root.report = JSON.parse(stdout)
                    root.lastError = root.report.error || ""
                    return
                } catch (e) {
                    root.lastError = "bad JSON from claude-usage: " + e
                    return
                }
            }
            root.lastError = (stderr || stdout || ("exit " + code)).trim()
        }
    }

    function poll() { exec.connectSource(pollCommand) }

    Timer {
        interval: Math.max(30, Plasmoid.configuration.pollInterval) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.poll()
    }
    // Re-poll when the popup opens so the numbers are current while visible.
    onExpandedChanged: if (expanded) poll()

    toolTipMainText: i18n("Claude Usage")
    toolTipSubText: {
        if (notConnected) return i18n("Not connected — run: claude-usage connect")
        if (fiveHourActive) return i18n("Session: %1% used · %2", Math.round(usedPercent), windowSubtitle(fiveHour))
        if (report) return i18n("Between sessions — 0% used")
        return lastError || i18n("Loading…")
    }

    preferredRepresentation: compactRepresentation

    compactRepresentation: MouseArea {
        implicitWidth: compactLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
        implicitHeight: compactLabel.implicitHeight
        onClicked: root.expanded = !root.expanded

        PC3.Label {
            id: compactLabel
            anchors.centerIn: parent
            text: root.compactText
            color: root.compactColor
            font.bold: root.fiveHourActive && Math.round(root.usedPercent) > 0
        }
    }

    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        implicitWidth: content.implicitWidth + content.anchors.leftMargin + content.anchors.rightMargin
        implicitHeight: content.implicitHeight

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.largeSpacing
            anchors.rightMargin: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading {
                    level: 3
                    text: i18n("Claude Usage")
                    Layout.fillWidth: true
                }
                PC3.ToolButton {
                    icon.name: "view-refresh"
                    display: PC3.AbstractButton.IconOnly
                    text: i18n("Refresh")
                    onClicked: root.poll()
                    PC3.ToolTip.text: text
                    PC3.ToolTip.visible: hovered
                }
            }

            // Not-connected state: point at the terminal connect flow.
            ColumnLayout {
                visible: root.notConnected
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                PC3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: i18n("Connect your Claude account from a terminal:")
                }
                PC3.TextField {
                    Layout.fillWidth: true
                    readOnly: true
                    text: "claude-usage connect"
                    font.family: "monospace"
                }
            }

            // Usage sections, one per window the API exposes.
            Repeater {
                model: root.report ? [
                    { title: i18n("Session (5h)"),   w: root.report.five_hour },
                    { title: i18n("Weekly"),          w: root.report.seven_day },
                    { title: i18n("Weekly · Fable"),  w: root.report.seven_day_fable },
                    { title: i18n("Weekly · Opus"),   w: root.report.seven_day_opus },
                    { title: i18n("Weekly · Sonnet"), w: root.report.seven_day_sonnet },
                ].filter(s => s.w !== null && s.w !== undefined) : []

                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing / 2

                    RowLayout {
                        Layout.fillWidth: true
                        PC3.Label {
                            text: modelData.title
                            font.bold: true
                            Layout.fillWidth: true
                        }
                        PC3.Label {
                            text: modelData.w.active
                                ? i18n("%1% used", Math.round(modelData.w.used_percent))
                                : i18n("0% used")
                            color: modelData.w.active
                                ? root.usageColor(modelData.w.used_percent)
                                : Kirigami.Theme.disabledTextColor
                        }
                    }

                    // Usage bar with a "you are here" time tick, like UsageGauge:
                    // fill ahead of the tick = burning quota faster than the clock.
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: Math.round(Kirigami.Units.gridUnit / 3)

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            color: Qt.alpha(Kirigami.Theme.textColor, 0.15)
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            radius: height / 2
                            width: parent.width * Math.min(1, Math.max(0, modelData.w.used_percent / 100))
                            color: root.usageColor(modelData.w.used_percent)
                            visible: modelData.w.active
                        }
                        // "You are here" time tick, mirroring UsageGauge: overhangs
                        // the bar and sits on a background-colored halo so it stays
                        // legible over both the colored fill and the empty track.
                        Rectangle {
                            visible: modelData.w.active && modelData.w.elapsed_seconds !== null
                            width: 8
                            radius: 2
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.topMargin: -4
                            anchors.bottomMargin: -4
                            x: parent.width * Math.min(1, Math.max(0,
                                modelData.w.elapsed_seconds / modelData.w.window_seconds)) - 4
                            color: Kirigami.Theme.backgroundColor

                            Rectangle {
                                anchors.centerIn: parent
                                width: 4
                                height: parent.height - 2
                                radius: 1
                                color: Kirigami.Theme.textColor
                            }
                        }
                    }

                    // Calendar labels under the bar (hours for the session
                    // window, weekdays for weekly ones), like the macOS gauges.
                    Item {
                        id: marksStrip
                        property var marks: root.calendarMarks(modelData.w)
                        visible: marks.length > 0
                        Layout.fillWidth: true
                        implicitHeight: visible
                            ? Kirigami.Units.smallSpacing + Math.round(Kirigami.Theme.smallFont.pointSize * 1.9)
                            : 0

                        Repeater {
                            model: marksStrip.marks
                            delegate: Item {
                                required property var modelData

                                Rectangle {
                                    visible: parent.modelData.hash
                                    width: 1
                                    height: 3
                                    x: marksStrip.width * parent.modelData.frac
                                    y: 0
                                    color: Kirigami.Theme.textColor
                                    opacity: 0.4
                                }
                                PC3.Label {
                                    text: parent.modelData.label
                                    font.pointSize: Math.round(Kirigami.Theme.smallFont.pointSize * 0.85)
                                    opacity: 0.55
                                    y: 4
                                    x: Math.min(
                                        Math.max(0, marksStrip.width * parent.modelData.frac - width / 2),
                                        marksStrip.width - width)
                                }
                            }
                        }
                    }

                    PC3.Label {
                        text: root.windowSubtitle(modelData.w)
                        opacity: 0.7
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }

            // Extra usage (pay-per-use overflow), when the plan exposes it.
            RowLayout {
                visible: root.report !== null && root.report.extra_usage !== null
                    && root.report.extra_usage !== undefined && root.report.extra_usage.enabled === true
                Layout.fillWidth: true
                PC3.Label {
                    text: i18n("Extra usage")
                    font.bold: true
                    Layout.fillWidth: true
                }
                PC3.Label {
                    text: root.report && root.report.extra_usage
                          && root.report.extra_usage.used_percent !== null
                        ? i18n("%1% used", Math.round(root.report.extra_usage.used_percent)) : "—"
                }
            }

            Kirigami.Separator { Layout.fillWidth: true; visible: !root.notConnected }

            PC3.Label {
                visible: !root.notConnected
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: {
                    if (root.lastError) return i18n("⚠ %1", root.lastError)
                    if (!root.report) return i18n("Loading…")
                    const age = root.report.age_seconds
                    return i18n("Updated %1 ago", root.fmtDuration(age))
                }
            }
        }
    }
}
