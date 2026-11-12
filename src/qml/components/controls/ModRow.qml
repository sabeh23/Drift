pragma ComponentBehavior: Bound
import QtQuick
import Drift

// ModSlot for a row of controls (a toolbar): each mod's item keeps its own size and they sit
// side by side. Collapses to nothing when no mod uses the hook.
Row {
    id: root

    property string hook: ""
    property var host: null

    property bool _live: true
    readonly property var entries: {
        void Mods.revision
        return root._live && root.hook.length > 0 ? Mods.hookEntries(root.hook) : []
    }

    visible: root.entries.length > 0
    spacing: Theme.spacingXs

    Connections {
        target: Mods
        function onAboutToReload() { root._live = false }
        function onModsChanged() { root._live = true }
    }

    Repeater {
        model: root.entries

        delegate: Loader {
            id: loader

            required property var modelData

            anchors.verticalCenter: parent ? parent.verticalCenter : undefined
            asynchronous: false

            Component.onCompleted: setSource(modelData.url, { "host": root.host })

            onStatusChanged: {
                if (status !== Loader.Error)
                    return
                console.warn("Mod", modelData.modId, "failed to load its", root.hook, "hook")
                Mods.reportError(modelData.modId, root.hook,
                                 qsTr("could not be loaded. Check the file for errors."))
            }

            Binding {
                when: loader.item !== null && "host" in loader.item
                target: loader.item
                property: "host"
                value: root.host
            }
        }
    }
}
