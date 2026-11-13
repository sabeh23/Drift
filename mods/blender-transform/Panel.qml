pragma ComponentBehavior: Bound
import QtQuick
import Drift

// Blender-style modal transforms over the preview.
//
//   G            move              then X / Y: only that axis
//   R            rotate            then X / Y: tilt about that axis (3D), R again: trackball (3D)
//   S            scale             then X / Y: stretch only that axis
//   typing       an exact amount: pixels (G), degrees (R), factor (S); Backspace edits, - flips
//   click/Enter  confirm           right-click/Esc: cancel
//   Shift        hold for fine control      Ctrl: hold to snap (10 px, 5°, 0.1x)
//
// One instance sits over every panel slot; only the one showing the preview does anything. The
// keys only work while the pointer is over the preview, and never while typing into a field.
Item {
    id: root

    property var host: null

    readonly property bool isPreview: {
        if (!root.host || !root.host.entries)
            return false
        const entries = root.host.entries
        const i = Math.max(0, Math.min(root.host.activeIndex, entries.length - 1))
        return entries.length > 0 && entries[i].type === "preview"
    }

    // ---- the preview's canvas -------------------------------------------------------------
    property var viewport: null
    function findViewport(item) {
        if (!item)
            return null
        if (item.canvas !== undefined && item.fitWidth !== undefined && item.toolHost !== undefined)
            return item
        const kids = item.children
        for (let i = 0; i < kids.length; ++i) {
            const hit = root.findViewport(kids[i])
            if (hit)
                return hit
        }
        return null
    }
    function canvasItem() {
        if (!root.viewport || !root.viewport.canvas)
            root.viewport = root.findViewport(root.host)
        return root.viewport ? root.viewport.canvas : null
    }
    readonly property real canvasW: Math.max(1, EditorState.projectFile.projectWidth())
    readonly property real canvasH: Math.max(1, EditorState.projectFile.projectHeight())

    // Scene point -> project pixels.
    function toCanvas(sx, sy) {
        const c = root.canvasItem()
        if (!c || c.width <= 0)
            return Qt.point(sx, sy)
        const p = c.mapFromItem(null, sx, sy)
        return Qt.point(p.x * root.canvasW / c.width, p.y * root.canvasH / c.height)
    }
    // Project pixels -> scene point.
    function toScene(cx, cy) {
        const c = root.canvasItem()
        if (!c || c.width <= 0)
            return Qt.point(cx, cy)
        return c.mapToItem(null, cx * c.width / root.canvasW, cy * c.height / root.canvasH)
    }

    // ---- state -----------------------------------------------------------------------------
    property string mode: ""        // "", "move", "rotate", "trackball", "scale"
    property string axis: ""        // "", "x", "y"
    property string typed: ""
    property var start: null        // values when the operation began
    property point pointer0: Qt.point(0, 0)
    property point pointer: Qt.point(0, 0)
    property real rotUnwrap: 0
    property real lastAngle: 0
    property bool turnedOn3d: false
    property string hud: ""
    property point rawLast: Qt.point(0, 0)
    property bool fine: false
    property bool snapping: false
    property var focusBefore: null

    readonly property bool active: root.mode !== ""
    readonly property int track: EditorState.selectedTrack
    readonly property int clip: EditorState.selectedClip

    function value(key, def) {
        return EditorState.propertyValueAt(root.track, root.clip, key, EditorState.playheadSeconds, def)
    }

    function isTyping() {
        const f = root.Window.activeFocusItem
        return !!f && f !== catcher && (f.cursorPosition !== undefined || f.selectedText !== undefined)
    }

    function inPopup(item) {
        for (let p = item; p; p = p.parent)
            if (p.toString().indexOf("PopupItem") >= 0 || p.toString().indexOf("Overlay") >= 0)
                return true
        return false
    }
    function giveFocusBack() {
        if (!catcher.activeFocus)
            return
        const back = root.focusBefore
        root.focusBefore = null
        if (back && back.visible)
            back.forceActiveFocus()
        else
            catcher.focus = false
    }

    function canStart() {
        if (!root.isPreview || root.active || root.track < 0 || root.clip < 0)
            return false
        const data = EditorState.selectedClipData
        return !!data && data.kind !== "audio" && data.kind !== "subtitle"
    }

    function begin(mode) {
        const data = EditorState.selectedClipData
        root.start = {
            x: root.value("x", 0), y: root.value("y", 0),
            w: root.value("width", root.canvasW), h: root.value("height", root.canvasH),
            rot: root.value("rotation", 0),
            rx: root.value("rotationX", 0), ry: root.value("rotationY", 0),
            text: data.kind === "text",
            pixelSize: (data.textStyle && data.textStyle.pixelSize) || 64,
            layer3d: !!data.layer3d
        }
        root.pointer0 = hover.point.scenePosition
        root.pointer = root.pointer0
        root.rawLast = root.pointer0
        root.fine = false
        root.snapping = false
        root.axis = ""
        root.typed = ""
        root.rotUnwrap = 0
        root.lastAngle = root.angleOf(root.pointer0)
        root.turnedOn3d = false
        root.mode = mode
        if (mode === "trackball")
            root.ensure3d()
        EditorState.beginPreviewDrag(mode === "move" ? "Move (G)" : mode === "scale" ? "Scale (S)" : "Rotate (R)")
        root.update()
    }

    function ensure3d() {
        if (!root.start.layer3d && !root.turnedOn3d) {
            // A separate step: turning the clip into a 3D layer is what lets it tilt at all.
            EditorState.cancelPreviewDrag()
            EditorState.setClipLayer3d(root.track, root.clip, true)
            root.turnedOn3d = true
            EditorState.beginPreviewDrag("Rotate (R)")
        }
    }

    function finish(confirm) {
        if (!root.active)
            return
        if (confirm) {
            EditorState.commitPreviewDrag()
        } else {
            EditorState.cancelPreviewDrag()
            if (root.turnedOn3d)
                EditorState.setClipLayer3d(root.track, root.clip, false)
        }
        root.mode = ""
        root.start = null
        root.hud = ""
        if (!hover.hovered)
            root.giveFocusBack()
    }

    function centerScene() {
        const s = root.start
        return root.toScene(s.x + s.w / 2, s.y + s.h / 2)
    }
    function angleOf(p) {
        const c = root.start ? root.centerScene() : Qt.point(0, 0)
        return Math.atan2(p.y - c.y, p.x - c.x) * 180 / Math.PI
    }

    // Pointer moved: Shift scales the motion down tenfold from here on, like Blender.
    function moved(raw, modifiers) {
        const f = (modifiers & Qt.ShiftModifier) ? 0.1 : 1
        root.fine = f < 1
        root.snapping = !!(modifiers & Qt.ControlModifier)
        root.pointer = Qt.point(root.pointer.x + (raw.x - root.rawLast.x) * f,
                                root.pointer.y + (raw.y - root.rawLast.y) * f)
        const a = root.angleOf(raw)
        let step = a - root.lastAngle
        if (step > 180) step -= 360
        if (step < -180) step += 360
        root.rotUnwrap += step * f
        root.lastAngle = a
        root.rawLast = raw
        root.update()
    }
    function snap(v, step) {
        return root.snapping ? Math.round(v / step) * step : v
    }

    function typedNumber() {
        if (root.typed === "" || root.typed === "-" || root.typed === ".")
            return NaN
        return Number(root.typed)
    }

    function setAxis(a) {
        if (root.mode === "rotate" || root.mode === "trackball") {
            // R then X / Y tilts in 3D about that axis.
            root.ensure3d()
            root.mode = "rotate"
        }
        root.axis = root.axis === a ? "" : a
        root.update()
    }

    function update() {
        const s = root.start
        if (!s)
            return
        const n = root.typedNumber()
        const c0 = root.toCanvas(root.pointer0.x, root.pointer0.y)
        const c1 = root.toCanvas(root.pointer.x, root.pointer.y)
        const typedTxt = root.typed !== "" ? "  [" + root.typed + "]" : ""
        const axisTxt = (root.axis !== "" ? "  along " + root.axis.toUpperCase() : "")
                        + (root.snapping ? "  snap" : "") + (root.fine ? "  fine" : "")

        if (root.mode === "move") {
            let dx = c1.x - c0.x
            let dy = c1.y - c0.y
            if (!isNaN(n)) {
                dx = root.axis === "y" ? 0 : n
                dy = root.axis === "x" ? 0 : (root.axis === "y" ? n : 0)
            }
            if (root.axis === "x") dy = 0
            if (root.axis === "y") dx = 0
            if (root.snapping) {
                dx = root.snap(s.x + dx, 10) - s.x
                dy = root.snap(s.y + dy, 10) - s.y
                if (root.axis === "x") dy = 0
                if (root.axis === "y") dx = 0
            }
            EditorState.previewSetClipPosition(root.track, root.clip, s.x + dx, s.y + dy)
            root.hud = "Move   X: " + Math.round(dx) + "   Y: " + Math.round(dy) + axisTxt + typedTxt
        } else if (root.mode === "scale") {
            const c = root.centerScene()
            const d0 = Math.max(1, Math.hypot(root.pointer0.x - c.x, root.pointer0.y - c.y))
            const d1 = Math.hypot(root.pointer.x - c.x, root.pointer.y - c.y)
            const k = !isNaN(n) ? n : Math.max(0.01, root.snap(d1 / d0, 0.1))
            const kx = root.axis === "y" ? 1 : k
            const ky = root.axis === "x" ? 1 : k
            const w = Math.max(1, s.w * kx)
            const h = Math.max(1, s.h * ky)
            const x = s.x + (s.w - w) / 2
            const y = s.y + (s.h - h) / 2
            if (s.text && root.axis === "")
                EditorState.previewSetTextRect(root.track, root.clip, x, y, w, h, Math.max(1, Math.round(s.pixelSize * k)))
            else
                EditorState.previewSetClipRect(root.track, root.clip, x, y, w, h)
            root.hud = "Scale   " + k.toFixed(3) + axisTxt + typedTxt
        } else if (root.mode === "rotate" && root.axis === "") {
            const deg = !isNaN(n) ? n : root.snap(s.rot + root.rotUnwrap, 5) - s.rot
            EditorState.previewSetClipRotation(root.track, root.clip, s.rot + deg)
            root.hud = "Rotate   " + deg.toFixed(1) + "°" + typedTxt
        } else if (root.mode === "rotate") {
            // Tilt about one axis: vertical drag for X, horizontal for Y.
            const sens = 0.5
            const t = EditorState.playheadSeconds
            if (root.axis === "x") {
                const deg = !isNaN(n) ? n : root.snap(s.rx + (root.pointer.y - root.pointer0.y) * sens, 5) - s.rx
                EditorState.previewSetClipKeyframe(root.track, root.clip, "rotationX", t, s.rx + deg)
                root.hud = "Rotate X (3D)   " + deg.toFixed(1) + "°" + typedTxt
            } else {
                const deg = !isNaN(n) ? n : root.snap(s.ry - (root.pointer.x - root.pointer0.x) * sens, 5) - s.ry
                EditorState.previewSetClipKeyframe(root.track, root.clip, "rotationY", t, s.ry + deg)
                root.hud = "Rotate Y (3D)   " + deg.toFixed(1) + "°" + typedTxt
            }
        } else if (root.mode === "trackball") {
            const sens = 0.5
            const t = EditorState.playheadSeconds
            const dxDeg = root.snap(s.ry - (root.pointer.x - root.pointer0.x) * sens, 5) - s.ry
            const dyDeg = root.snap(s.rx + (root.pointer.y - root.pointer0.y) * sens, 5) - s.rx
            EditorState.previewSetClipKeyframe(root.track, root.clip, "rotationX", t, s.rx + dyDeg)
            EditorState.previewSetClipKeyframe(root.track, root.clip, "rotationY", t, s.ry + dxDeg)
            root.hud = "Trackball (3D)   X: " + dyDeg.toFixed(1) + "°   Y: " + dxDeg.toFixed(1) + "°"
        }
    }

    // ---- input -----------------------------------------------------------------------------
    HoverHandler {
        id: hover
        enabled: root.isPreview
        // Borrow keyboard focus only while the pointer is over the preview, and hand it back
        // to whatever had it when the pointer leaves, so the rest of the editor keeps its keys.
        onHoveredChanged: {
            if (hovered) {
                const f = root.Window.activeFocusItem
                if (f !== catcher && !root.isTyping() && !root.inPopup(f)) {
                    root.focusBefore = f
                    catcher.forceActiveFocus()
                }
            } else if (!root.active) {
                root.giveFocusBack()
            }
        }
    }

    // Takes the keys while the pointer is over the preview. It has to be the focus item to beat
    // the editor's own single-key shortcuts (S split, G guides, R rotate gizmo) to them.
    Item {
        id: catcher
        focus: false

        function claims(event) {
            if (root.active)
                return true
            if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier | Qt.ShiftModifier))
                return false
            if (!hover.hovered || !root.canStart())
                return false
            return event.key === Qt.Key_G || event.key === Qt.Key_R || event.key === Qt.Key_S
        }

        Keys.onShortcutOverride: (event) => { if (catcher.claims(event)) event.accepted = true }
        Keys.onReleased: (event) => {
            if (root.active && event.key === Qt.Key_Control) {
                event.accepted = true
                root.snapping = false
                root.update()
            }
        }
        Keys.onPressed: (event) => {
            if (!catcher.claims(event))
                return
            event.accepted = true
            if (event.isAutoRepeat)
                return
            const k = event.key
            if (root.active && (k === Qt.Key_Control || k === Qt.Key_Shift)) {
                root.snapping = !!(event.modifiers & Qt.ControlModifier)
                root.update()
                return
            }
            if (!root.active) {
                if (k === Qt.Key_G) root.begin("move")
                else if (k === Qt.Key_R) root.begin("rotate")
                else if (k === Qt.Key_S) root.begin("scale")
                return
            }
            if (k === Qt.Key_Escape) { root.finish(false); return }
            if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) { root.finish(true); return }
            if (k === Qt.Key_X) { root.setAxis("x"); return }
            if (k === Qt.Key_Y) { root.setAxis("y"); return }
            if (k === Qt.Key_R && (root.mode === "rotate" || root.mode === "trackball")) {
                // R again: trackball.
                root.ensure3d()
                root.mode = root.mode === "trackball" ? "rotate" : "trackball"
                root.axis = ""
                root.update()
                return
            }
            if (k === Qt.Key_G && root.mode !== "move") { root.finish(false); root.begin("move"); return }
            if (k === Qt.Key_S && root.mode !== "scale") { root.finish(false); root.begin("scale"); return }
            if (k === Qt.Key_Backspace) { root.typed = root.typed.slice(0, -1); root.update(); return }
            if (k === Qt.Key_Minus) {
                root.typed = root.typed.startsWith("-") ? root.typed.slice(1) : "-" + root.typed
                root.update()
                return
            }
            if ((k >= Qt.Key_0 && k <= Qt.Key_9) || k === Qt.Key_Period) {
                root.typed += event.text
                root.update()
            }
        }
    }

    // While an operation runs: the pointer drives it, left click confirms, right click cancels.
    MouseArea {
        anchors.fill: parent
        enabled: root.active
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: root.mode === "move" ? Qt.SizeAllCursor : Qt.CrossCursor
        onPositionChanged: (mouse) => root.moved(mapToItem(null, mouse.x, mouse.y), mouse.modifiers)
        onPressed: (mouse) => root.finish(mouse.button === Qt.LeftButton)
    }

    // Blender-style status line.
    Rectangle {
        visible: root.active
        x: 10
        y: 10
        width: hudText.implicitWidth + 20
        height: hudText.implicitHeight + 10
        radius: 4
        color: "#cc000000"

        Text {
            id: hudText
            anchors.centerIn: parent
            text: root.hud
            color: "#ffffff"
            font.family: Theme.fontFamily
            font.pixelSize: 12
        }
    }

    // Axis guide line through the clip's centre, like Blender's constraint line.
    Rectangle {
        visible: root.active && root.axis !== "" && (root.mode === "move" || root.mode === "scale")
        readonly property point c: root.start ? root.mapFromItem(null, root.centerScene().x, root.centerScene().y)
                                              : Qt.point(0, 0)
        x: root.axis === "x" ? 0 : c.x - 0.5
        y: root.axis === "y" ? 0 : c.y - 0.5
        width: root.axis === "x" ? root.width : 1
        height: root.axis === "y" ? root.height : 1
        color: root.axis === "x" ? "#ff3352" : "#8bdc00"
    }
}
