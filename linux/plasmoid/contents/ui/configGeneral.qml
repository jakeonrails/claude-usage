import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_pollInterval: pollInterval.value
    property alias cfg_binaryPath: binaryPath.text

    Kirigami.FormLayout {
        QQC2.SpinBox {
            id: pollInterval
            Kirigami.FormData.label: i18n("Poll every:")
            from: 30
            to: 3600
            stepSize: 30
            textFromValue: (value) => i18n("%1 s", value)
            valueFromText: (text) => parseInt(text)
        }
        QQC2.TextField {
            id: binaryPath
            Kirigami.FormData.label: i18n("claude-usage binary:")
            placeholderText: i18n("auto (~/.local/bin, then $PATH)")
        }
    }
}
