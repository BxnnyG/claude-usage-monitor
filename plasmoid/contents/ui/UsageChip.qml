import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Ein Fenster (5h oder 7d) in der Kontrollleiste: "5h 42%" + dünner Balken.
ColumnLayout {
    id: chip

    property string label
    property var info: null        // Objekt aus main.qml windowInfo(), oder null
    property string countdown: ""  // z. B. "1:23"; leer = ausblenden
    property int warnPercent: 70
    property int critPercent: 90

    readonly property bool hasValue: !!info && !info.expired
    readonly property real pct: hasValue ? info.pct : 0
    readonly property color accent: !hasValue ? Kirigami.Theme.disabledTextColor
        : pct >= critPercent ? Kirigami.Theme.negativeTextColor
        : pct >= warnPercent ? Kirigami.Theme.neutralTextColor
        : Kirigami.Theme.highlightColor

    spacing: 2
    opacity: hasValue && info.stale ? 0.55 : 1.0

    RowLayout {
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label {
            text: chip.label
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
        PlasmaComponents.Label {
            // Feste Mindestbreite, damit die Leiste nicht zuckt, wenn 9% -> 10% wird
            Layout.minimumWidth: widest.advanceWidth
            horizontalAlignment: Text.AlignRight
            text: chip.hasValue ? Math.round(chip.pct) + "%" : "–"
            font.bold: chip.hasValue && chip.pct >= chip.warnPercent
            color: chip.hasValue && chip.pct >= chip.warnPercent ? chip.accent : Kirigami.Theme.textColor

            TextMetrics {
                id: widest
                font.bold: true
                text: "100%"
            }
        }
        PlasmaComponents.Label {
            visible: chip.hasValue && chip.countdown.length > 0
            text: "↻ " + chip.countdown
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 3
        radius: height / 2
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                       Kirigami.Theme.textColor.b, 0.15)

        Rectangle {
            width: parent.width * Math.min(100, chip.pct) / 100
            height: parent.height
            radius: parent.radius
            color: chip.accent
        }
    }
}
