import QtQuick
import Drift
import "layout.js" as Layout

// One per panel slot. Adds a small grip at the top of the slot; dragging it onto another slot
// re-docks the panel there. The instances talk through Mods.post(): the one being dragged reports
// where the pointer is, and whichever one is under it shows the drop zone and does the move.
Item {
    id: root

    property var host: null

    readonly property string modId: "panel-docking"
    readonly property var entries: root.host ? root.host.entries : []
    readonly property string panelType: root.entries.length > 0
        ? root.entries[Math.max(0, Math.min(root.host.activeIndex, root.entries.length - 1))].type
        : ""
    readonly property bool usable: root.panelType !== "" && !(root.host && root.host.fullscreen)

    // Drop zone under the pointer while some panel is being dragged over this slot.
    property string zone: ""

    function zoneAt(x, y) {
        if (x < 0 || y < 0 || x > root.width || y > root.height || root.width <= 0 || root.height <= 0)
            return ""
        const fx = x / root.width
        const fy = y / root.height
        if (fx > 0.3 && fx < 0.7 && fy > 0.3 && fy < 0.7)
            return "center"
        const edges = [["left", fx], ["right", 1 - fx], ["top", fy], ["bottom", 1 - fy]]
        edges.sort((a, b) => a[1] - b[1])
        return edges[0][0]
    }

    Connections {
        target: Mods

        function onMessage(modId, topic, payload) {
            if (modId !== root.modId)
                return
            if (topic === "move") {
                if (!root.usable) {
                    root.zone = ""
                    return
                }
                const local = root.mapFromItem(null, payload.x, payload.y)
                let zone = root.zoneAt(local.x, local.y)
                // A panel alone in its slot has nowhere to go within that slot.
                if (zone !== "" && root.entries.length === 1 && root.entries[0].type === payload.type)
                    zone = ""
                // Onto the middle of the slot it is already a tab of: nothing to do.
                if (zone === "center" && root.entries.some(entry => entry.type === payload.type))
                    zone = ""
                root.zone = zone
            } else if (topic === "drop") {
                const zone = root.zone
                root.zone = ""
                if (zone === "" || root.entries.length === 0)
                    return
                const next = Layout.movePanel(Workspaces.workspace(Workspaces.activeId),
                                              payload.type, root.entries[0].type, zone)
                if (next)
                    Workspaces.saveWorkspace(next)
            } else if (topic === "cancel") {
                root.zone = ""
            }
        }
    }

    // Where the panel would land.
    Rectangle {
        visible: root.zone !== ""
        x: root.zone === "right" ? root.width / 2 : 0
        y: root.zone === "bottom" ? root.height / 2 : 0
        width: (root.zone === "left" || root.zone === "right") ? root.width / 2 : root.width
        height: (root.zone === "top" || root.zone === "bottom") ? root.height / 2 : root.height
        color: "#4d9dff"
        opacity: 0.3
        border.color: "#4d9dff"
        border.width: 2
    }

    Rectangle {
        id: grip
        visible: root.usable
        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.horizontalCenter: parent.horizontalCenter
        width: 46
        height: 7
        radius: 3.5
        color: "#ffffff"
        opacity: area.pressed ? 0.95 : (area.containsMouse ? 0.65 : 0.14)

        MouseArea {
            id: area
            anchors.fill: parent
            anchors.margins: -3
            hoverEnabled: true
            preventStealing: true
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

            property bool moved: false

            onPressed: moved = false
            onPositionChanged: (mouse) => {
                if (!pressed)
                    return
                moved = true
                const scene = area.mapToItem(null, mouse.x, mouse.y)
                Mods.post(root.modId, "move", { x: scene.x, y: scene.y, type: root.panelType })
            }
            onReleased: Mods.post(root.modId, moved ? "drop" : "cancel", { type: root.panelType })
            onCanceled: Mods.post(root.modId, "cancel", {})
        }
    }
}
