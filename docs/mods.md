# Mods

A mod is a folder of QML that Drift loads into fixed hook points of its own interface. Mods can
use everything the interface itself uses (`import Drift`: `EditorState`, `Workspaces`, `Theme`,
`Mods`, the themed controls), so a feature that needs no new engine code can be added, changed or
removed without rebuilding or reinstalling Drift.

Mods live in `<Documents>/Drift Mods/<mod folder>/` (`DRIFT_MODS_DIR` overrides the location). A new
mod is off until it is switched on in **Settings → Mods**: mods are ordinary QML and run with
Drift's own permissions. The folder is watched, so saving a file reloads the mods in place.

## Layout

```
Drift Mods/
  keyframe-diamonds/
    mod.json            optional
    TimelineClip.qml    one file per hook
```

`mod.json` (all fields optional):

```json
{
  "name": "Keyframe diamonds",
  "description": "Shows keyframes on timeline clips.",
  "author": "you",
  "version": "1.0",
  "hooks": { "timelineClip": "Diamonds.qml" }
}
```

Without a `hooks` entry, a hook loads the file named after it with a capital first letter
(`timelineClip` → `TimelineClip.qml`). Hook files must be inside the mod's folder.

## Hooks

Each hook instantiates the file with a `host` property. Declare `property var host` to receive it.

| Hook | Where | `host` |
|---|---|---|
| `app` | Once, filling the editor window, above the panels | The `ApplicationWindow` |
| `panel` | Over every panel slot of the workspace | The `WorkspaceSlot`: `host.entries` (`[{type}]`), `host.node`, `host.activeIndex` |
| `timelineClip` | Over every clip on the timeline | The `TimelineClipItem`: `host.trackIndex`, `host.clipIndex`, `host.clipData`, `host.panel.pxPerSecond` |
| `timelineToolbar` | Appended to the timeline toolbar's buttons | The toolbar item |

Overlay hooks (`app`, `panel`, `timelineClip`) fill their host and take no input unless the mod
adds something that does, so everything underneath keeps working.

## The `Mods` singleton

- `Mods.setting(modId, key, fallback)` / `Mods.setSetting(modId, key, value)`: small per-mod storage.
- `Mods.post(modId, topic, payload)` and the `message(modId, topic, payload)` signal: a mod's
  instances are separate objects (one per clip, one per panel); this is how they talk.
- `Mods.reload()`, `Mods.revision`, `Mods.folder`.

## Changing the layout from a mod

`Workspaces.workspace(Workspaces.activeId)` returns the active layout as a tree
(`windows[].root`, nodes are `{split, sizes, children}` or `{panels: [{type}], active}`), and
`Workspaces.saveWorkspace(tree)` applies an edited one immediately.
