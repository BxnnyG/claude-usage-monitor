import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Eine Zeile im Popup: Titel, Prozent, Fortschrittsbalken, Reset-Info.
ColumnLayout {
    id: row

    property string title
    property var info: null
    property string detail
    property int warnPercent: 70
    property int critPercent: 90

    readonly property bool hasValue: !!info && !info.expired
    readonly property real pct: hasValue ? info.pct : 0

    Layout.fillWidth: true
    spacing: Kirigami.Units.smallSpacing

    RowLayout {
        Layout.fillWidth: true

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: row.title
            elide: Text.ElideRight
        }
        PlasmaComponents.Label {
            text: row.hasValue ? Math.round(row.pct) + " %" : "–"
            font.bold: true
            color: !row.hasValue ? Kirigami.Theme.disabledTextColor
                 : row.pct >= row.critPercent ? Kirigami.Theme.negativeTextColor
                 : row.pct >= row.warnPercent ? Kirigami.Theme.neutralTextColor
                 : Kirigami.Theme.textColor
        }
    }

    PlasmaComponents.ProgressBar {
        Layout.fillWidth: true
        from: 0
        to: 100
        value: Math.min(100, row.pct)
        opacity: row.hasValue && !row.info.stale ? 1.0 : 0.5
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        visible: text.length > 0
        text: row.detail
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        opacity: 0.7
    }
}
