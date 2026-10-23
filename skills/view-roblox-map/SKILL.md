---
name: view-roblox-map
description: Render a Roblox map or build (.rbxm, .rbxmx, .rbxl, .rbxlx) to floor plans, 3D views and a text summary without Studio. Use after building or changing a map, model or level (by script, by MapKit-style generators, or by hand) to check its layout, room sizes, doors, stairs, spawns and prompts, or when asked to look at or review a map file.
---

# View a Roblox map offline

The tool is `mapview/run.luau`, two folders up from this skill's folder
(`<skill folder>/../../mapview/run.luau`; docs in `mapview/README.md` next to it).

## Workflow

1. Check `lune --version` works (0.10+). If not, ask the user before installing it.
2. Get a file: a `.rbxm`/`.rbxmx` model or a `.rbxl`/`.rbxlx` place. A Rojo project can make one with
   `rojo build -o place.rbxl`; a map built in Studio needs the user to save it (right-click, Save to
   File). A Lune build script can write one with `roblox.serializeModel`.
3. Run it:
   ```bash
   lune run <skill folder>/../../mapview/run.luau <file> [--path Workspace.Map] [--tags Door,Loot]
   ```
4. Read `artifacts/mapview/<name>-summary.txt` first (levels, groups with sizes and positions, prompts,
   spawns, tags), then the images with the Read tool:
   - `<name>-plan-<level>.png`: floor plan. Outlined shapes cross the cut line (walls); the grid is
     10 studs, so measure doorways and corridors off it.
   - `<name>-view-levelN.png`: that storey from above with the floors over it removed.
   - `<name>-view-se.png` / `-view-nw.png`: the outside.
5. If the levels are wrong (a mezzanine, a split-level), pass `--levels y1,y2`. If scenery swamps the
   framing, `--path` to the building.

## Keep in mind

- MeshParts and unions draw as bounding boxes; Terrain, textures and decals aren't drawn. Parts with
  Transparency 0.95+ are skipped.
- Lighting is a flat daylight approximation: judge layout and form, not mood.
- Check what the summary says against what was meant to be built (room count, door widths, spawn
  placement) and say plainly what doesn't match.
