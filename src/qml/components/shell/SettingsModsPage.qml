pragma ComponentBehavior: Bound
import QtQuick
import Drift

// Settings > Mods: the user's mods folder, with a switch per mod.
SettingsPage {
    id: page

    pageId: "mods"
    title: qsTr("Mods")

    readonly property var mods: {
        void Mods.revision
        void Mods.errorRevision
        return Mods.mods
    }

    Text {
        width: parent.width
        visible: page.query.length === 0
        wrapMode: Text.WordWrap
        text: qsTr("Mods add to Drift's interface without reinstalling it. Each one is a folder inside your mods folder. They run with the same access to your computer as Drift itself, so only switch on mods you trust.")
        color: Theme.c.settingsRow.foregroundMuted
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeXs
    }

    SettingsRow {
        title: qsTr("Mods folder")
        description: Mods.folder
        keywords: "mod mods addon plugin extension folder directory open reload refresh"
        query: page.query

        Row {
            spacing: Theme.spacingSm

            ThemedButton {
                text: qsTr("Open folder")
                variant: "secondary"
                onClicked: Qt.openUrlExternally(Mods.folderUrl)
            }

            ThemedButton {
                text: qsTr("Reload")
                variant: "secondary"
                onClicked: Mods.reload()
            }
        }
    }

    Text {
        width: parent.width
        visible: page.mods.length === 0 && page.query.length === 0
        wrapMode: Text.WordWrap
        text: qsTr("No mods yet. Put a mod's folder into the mods folder and it will show up here.")
        color: Theme.c.settingsRow.foregroundMuted
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeXs
    }

    Repeater {
        model: page.mods

        delegate: SettingsRow {
            id: modRow

            required property var modelData

            readonly property string details: {
                const parts = []
                if (modelData.description.length > 0)
                    parts.push(modelData.description)
                const credit = []
                if (modelData.version.length > 0)
                    credit.push(qsTr("Version %1").arg(modelData.version))
                if (modelData.author.length > 0)
                    credit.push(qsTr("by %1").arg(modelData.author))
                if (credit.length > 0)
                    parts.push(credit.join(" "))
                if (modelData.hooks.length === 0)
                    parts.push(qsTr("Nothing to load: no hook files found."))
                for (const error of modelData.errors)
                    parts.push(qsTr("Problem: %1").arg(error))
                return parts.join("\n")
            }

            title: modelData.name
            description: modRow.details
            keywords: "mod " + modelData.id
            query: page.query

            ThemedSwitch {
                checked: modRow.modelData.enabled
                enabled: modRow.modelData.hooks.length > 0
                onToggled: Mods.setEnabled(modRow.modelData.id, checked)
            }
        }
    }
}
