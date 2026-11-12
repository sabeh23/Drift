import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Window
import Drift
// CapCut-style Animation: In / Out only.
// Fade is one kind among slide/zoom/pop — same duration + style (Linear/Smooth/Natural/Custom).
Item {
    id: root

    property int clipDataRevision: 0
    readonly property var clipData: {
        void clipDataRevision
        return EditorState.selectedClipData
    }
    readonly property bool hasSelection: !!clipData && Object.keys(clipData).length > 0
    readonly property string clipKind: hasSelection ? (clipData.kind || "") : ""
    readonly property bool supportsBodyAnim: clipKind === "video" || clipKind === "image"
                                             || clipKind === "shape" || clipKind === "text"
    readonly property bool supportsFade: supportsBodyAnim || clipKind === "audio"

    readonly property var animKinds: [
        "none", "fade", "slideUp", "slideDown", "slideLeft", "slideRight",
        "zoomIn", "zoomOut", "pop", "spinCW", "spinCCW", "bounce"
    ]
    readonly property var animKindLabels: [
        qsTr("None"), qsTr("Fade"), qsTr("Slide up"), qsTr("Slide down"),
        qsTr("Slide left"), qsTr("Slide right"), qsTr("Zoom in"), qsTr("Zoom out"),
        qsTr("Pop"), qsTr("Spin CW"), qsTr("Spin CCW"), qsTr("Bounce")
    ]
    readonly property var animIn: {
        void clipDataRevision
        return (clipData && clipData.animIn)
               ? clipData.animIn
               : { kind: "none", duration: 0.5, curve: "smooth" }
    }
    readonly property var animOut: {
        void clipDataRevision
        return (clipData && clipData.animOut)
               ? clipData.animOut
               : { kind: "none", duration: 0.5, curve: "smooth" }
    }

    // Keyframe presets: the user's library, shared by every project.
    property int presetRevision: 0
    readonly property var keyframePresets: {
        void root.presetRevision
        return EditorState.keyframePresets()
    }
    readonly property int animatedCount: {
        void root.clipDataRevision
        return root.hasSelection
               ? EditorState.clipAnimatedProperties(EditorState.selectedTrack,
                                                    EditorState.selectedClip).length
               : 0
    }
    property bool fitPresets: true
    property var menuPreset: null

    height: column.height
    implicitHeight: column.height

    function setAnim(which, patch) {
        EditorState.setClipAnimation(EditorState.selectedTrack, EditorState.selectedClip, which, patch)
    }

    function applyBoth(kind) {
        const curve = kind === "none" ? "smooth" : (root.animIn.curve || "smooth")
        const duration = 0.5
        root.setAnim("animIn", { kind: kind, duration: duration, curve: curve })
        root.setAnim("animOut", { kind: kind, duration: duration, curve: curve })
    }

    function setStyle(which, curve, handles) {
        const patch = { curve: curve }
        if (handles.length === 4)
            patch.handles = handles
        root.setAnim(which, patch)
        if (curve === "custom")
            ShellBridge.main.openFadeCurve(EditorState.selectedTrack, EditorState.selectedClip)
    }

    function refreshFields() {
        if (root.supportsBodyAnim) {
            if (animInDurationField && !animInDurationField.activeFocus)
                animInDurationField.value = root.animIn.duration || 0.5
            if (animOutDurationField && !animOutDurationField.activeFocus)
                animOutDurationField.value = root.animOut.duration || 0.5
        }
        if (root.clipKind === "audio") {
            if (audioFadeInField && !audioFadeInField.activeFocus)
                audioFadeInField.value = root.clipData.fadeIn || 0
            if (audioFadeOutField && !audioFadeOutField.activeFocus)
                audioFadeOutField.value = root.clipData.fadeOut || 0
        }
    }

    Connections {
        target: EditorState
        function onSelectionChanged() { root.clipDataRevision++; root.refreshFields() }
        function onSelectedClipDataChanged() { root.clipDataRevision++; root.refreshFields() }
        function onTracksChanged() { root.clipDataRevision++; root.refreshFields() }
        function onKeyframePresetsChanged() { root.presetRevision++ }
    }

    Component.onCompleted: refreshFields()

    Column {
        id: column
        width: root.width
        spacing: Theme.spacingXl

        EmptyState {
            visible: !root.supportsFade
            width: parent.width
            compact: true
            glyph: Theme.icons.sparkles
            title: qsTr("Not available")
            hint: qsTr("Animation applies to video, image, shape, text, and audio.")
        }

        // ----- Audio: volume fades only ----------------------------------------------------
        Text {
            visible: root.clipKind === "audio"
            text: qsTr("Fade in / out (volume)")
            color: Theme.c.animationInspector.foregroundMuted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeXs
        }

        Row {
            visible: root.clipKind === "audio"
            width: parent.width
            spacing: 6

            ThemedNumberField {
                id: audioFadeInField
                to: Math.max(0.1, root.clipData.duration || 1)
                unit: "s"
                width: (parent.width - parent.spacing) / 2
                decimals: 2
                step: 0.05
                from: 0
                onEdited: v => EditorState.setClipFade(
                               EditorState.selectedTrack, EditorState.selectedClip,
                               v, root.clipData.fadeOut || 0)
            }
            ThemedNumberField {
                id: audioFadeOutField
                to: Math.max(0.1, root.clipData.duration || 1)
                unit: "s"
                width: (parent.width - parent.spacing) / 2
                decimals: 2
                step: 0.05
                from: 0
                onEdited: v => EditorState.setClipFade(
                               EditorState.selectedTrack, EditorState.selectedClip,
                               root.clipData.fadeIn || 0, v)
            }
        }

        Text {
            visible: root.clipKind === "audio"
            text: qsTr("Style")
            color: Theme.c.animationInspector.foregroundMuted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeXs
        }

        CurveField {
            visible: root.clipKind === "audio"
            width: parent.width
            domain: "fade"
            curve: root.clipData.fadeCurve || "smooth"
            handles: root.clipData.fadeHandles || []
            onCurveChosen: (curve, handles) => {
                EditorState.setClipFadeCurve(EditorState.selectedTrack, EditorState.selectedClip,
                                             curve, handles)
                if (curve === "custom")
                    ShellBridge.main.openFadeCurve(EditorState.selectedTrack, EditorState.selectedClip)
            }
        }

        // ----- Visual: CapCut In / Out -----------------------------------------------------
        Text {
            visible: root.supportsBodyAnim
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("Pick how the clip enters and leaves. Fade is one option — same style controls as slide or zoom.")
            color: Theme.c.animationInspector.foregroundMuted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeXs
        }

        Flow {
            visible: root.supportsBodyAnim
            width: parent.width
            spacing: 6

            Repeater {
                model: [
                    { label: qsTr("Fade"), kind: "fade" },
                    { label: qsTr("Slide up"), kind: "slideUp" },
                    { label: qsTr("Pop"), kind: "pop" },
                    { label: qsTr("Zoom in"), kind: "zoomIn" },
                    { label: qsTr("Bounce"), kind: "bounce" },
                    { label: qsTr("Clear"), kind: "none" }
                ]
                delegate: ThemedChip {
                    required property var modelData
                    text: modelData.label
                    selected: modelData.kind !== "none"
                              && root.animIn.kind === modelData.kind
                              && root.animOut.kind === modelData.kind
                    onClicked: root.applyBoth(modelData.kind)
                }
            }
        }

        Text {
            visible: root.supportsBodyAnim
            text: qsTr("In")
            SearchAnchor {
                searchId: "animation-in"
                title: qsTr("In animation")
                keywords: "intro enter fade slide pop zoom bounce"
            }
            color: Theme.c.animationInspector.foregroundMuted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeXs
        }

        Row {
            visible: root.supportsBodyAnim
            width: parent.width
            spacing: 6

            ThemedComboBox {
                width: Math.max(40, (parent.width - parent.spacing * 2 - 56) / 2)
                model: root.animKindLabels
                currentIndex: Math.max(0, root.animKinds.indexOf(root.animIn.kind || "none"))
                onActivated: root.setAnim("animIn", { kind: root.animKinds[currentIndex] })
            }
            CurveField {
                width: Math.max(40, (parent.width - parent.spacing * 2 - 56) / 2)
                anchors.verticalCenter: parent.verticalCenter
                domain: "fade"
                curve: root.animIn.curve || root.clipData.fadeCurve || "smooth"
                handles: root.animIn.handles || []
                onCurveChosen: (curve, handles) => root.setStyle("animIn", curve, handles)
            }
            ThemedNumberField {
                id: animInDurationField
                to: 10
                unit: "s"
                width: 56
                decimals: 2
                step: 0.05
                from: 0
                onEdited: v => root.setAnim("animIn", { duration: v })
            }
        }

        Text {
            visible: root.supportsBodyAnim
            text: qsTr("Out")
            SearchAnchor {
                searchId: "animation-out"
                title: qsTr("Out animation")
                keywords: "outro exit fade slide pop zoom"
            }
            color: Theme.c.animationInspector.foregroundMuted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeXs
        }

        Row {
            visible: root.supportsBodyAnim
            width: parent.width
            spacing: 6

            ThemedComboBox {
                width: Math.max(40, (parent.width - parent.spacing * 2 - 56) / 2)
                model: root.animKindLabels
                currentIndex: Math.max(0, root.animKinds.indexOf(root.animOut.kind || "none"))
                onActivated: root.setAnim("animOut", { kind: root.animKinds[currentIndex] })
            }
            CurveField {
                width: Math.max(40, (parent.width - parent.spacing * 2 - 56) / 2)
                anchors.verticalCenter: parent.verticalCenter
                domain: "fade"
                curve: root.animOut.curve || root.clipData.fadeCurve || "smooth"
                handles: root.animOut.handles || []
                onCurveChosen: (curve, handles) => root.setStyle("animOut", curve, handles)
            }
            ThemedNumberField {
                id: animOutDurationField
                to: 10
                unit: "s"
                width: 56
                decimals: 2
                step: 0.05
                from: 0
                onEdited: v => root.setAnim("animOut", { duration: v })
            }
        }

        SearchAnchor {
            searchId: "animation-custom-curve"
            title: qsTr("Custom curve")
            keywords: "easing"
            target: animationCustomCurveButton
        }
        ThemedButton {
            id: animationCustomCurveButton
            visible: root.supportsBodyAnim
                     && ((root.animIn.curve || "") === "custom"
                         || (root.animOut.curve || "") === "custom"
                         || (root.clipData.fadeCurve || "") === "custom")
            width: parent.width
            text: qsTr("Edit custom curve…")
            variant: "secondary"
            onClicked: ShellBridge.main.openFadeCurve(
                           EditorState.selectedTrack, EditorState.selectedClip)
        }

        Text {
            visible: root.supportsBodyAnim && root.clipKind === "text"
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("Letter and word animations live in the Text tab, under Animate. This moves the whole clip.")
            color: Theme.c.animationInspector.foregroundMuted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeXs
        }

        // ----- Keyframe presets: save a clip's keyframes, reuse them anywhere ---------------
        Column {
            id: presetSection
            visible: root.hasSelection
            width: parent.width
            spacing: Theme.spacingMd

            ThemedLabel {
                text: qsTr("Keyframe presets")
                tone: "default"
                size: "sm"
                SearchAnchor {
                    searchId: "animation-keyframe-presets"
                    title: qsTr("Keyframe presets")
                    keywords: "keyframes save reuse copy paste prefab template animation library"
                }
            }

            ThemedLabel {
                width: parent.width
                text: qsTr("Save this clip's keyframes, then apply them to any clip in any project. A preset starts at the playhead.")
            }

            ThemedButton {
                width: parent.width
                text: qsTr("Save keyframes as preset…")
                variant: "secondary"
                enabled: root.animatedCount > 0
                onClicked: saveDialog.openFor(EditorState.selectedTrack, EditorState.selectedClip,
                                              qsTr("My animation %1").arg(root.keyframePresets.length + 1))
            }

            ThemedLabel {
                visible: root.animatedCount === 0
                width: parent.width
                text: qsTr("This clip has no keyframes to save yet.")
            }

            ThemedSwitch {
                visible: root.keyframePresets.length > 0
                width: parent.width
                text: qsTr("Fit to this clip")
                tooltip: qsTr("On: move and size relative to where this clip already is, scaled to its size. Off: use the exact values the preset was saved with.")
                checked: root.fitPresets
                onToggled: root.fitPresets = checked
            }

            Repeater {
                model: root.keyframePresets
                delegate: Item {
                    id: presetRow
                    required property var modelData
                    width: presetSection.width
                    height: Math.max(presetText.implicitHeight, applyChip.height)

                    Column {
                        id: presetText
                        anchors.left: parent.left
                        anchors.right: applyChip.left
                        anchors.rightMargin: Theme.spacingSm
                        anchors.verticalCenter: parent.verticalCenter

                        ThemedLabel {
                            width: parent.width
                            text: presetRow.modelData.label
                            tone: "default"
                            size: "sm"
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                        ThemedLabel {
                            width: parent.width
                            text: qsTr("%n propert(ies)", "", presetRow.modelData.properties.length)
                                  + " · " + qsTr("%1 s").arg(Number(presetRow.modelData.duration).toFixed(2))
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                    }

                    ThemedChip {
                        id: applyChip
                        anchors.right: moreButton.left
                        anchors.rightMargin: Theme.spacingXs
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Apply")
                        tooltip: presetRow.modelData.properties.join(", ")
                        onClicked: EditorState.applyKeyframePreset(EditorState.selectedTrack,
                                                                   EditorState.selectedClip,
                                                                   presetRow.modelData.id,
                                                                   root.fitPresets,
                                                                   EditorState.playheadSeconds)
                    }

                    IconButton {
                        id: moreButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        glyph: Theme.icons.ellipsis
                        tooltip: qsTr("More")
                        onClicked: {
                            root.menuPreset = presetRow.modelData
                            presetMenu.popup(moreButton, 0, moreButton.height)
                        }
                    }
                }
            }
        }
    }

    ThemedContextMenu {
        id: presetMenu
        implicitWidth: 160

        ThemedMenuItem {
            text: qsTr("Rename…")
            onTriggered: renameDialog.openWith(qsTr("Rename keyframe preset"), root.menuPreset.label)
        }

        ThemedMenuItem {
            text: qsTr("Delete")
            icon.name: Theme.icons.trash
            onTriggered: deleteDialog.open()
        }
    }

    NameDialog {
        id: renameDialog
        onSubmitted: (name) => EditorState.renameKeyframePreset(root.menuPreset.id, name)
    }

    ThemedDialog {
        id: deleteDialog
        title: qsTr("Delete keyframe preset?")
        acceptText: qsTr("Delete")
        acceptVariant: "destructive"
        preferredWidth: Theme.dialogWidthSm
        onAccepted: EditorState.deleteKeyframePreset(root.menuPreset.id)

        contentItem: ThemedLabel {
            text: root.menuPreset
                  ? qsTr("“%1” will be removed from every project. Keyframes already applied to clips stay.").arg(root.menuPreset.label)
                  : ""
            tone: "default"
            size: "sm"
        }
    }

    KeyframePresetSaveDialog {
        id: saveDialog
    }
}
