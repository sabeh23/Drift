pragma ComponentBehavior: Bound
import QtQuick
import Drift

// Ctrl + middle-drag zooms the timeline around the point you grabbed, like Blender.
// Everything else (middle-drag pan, wheel, clicks) passes straight through to the timeline.
Item {
    id: root

    property var host: null

    readonly property bool isTimeline: {
        if (!root.host || !root.host.entries)
            return false
        const entries = root.host.entries
        const i = Math.max(0, Math.min(root.host.activeIndex, entries.length - 1))
        return entries.length > 0 && entries[i].type === "timeline"
    }

    function find(item, test) {
        if (!item)
            return null
        if (test(item))
            return item
        const kids = item.children
        for (let i = 0; i < kids.length; ++i) {
            const hit = root.find(kids[i], test)
            if (hit)
                return hit
        }
        return null
    }

    property var panel: null
    property var flick: null
    property real zoom0: 1
    property real anchorSeconds: 0
    property real viewportX: 0
    property real pressX: 0

    MouseArea {
        anchors.fill: parent
        enabled: root.isTimeline
        acceptedButtons: Qt.MiddleButton
        preventStealing: true

        onPressed: (mouse) => {
            if (!(mouse.modifiers & Qt.ControlModifier)) {
                mouse.accepted = false
                return
            }
            if (!root.panel || !root.panel.visible)
                root.panel = root.find(root.host, it => typeof it.setZoomAround === "function"
                                                       && it.timelineViewX !== undefined)
            if (!root.panel) {
                mouse.accepted = false
                return
            }
            const p = root.panel
            root.flick = root.find(p, it => it !== p && it.flickableDirection !== undefined
                                            && it.contentX === p.timelineViewX
                                            && it.width === p.timelineViewW)
            const scene = mapToItem(null, mouse.x, mouse.y)
            const local = root.flick ? root.flick.mapFromItem(null, scene.x, scene.y)
                                     : p.mapFromItem(null, scene.x, scene.y)
            root.viewportX = Math.max(0, local.x)
            root.anchorSeconds = Math.max(0, (p.timelineViewX + root.viewportX) / p.pxPerSecond)
            root.zoom0 = p.zoom
            root.pressX = scene.x
        }
        onPositionChanged: (mouse) => {
            if (!pressed || !root.panel)
                return
            const scene = mapToItem(null, mouse.x, mouse.y)
            const slow = (mouse.modifiers & Qt.ShiftModifier) ? 0.2 : 1
            const factor = Math.exp((scene.x - root.pressX) * 0.01 * slow)
            root.panel.setZoomAround(root.zoom0 * factor, root.anchorSeconds, root.viewportX)
        }
    }
}
