import QtQuick
import Drift

// One per clip on the timeline. Draws a diamond along the bottom edge of the clip at every time
// one of its properties has a keyframe.
Item {
    id: root

    property var host: null

    // Keyframe times in timeline seconds, one per instant however many properties are keyed there.
    readonly property var times: {
        void EditorState.tracksRevision
        if (!root.host)
            return []
        const track = root.host.trackIndex
        const clip = root.host.clipIndex
        const seen = {}
        const out = []
        const props = EditorState.clipAnimatedProperties(track, clip)
        for (let i = 0; i < props.length; ++i) {
            const keys = EditorState.clipKeyframes(track, clip, props[i])
            for (let k = 0; k < keys.length; ++k) {
                const ms = Math.round(keys[k].seconds * 1000)
                if (seen[ms])
                    continue
                seen[ms] = true
                out.push(keys[k].seconds)
            }
        }
        return out
    }

    Repeater {
        model: root.times

        delegate: Item {
            id: marker

            required property real modelData

            readonly property real px: root.host
                ? (marker.modelData - root.host.effectiveStart) * root.host.panel.pxPerSecond
                : -1

            visible: marker.px >= 0 && marker.px <= root.width
            x: marker.px - width / 2
            y: root.height - height - 1
            width: 13
            height: 13

            Rectangle {
                anchors.centerIn: parent
                width: 7
                height: 7
                rotation: 45
                antialiasing: true
                color: hit.containsMouse ? "#ffd54a" : "#ffffff"
                border.color: "#1a1a1a"
                border.width: 1
            }

            MouseArea {
                id: hit
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: EditorState.playheadSeconds = marker.modelData
            }
        }
    }
}
