pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Drift

// Saves a clip's keyframes as a keyframe preset: a name, and which of its animated properties to
// keep. Everything starts ticked, so the common case is type a name and press Save.
ThemedDialog {
    id: root

    property int trackIndex: -1
    property int clipIndex: -1
    property var candidates: []
    // prop -> bool; a plain object so the checkboxes can bind to it through a revision counter.
    property var chosen: ({})
    property int chosenRevision: 0

    readonly property int chosenCount: {
        void root.chosenRevision
        let n = 0
        for (let i = 0; i < root.candidates.length; ++i) {
            if (root.chosen[root.candidates[i].prop])
                ++n
        }
        return n
    }

    title: qsTr("Save keyframes as preset")
    acceptText: qsTr("Save")
    preferredWidth: Theme.dialogWidthSm

    function openFor(trackIndex, clipIndex, suggestedName) {
        root.trackIndex = trackIndex
        root.clipIndex = clipIndex
        root.candidates = EditorState.keyframePresetCandidates(trackIndex, clipIndex)
        const all = {}
        for (let i = 0; i < root.candidates.length; ++i)
            all[root.candidates[i].prop] = true
        root.chosen = all
        root.chosenRevision++
        nameField.text = suggestedName
        open()
        nameField.forceActiveFocus()
        nameField.selectAll()
    }

    onAccepted: {
        const name = nameField.text.trim()
        if (name.length === 0 || root.chosenCount === 0)
            return
        const props = []
        for (let i = 0; i < root.candidates.length; ++i) {
            const prop = root.candidates[i].prop
            if (root.chosen[prop])
                props.push(prop)
        }
        EditorState.saveKeyframePreset(root.trackIndex, root.clipIndex, name, props)
    }

    contentItem: Column {
        spacing: Theme.spacingLg
        width: parent ? parent.width : 320

        ThemedLabel {
            text: qsTr("Name")
        }

        ThemedTextField {
            id: nameField
            width: parent.width
            placeholderText: qsTr("My animation")
        }

        ThemedLabel {
            width: parent.width
            text: root.candidates.length > 0
                  ? qsTr("Keyframes to include")
                  : qsTr("This clip has no keyframes yet. Add some with the ◇ buttons next to a property, then save them here.")
        }

        Column {
            width: parent.width
            spacing: Theme.spacingXs
            visible: root.candidates.length > 0

            Repeater {
                model: root.candidates
                delegate: ThemedCheckBox {
                    required property var modelData
                    width: parent ? parent.width : 0
                    text: qsTr("%1 (%n key(s))", "", modelData.keyCount).arg(modelData.label)
                    checked: {
                        void root.chosenRevision
                        return !!root.chosen[modelData.prop]
                    }
                    onToggled: {
                        root.chosen[modelData.prop] = checked
                        root.chosenRevision++
                    }
                }
            }
        }
    }
}
