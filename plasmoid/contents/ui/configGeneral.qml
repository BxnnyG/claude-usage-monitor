import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_refreshSeconds: refreshSpin.value
    property alias cfg_warnPercent: warnSpin.value
    property alias cfg_critPercent: critSpin.value
    property alias cfg_staleMinutes: staleSpin.value
    property alias cfg_showWeekly: weeklyCheck.checked

    Kirigami.FormLayout {
        QQC2.SpinBox {
            id: refreshSpin
            Kirigami.FormData.label: i18n("Datei lesen alle (Sekunden):")
            from: 2
            to: 600
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: warnSpin
            Kirigami.FormData.label: i18n("Gelb ab (%):")
            from: 1
            to: 100
        }
        QQC2.SpinBox {
            id: critSpin
            Kirigami.FormData.label: i18n("Rot ab (%):")
            from: 1
            to: 100
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: staleSpin
            Kirigami.FormData.label: i18n("Abblenden nach (Minuten ohne Update):")
            from: 1
            to: 1440
        }
        QQC2.CheckBox {
            id: weeklyCheck
            Kirigami.FormData.label: i18n("Kontrollleiste:")
            text: i18n("7-Tage-Wert anzeigen")
        }
    }
}
