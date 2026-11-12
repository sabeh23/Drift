pragma ComponentBehavior: Bound
import QtQuick
import Drift

// A hook point for user mods (see ModManager): loads, on top of whatever it is placed over, the
// file each enabled mod provides for `hook`, and hands it `host`. It draws nothing and takes no
// input itself, so with no mods the interface underneath is untouched.
Item {
    id: root

    property string hook: ""
    property var host: null

    // Emptied while the files are re-read, so every loaded item is gone before the engine drops
    // the components they were made from.
    property bool _live: true
    readonly property var entries: {
        void Mods.revision
        return root._live && root.hook.length > 0 ? Mods.hookEntries(root.hook) : []
    }

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

            anchors.fill: parent
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
