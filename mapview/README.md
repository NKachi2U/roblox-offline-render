# mapview: see a Roblox map without Studio

Renders a `.rbxm`, `.rbxmx`, `.rbxl` or `.rbxlx` file to images:

- **Floor plans** of every level (SVG, plus PNG when Chrome or Edge is installed): a section through
  each storey with walls outlined, furniture, a 10-stud grid and scale bar, group names (your Models
  and Folders), SpawnLocations, ProximityPrompts with their action text, and parts with tags you ask for.
- **3D views** (PNG): the whole map from the south-east and north-west, and each level from above with
  the floors over it lifted off.
- **A summary** (`.txt`): bounds, levels, groups with sizes and positions, spawns, prompts, tags.

```bash
lune run path/to/mapview/run.luau MyMap.rbxm
lune run path/to/mapview/run.luau place.rbxl --path Workspace.Map
lune run path/to/mapview/run.luau MyMap.rbxm --levels 0,16 --tags Door,Loot
```

Outputs go to `artifacts/mapview/<name>-plan-<level>.png`, `<name>-view-<se|nw|levelN>.png` and
`<name>-summary.txt`.

| Flag | |
|---|---|
| `--path <A.B.C>` | Draw only this instance. Place files default to everything in Workspace. |
| `--levels <y,y,...>` | Floor heights, if the automatic ones are wrong |
| `--tags <A,B>` | Mark parts with these CollectionService tags on the plans |
| `--size WxH` | 3D view size (default 1400x900) |
| `--views <file.json>` | Extra cameras: `{ "name": { "eye": [x,y,z], "target": [x,y,z], "fov": 60, "size": [w,h], "ortho": pxPerStud, "maxBottom": y } }` |
| `--all` | Frame every part (distant scenery is left out of the framing by default) |
| `--plans-only` / `--views-only` | Skip the other kind |
| `--out <dir>` | Output folder (default `./artifacts/mapview`) |
| `--no-png` | Plans as SVG only |

To get a file out of Studio: right-click a model, **Save to File...** (`.rbxm`), or save the whole place
(`.rbxl`). From a Rojo project, `rojo build -o place.rbxl`.

## How it works

- **Levels** are found from the tops of large flat parts, weighted by area. A level needs walls standing
  on it, so a flat roof isn't counted, and a floor resting on a baseplate wins over the baseplate.
- **Framing** leaves out huge thin slabs (a Baseplate) and parts far from everything else (a mountain
  backdrop), so the camera fits the building. The summary says how many were left out.
- **3D views** come from a small software rasterizer: flat sun shading, transparency, a little fog.
  It shows form and layout, not Roblox lighting.

## Limits

- MeshParts and unions are drawn as their bounding boxes. Terrain isn't drawn.
- Parts with Transparency 0.95 or more are skipped (invisible collision boxes, triggers).
- Textures, decals and SurfaceGuis aren't drawn.

## Files

`run.luau` command line · `geometry.luau` loading, bounds, levels · `plan.luau` SVG floor plans ·
`raster.luau` 3D views · `png.luau` PNG writer. PNG plans use `../uikit/browser.luau`.
