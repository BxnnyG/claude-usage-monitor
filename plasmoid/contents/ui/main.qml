import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ---------- Konfiguration ----------
    readonly property int refreshSeconds: Math.max(2, Plasmoid.configuration.refreshSeconds)
    readonly property int warnPercent: Plasmoid.configuration.warnPercent
    readonly property int critPercent: Plasmoid.configuration.critPercent
    readonly property int staleMinutes: Plasmoid.configuration.staleMinutes
    readonly property bool showWeekly: Plasmoid.configuration.showWeekly
    readonly property bool showCountdown: Plasmoid.configuration.showCountdown

    readonly property string usageUrl: "https://claude.ai/settings/usage"
    // Fester Pfad, identisch zum Hook. Konstanter String -> keine Shell-Injection möglich.
    readonly property string readCommand: 'cat -- "$HOME/.cache/claude-usage/state.json"'

    // ---------- Zustand ----------
    property var usage: null          // geparste state.json oder null
    property string lastRaw: ""
    property bool parseError: false
    property real now: Date.now() / 1000

    readonly property var fiveHour: windowInfo("five_hour")
    readonly property var sevenDay: windowInfo("seven_day")
    readonly property var windowKeys: {
        if (!usage || !usage.windows)
            return []
        const order = ["five_hour", "seven_day", "spend_limit"]
        const keys = Object.keys(usage.windows)
        return order.filter(k => keys.includes(k)).concat(keys.filter(k => !order.includes(k)).sort())
    }
    readonly property bool dataStale: !!usage && !!usage.updated_at
                                      && (now - usage.updated_at) > staleMinutes * 60

    // ---------- Datei lesen ----------
    P5Support.DataSource {
        id: reader
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.handleOutput(data["exit code"], data["stdout"])
        }
    }

    Timer {
        interval: root.refreshSeconds * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.reload()
    }

    // Countdown/„vor X min“ weiterzählen, auch wenn die Datei selten gelesen wird
    Timer {
        interval: 30 * 1000
        running: true
        repeat: true
        onTriggered: root.now = Date.now() / 1000
    }

    // Beim Öffnen des Popups nicht auf den nächsten Timer-Tick warten
    onExpandedChanged: if (expanded) reload()

    function reload() {
        now = Date.now() / 1000
        reader.connectSource(readCommand)
    }

    function handleOutput(exitCode, stdout) {
        if (exitCode !== 0 || !stdout) {
            usage = null
            lastRaw = ""
            parseError = false
            return
        }
        if (stdout === lastRaw)
            return
        try {
            const parsed = JSON.parse(stdout)
            if (!parsed || typeof parsed.windows !== "object" || parsed.windows === null)
                throw new Error("windows fehlt")
            usage = parsed
            lastRaw = stdout
            parseError = false
        } catch (e) {
            // Alten Stand behalten; der Hook schreibt atomar, das sollte praktisch nie passieren.
            parseError = true
        }
    }

    // ---------- Aufbereitung ----------
    function windowInfo(key) {
        if (!usage || !usage.windows || !usage.windows[key])
            return null
        const w = usage.windows[key]
        const resetsAt = Number(w.resets_at) || 0
        const seenAt = Number(w.seen_at) || Number(usage.updated_at) || 0
        return {
            key: key,
            pct: Number(w.used_percentage),
            resetsAt: resetsAt,
            expired: resetsAt > 0 && resetsAt <= now,
            stale: (now - seenAt) > staleMinutes * 60
        }
    }

    function windowTitle(key) {
        switch (key) {
        case "five_hour": return i18n("Aktuelle Session (5 Stunden)")
        case "seven_day": return i18n("Woche (7 Tage)")
        case "spend_limit": return i18n("Ausgabenlimit")
        default: return key
        }
    }

    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        if (sec < 60)
            return i18n("unter 1 min")
        const d = Math.floor(sec / 86400)
        const h = Math.floor(sec % 86400 / 3600)
        const m = Math.floor(sec % 3600 / 60)
        if (d > 0)
            return i18n("%1 T %2 h", d, h)
        if (h > 0)
            return i18n("%1 h %2 min", h, m)
        return i18n("%1 min", m)
    }

    // Kurzform für die Leiste: "2T 4h", "1:23" (h:mm), "0:07"
    function fmtCountdown(info) {
        if (!info || info.expired || info.resetsAt <= 0)
            return ""
        const sec = Math.max(0, info.resetsAt - now)
        const d = Math.floor(sec / 86400)
        const h = Math.floor(sec % 86400 / 3600)
        const m = Math.ceil(sec % 3600 / 60)
        if (d > 0)
            return i18n("%1T %2h", d, h)
        if (m === 60)
            return (h + 1) + ":00"
        return h + ":" + (m < 10 ? "0" : "") + m
    }

    function fmtClock(epoch) {
        const dt = new Date(epoch * 1000)
        if (dt.toDateString() === new Date(now * 1000).toDateString())
            return Qt.formatTime(dt, "HH:mm")
        return Qt.formatDateTime(dt, "ddd HH:mm")
    }

    function detailText(info) {
        if (!info)
            return i18n("Keine Daten")
        if (info.expired)
            return i18n("Um %1 zurückgesetzt. Neuer Wert kommt mit der nächsten Antwort in Claude Code.",
                        fmtClock(info.resetsAt))
        if (info.resetsAt > 0)
            return i18n("Reset in %1, um %2", fmtDuration(info.resetsAt - now), fmtClock(info.resetsAt))
        return ""
    }

    function shortLine(label, info) {
        if (!info)
            return label + ": –"
        if (info.expired)
            return i18n("%1: zurückgesetzt", label)
        return i18n("%1: %2%3 % (Reset %4)", label, info.stale ? "≥ " : "", Math.round(info.pct), fmtClock(info.resetsAt))
    }

    readonly property string freshnessText: {
        if (!usage || !usage.updated_at)
            return ""
        return i18n("Letztes Update aus Claude Code: %1 (vor %2)",
                    fmtClock(usage.updated_at), fmtDuration(now - usage.updated_at))
    }

    // ---------- Plasmoid-Integration ----------
    Plasmoid.icon: "utilities-system-monitor"
    toolTipMainText: i18n("Claude-Nutzungslimit")
    toolTipSubText: {
        if (!usage)
            return i18n("Noch keine Daten. Claude Code starten und eine Nachricht schicken.")
        let lines = [shortLine("5h", fiveHour), shortLine("7d", sevenDay), freshnessText]
        if (dataStale)
            lines.push(i18n("Veraltet – Nutzung im Browser ist nicht enthalten."))
        return lines.join("\n")
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Nutzung auf claude.ai öffnen")
            icon.name: "internet-web-browser"
            onTriggered: Qt.openUrlExternally(root.usageUrl)
        },
        PlasmaCore.Action {
            text: i18n("Jetzt neu lesen")
            icon.name: "view-refresh"
            onTriggered: root.reload()
        }
    ]

    // ---------- Kontrollleiste ----------
    compactRepresentation: MouseArea {
        id: compact

        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical

        Layout.minimumWidth: vertical ? 0 : grid.implicitWidth
        Layout.preferredWidth: Layout.minimumWidth
        Layout.minimumHeight: vertical ? grid.implicitHeight : 0
        Layout.preferredHeight: Layout.minimumHeight

        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton)
                root.reload()
            else
                root.expanded = !root.expanded
        }

        GridLayout {
            id: grid
            anchors.centerIn: parent
            flow: compact.vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
            rowSpacing: Kirigami.Units.smallSpacing
            columnSpacing: Kirigami.Units.largeSpacing

            UsageChip {
                label: "5h"
                info: root.fiveHour
                countdown: root.showCountdown ? root.fmtCountdown(root.fiveHour) : ""
                warnPercent: root.warnPercent
                critPercent: root.critPercent
            }
            UsageChip {
                visible: root.showWeekly
                label: "7d"
                info: root.sevenDay
                warnPercent: root.warnPercent
                critPercent: root.critPercent
            }
        }
    }

    // ---------- Popup ----------
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.preferredWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: body.implicitHeight + Kirigami.Units.largeSpacing * 2
        Layout.preferredHeight: Layout.minimumHeight

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Heading {
                Layout.fillWidth: true
                level: 4
                text: i18n("Claude-Nutzungslimit")
            }

            PlasmaExtras.PlaceholderMessage {
                Layout.fillWidth: true
                visible: root.usage === null
                iconName: "utilities-system-monitor"
                text: i18n("Noch keine Daten")
                explanation: i18n("Claude Code starten und eine Nachricht schicken. Der statusLine-Hook schreibt die Limits dann nach ~/.cache/claude-usage/state.json.")
            }

            Repeater {
                model: root.windowKeys
                delegate: WindowRow {
                    required property string modelData
                    readonly property var winInfo: root.windowInfo(modelData)
                    title: root.windowTitle(modelData)
                    info: winInfo
                    detail: root.detailText(winInfo)
                    warnPercent: root.warnPercent
                    critPercent: root.critPercent
                }
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: root.usage !== null
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                text: root.freshnessText
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: root.dataStale
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.neutralTextColor
                text: i18n("Seitdem keine neuen Daten. Die Werte kommen nur aus Claude Code auf diesem Rechner – Nutzung im Browser, in der App oder in Claude Code im Web/in der Cloud fehlt, bis hier die nächste Claude-Code-Antwort kommt. Angezeigt ist deshalb nur ein Mindestwert (≥).")
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: root.parseError
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.negativeTextColor
                text: i18n("state.json ist nicht lesbar. Anzeige zeigt den letzten gültigen Stand.")
            }

            RowLayout {
                Layout.fillWidth: true

                PlasmaComponents.Button {
                    icon.name: "view-refresh"
                    text: i18n("Neu lesen")
                    onClicked: root.reload()
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Button {
                    icon.name: "internet-web-browser"
                    text: i18n("Auf claude.ai öffnen")
                    onClicked: Qt.openUrlExternally(root.usageUrl)
                }
            }
        }
    }
}
