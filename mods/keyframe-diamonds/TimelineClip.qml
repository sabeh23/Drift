pragma ComponentBehavior: Bound
import QtQuick
import Drift

// One per clip on the timeline. A diamond along the bottom edge for every instant the clip has a
// keyframe (all properties keyed at that time share one diamond, like CapCut).
//
//   click          select it and jump the playhead there
//   drag           move it (every property keyed at that instant moves together)
//   Delete         delete the selected diamond's keyframes
//   right-click    menu: jump, copy, delete
Item {
    id: root

    property var host: null

    readonly property string modId: "keyframe-diamonds"
    readonly property real diamondSize: 11
    readonly property real hitSize: 20

    readonly property int trackIndex: root.host ? root.host.trackIndex : -1
    readonly property int clipIndex: root.host ? root.host.clipIndex : -1
    readonly property real pxPerSecond: root.host ? root.host.panel.pxPerSecond : 1
    readonly property real clipStart: root.host ? root.host.effectiveStart : 0
    readonly property real clipDuration: root.host ? root.host.effectiveDuration : 0

    // Selected diamond's time (timeline seconds) on this clip; -1 for none.
    property real selected: -1

    // [{seconds, props: [prop...]}], one entry per keyed instant.
    readonly property var keys: {
        void EditorState.tracksRevision
        if (root.trackIndex < 0 || root.clipIndex < 0)
            return []
        const byTime = {}
        const out = []
        const props = EditorState.clipAnimatedProperties(root.trackIndex, root.clipIndex)
        for (let i = 0; i < props.length; ++i) {
            const list = EditorState.clipKeyframes(root.trackIndex, root.clipIndex, props[i])
            for (let k = 0; k < list.length; ++k) {
                const ms = Math.round(list[k].seconds * 1000)
                let entry = byTime[ms]
                if (!entry) {
                    entry = { seconds: list[k].seconds, props: [] }
                    byTime[ms] = entry
                    out.push(entry)
                }
                if (entry.props.indexOf(props[i]) < 0)
                    entry.props.push(props[i])
            }
        }
        out.sort((a, b) => a.seconds - b.seconds)
        return out
    }

    function refsFor(entry) {
        return entry.props.map(p => ({ prop: p, seconds: entry.seconds }))
    }

    function deleteEntry(entry) {
        EditorState.keyframes.removeKeysAt(root.trackIndex, root.clipIndex, entry.props, entry.seconds)
        root.selected = -1
    }

    // Only one diamond is selected across the whole timeline.
    Connections {
        target: Mods
        function onMessage(modId, topic, payload) {
            if (modId === root.modId && topic === "select" && payload !== root)
                root.selected = -1
        }
    }

    Repeater {
        model: root.keys

        delegate: Item {
            id: marker

            required property var modelData

            property real dragDx: 0
            property bool dragging: false
            property real pressSceneX: 0
            readonly property bool isSelected: Math.abs(root.selected - marker.modelData.seconds) < 0.0005
            readonly property real px: (marker.modelData.seconds - root.clipStart) * root.pxPerSecond

            visible: marker.px >= -1 && marker.px <= root.width + 1
            width: root.hitSize
            height: root.hitSize
            x: marker.px + marker.dragDx - width / 2
            y: root.height - height
            z: marker.isSelected || marker.dragging ? 2 : 1
            focus: marker.isSelected

            Rectangle {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -2
                width: root.diamondSize
                height: root.diamondSize
                rotation: 45
                antialiasing: true
                color: marker.isSelected || marker.dragging ? "#ffb020"
                       : hit.containsMouse ? "#ffe08a" : "#ffffff"
                border.color: "#111111"
                border.width: 1.5
            }

            // Keep Delete for the diamond instead of the editor's delete-clip shortcut.
            Keys.onShortcutOverride: (event) => {
                if (marker.isSelected && (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace))
                    event.accepted = true
            }
            Keys.onPressed: (event) => {
                if (!marker.isSelected)
                    return
                if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                    root.deleteEntry(marker.modelData)
                    event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                    root.selected = -1
                    event.accepted = true
                }
            }

            MouseArea {
                id: hit
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: marker.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                onPressed: (mouse) => {
                    root.selected = marker.modelData.seconds
                    Mods.post(root.modId, "select", root)
                    marker.forceActiveFocus()
                    if (mouse.button === Qt.RightButton) {
                        menu.entry = marker.modelData
                        menu.popup()
                        return
                    }
                    marker.pressSceneX = hit.mapToItem(null, mouse.x, 0).x
                    marker.dragging = false
                    marker.dragDx = 0
                }

                onPositionChanged: (mouse) => {
                    if (!(hit.pressedButtons & Qt.LeftButton))
                        return
                    let dx = hit.mapToItem(null, mouse.x, 0).x - marker.pressSceneX
                    if (!marker.dragging && Math.abs(dx) < 3)
                        return
                    // Stay inside the clip.
                    const minDx = -marker.px
                    const maxDx = root.clipDuration * root.pxPerSecond - marker.px
                    dx = Math.max(minDx, Math.min(maxDx, dx))
                    marker.dragging = true
                    marker.dragDx = dx
                    EditorState.keyframes.previewMoveKeys(root.trackIndex, root.clipIndex,
                                                          root.refsFor(marker.modelData),
                                                          dx / root.pxPerSecond)
                }

                onReleased: (mouse) => {
                    if (mouse.button !== Qt.LeftButton)
                        return
                    if (marker.dragging) {
                        const target = marker.modelData.seconds + marker.dragDx / root.pxPerSecond
                        EditorState.commitPreviewDrag()
                        EditorState.keyframes.clearCollisions()
                        marker.dragging = false
                        marker.dragDx = 0
                        root.selected = target
                    } else {
                        EditorState.playheadSeconds = marker.modelData.seconds
                    }
                }

                onCanceled: {
                    if (marker.dragging)
                        EditorState.cancelPreviewDrag()
                    marker.dragging = false
                    marker.dragDx = 0
                }
            }
        }
    }

    ThemedContextMenu {
        id: menu

        property var entry: null

        ThemedMenuItem {
            text: "Jump to keyframe"
            onTriggered: EditorState.playheadSeconds = menu.entry.seconds
        }
        ThemedMenuItem {
            text: "Copy keyframe"
            onTriggered: EditorState.keyframes.copyKeys(root.trackIndex, root.clipIndex,
                                                        root.refsFor(menu.entry))
        }
        ThemedMenuItem {
            text: "Paste keyframes at playhead"
            enabled: EditorState.keyframes.clipboardCount > 0
            onTriggered: EditorState.keyframes.pasteKeys(root.trackIndex, root.clipIndex,
                                                         EditorState.playheadSeconds)
        }
        ThemedMenuItem {
            text: "Delete keyframe"
            onTriggered: root.deleteEntry(menu.entry)
        }
    }
}
