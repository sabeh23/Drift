.pragma library

// Workspace layout edits. A layout node is a split {split: "h"|"v", sizes, children} or a leaf
// {panels: [{type, tab?}], active}.

function clone(value) {
    return JSON.parse(JSON.stringify(value))
}

function isLeaf(node) {
    return node.split === undefined
}

function find(node, type, parent, index) {
    if (isLeaf(node)) {
        const panels = node.panels || []
        for (let i = 0; i < panels.length; ++i) {
            if (panels[i].type === type)
                return { leaf: node, parent: parent, index: index, panelIndex: i }
        }
        return null
    }
    for (let i = 0; i < node.children.length; ++i) {
        const hit = find(node.children[i], type, node, i)
        if (hit)
            return hit
    }
    return null
}

function evenSizes(count) {
    const sizes = []
    for (let i = 0; i < count; ++i)
        sizes.push(1 / count)
    return sizes
}

function fixSizes(node) {
    if (!node.sizes || node.sizes.length !== node.children.length) {
        node.sizes = evenSizes(node.children.length)
        return
    }
    let sum = 0
    for (let i = 0; i < node.sizes.length; ++i)
        sum += node.sizes[i]
    if (sum <= 0) {
        node.sizes = evenSizes(node.children.length)
        return
    }
    for (let i = 0; i < node.sizes.length; ++i)
        node.sizes[i] = node.sizes[i] / sum
}

// Drops empty leaves and splits left with a single child, which takes its parent's place.
function normalize(node) {
    if (isLeaf(node))
        return (node.panels || []).length > 0 ? node : null
    const children = []
    const sizes = []
    for (let i = 0; i < node.children.length; ++i) {
        const child = normalize(node.children[i])
        if (!child)
            continue
        children.push(child)
        sizes.push(node.sizes && node.sizes.length === node.children.length ? node.sizes[i] : 1)
    }
    if (children.length === 0)
        return null
    if (children.length === 1)
        return children[0]
    node.children = children
    node.sizes = sizes
    fixSizes(node)
    return node
}

// Moves panel `type` next to (zone "left" | "right" | "top" | "bottom") or into (zone "center")
// the slot showing `targetType`. Returns the edited workspace, or null when nothing would change.
function movePanel(workspace, type, targetType, zone) {
    const next = clone(workspace)
    const windows = next.windows || []
    for (let w = 0; w < windows.length; ++w) {
        const win = windows[w]
        const src = find(win.root, type, null, -1)
        const dst = find(win.root, targetType, null, -1)
        if (!src || !dst)
            continue
        if (src.leaf === dst.leaf && (zone === "center" || src.leaf.panels.length === 1))
            return null

        const entry = src.leaf.panels.splice(src.panelIndex, 1)[0]
        src.leaf.active = Math.max(0, Math.min(src.leaf.active || 0, src.leaf.panels.length - 1))

        // Whatever is left in the target slot names it from here on (the dragged panel may have
        // been the one it was found by).
        if (dst.leaf.panels.length === 0)
            return null
        const anchorType = dst.leaf.panels[0].type

        const root = normalize(win.root)
        if (!root)
            return null
        win.root = root

        const at = find(win.root, anchorType, null, -1)
        if (!at)
            return null

        if (zone === "center") {
            at.leaf.panels.push(entry)
            at.leaf.active = at.leaf.panels.length - 1
            return next
        }

        const fresh = { panels: [entry], active: 0 }
        const orientation = (zone === "left" || zone === "right") ? "h" : "v"
        const before = zone === "left" || zone === "top"
        if (at.parent && at.parent.split === orientation) {
            fixSizes(at.parent)
            const half = at.parent.sizes[at.index] / 2
            at.parent.sizes[at.index] = half
            const where = before ? at.index : at.index + 1
            at.parent.children.splice(where, 0, fresh)
            at.parent.sizes.splice(where, 0, half)
        } else {
            const wrapper = {
                split: orientation,
                sizes: [0.5, 0.5],
                children: before ? [fresh, at.leaf] : [at.leaf, fresh]
            }
            if (at.parent)
                at.parent.children[at.index] = wrapper
            else
                win.root = wrapper
        }
        return next
    }
    return null
}
