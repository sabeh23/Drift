pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Drift

// Timeline toolbar button: Scale X and Scale Y for the selected clip, separately. 100% on both
// is the clip at its normal fitted size; the box stays centred while it scales.
Item {
    id: root

    property var host: null

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property int track: EditorState.selectedTrack
    readonly property int clip: EditorState.selectedClip
    readonly property var clipData: EditorState.selectedClipData
    readonly property bool hasClip: root.track >= 0 && root.clip >= 0 && !!root.clipData
                                    && ["video", "image", "text", "shape", "vector", "composite", "pdf"]
                                       .indexOf(root.clipData.kind) >= 0
    readonly property real canvasW: Math.max(1, EditorState.projectFile.projectWidth())
    readonly property real canvasH: Math.max(1, EditorState.projectFile.projectHeight())

    // The box the clip has at 100%: its source shape fitted inside the canvas.
    readonly property var fit: {
        const sw = root.clipData ? Number(root.clipData.sourceWidth || 0) : 0
        const sh = root.clipData ? Number(root.clipData.sourceHeight || 0) : 0
        if (sw > 0 && sh > 0) {
            const k = Math.min(root.canvasW / sw, root.canvasH / sh)
            return { w: sw * k, h: sh * k }
        }
        return { w: root.canvasW, h: root.canvasH }
    }

    property int revision: 0
    function value(key, def) {
        return EditorState.propertyValueAt(root.track, root.clip, key, EditorState.playheadSeconds, def)
    }
    readonly property real curW: (root.revision, EditorState.tracksRevision, EditorState.playheadSeconds,
                                  root.hasClip ? root.value("width", root.canvasW) : root.canvasW)
    readonly property real curH: (root.revision, EditorState.tracksRevision, EditorState.playheadSeconds,
                                  root.hasClip ? root.value("height", root.canvasH) : root.canvasH)
    readonly property real scaleX: root.curW / root.fit.w * 100
    readonly property real scaleY: root.curH / root.fit.h * 100

    Connections {
        target: EditorState
        function onClipPropertiesPreviewed(trackIndex, clipIndex, keys) { root.revision++ }
        function onSelectionChanged() { root.revision++ }
    }

    // The rect as the drag began; every update scales from it, about its centre.
    property var start: null
    function begin() {
        root.start = {
            x: root.value("x", 0), y: root.value("y", 0),
            w: root.curW, h: root.curH
        }
        EditorState.beginPreviewDrag("Scale X / Y")
    }
    function apply(sxPercent, syPercent) {
        const s = root.start
        if (!s)
            return
        const w = Math.max(1, root.fit.w * sxPercent / 100)
        const h = Math.max(1, root.fit.h * syPercent / 100)
        const cx = s.x + s.w / 2
        const cy = s.y + s.h / 2
        EditorState.previewSetClipRect(root.track, root.clip, cx - w / 2, cy - h / 2, w, h)
    }
    function end() {
        EditorState.commitPreviewDrag()
        root.start = null
        root.revision++
    }
    function setOnce(sx, sy) {
        root.begin()
        root.apply(sx, sy)
        root.end()
    }

    TimelineToolbarToolButton {
        id: button
        glyph: Theme.icons.maximize
        tooltip: "Scale X / Y (stretch the selected clip on one axis)"
        active: panel.opened
        enabled: root.hasClip
        onClicked: panel.opened ? panel.close() : panel.open()
    }

    Popup {
        id: panel

        y: -height - 6
        x: Math.min(0, -width / 2 + root.width / 2)
        padding: 12
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        onClosed: if (root.start) root.end()

        property bool linked: false

        background: Rectangle {
            color: Theme.c.themedContextMenu.background
            border.color: Theme.c.themedContextMenu.border
            radius: 8
        }

        contentItem: Column {
            spacing: 8
            width: 280

            Text {
                text: "Scale X / Y"
                color: Theme.c.settingsPage.foreground
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSm
                font.weight: Font.DemiBold
            }

            Repeater {
                model: [ { axis: "x", label: "Scale X" }, { axis: "y", label: "Scale Y" } ]

                delegate: Row {
                    id: axisRow

                    required property var modelData
                    readonly property bool isX: modelData.axis === "x"
                    readonly property real current: axisRow.isX ? root.scaleX : root.scaleY

                    spacing: 8

                    Text {
                        width: 52
                        anchors.verticalCenter: parent.verticalCenter
                        text: axisRow.modelData.label
                        color: Theme.c.settingsRow.foregroundMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeXs
                    }

                    ThemedSlider {
                        id: slider
                        width: 150
                        anchors.verticalCenter: parent.verticalCenter
                        from: 1
                        to: 400
                        stepSize: 1
                        showValueTooltip: false
                        value: axisRow.current

                        onPressedChanged: {
                            if (pressed)
                                root.begin()
                            else
                                root.end()
                        }
                        onMoved: {
                            if (panel.linked) {
                                const ratio = value / Math.max(1, axisRow.current)
                                root.apply(axisRow.isX ? value : root.scaleX * ratio,
                                           axisRow.isX ? root.scaleY * ratio : value)
                            } else {
                                root.apply(axisRow.isX ? value : root.scaleX,
                                           axisRow.isX ? root.scaleY : value)
                            }
                        }
                    }

                    Text {
                        width: 46
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(axisRow.current) + "%"
                        color: Theme.c.settingsPage.foreground
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeXs
                    }
                }
            }

            Row {
                spacing: 8

                ThemedSwitch {
                    text: "Link"
                    checked: panel.linked
                    onToggled: panel.linked = checked
                }

                ThemedButton {
                    text: "Reset to 100%"
                    variant: "secondary"
                    onClicked: root.setOnce(100, 100)
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "With Auto keyframes off, a clip that already has size keyframes won't change here, same as the Transform panel."
                color: Theme.c.settingsRow.foregroundMuted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeXs
            }
        }
    }
}
