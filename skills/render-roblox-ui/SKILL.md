---
name: render-roblox-ui
description: Render a Roblox game's ScreenGui/HUD/menu UI to PNG without opening Studio, by running the project's real client (and server) scripts offline. Use when writing, changing or reviewing UI code in a Rojo project, when asked to see, screenshot, preview or check UI layout, or to verify a UI fix at several screen sizes.
---

# Render Roblox UI offline

The tool is `uikit/run.luau`, two folders up from this skill's folder (`<skill folder>/../../uikit/run.luau`;
full docs in `uikit/README.md` next to it). It runs the place's real client scripts against a stand-in
Roblox client, and with `server = true` its real server scripts in loopback, then lays the GUI out with
Roblox's rules and screenshots it with headless Chrome or Edge.

## Workflow

1. Check `lune --version` works in the project (0.10+). If not, ask the user before installing it
   (`rokit add lune-org/lune` adds it to the project's rokit.toml).
2. Write a scenario in the project's `ui-scenarios/<name>.luau`:
   ```lua
   return {
   	size = "1280x720",                       -- optional, default 1920x1080
   	run = function(ui)
   		ui.boot({ server = true })           -- omit server if the server scripts can't run offline
   		ui.click("ShopGui/ShopButton")        -- queries: "Gui/Child/Grandchild", "text:PLAY", "class:TextButton"
   		ui.shot("open")
   		ui.dump("ShopGui/Window", { depth = 2 })  -- exact rects, better than guessing from pixels
   	end,
   }
   ```
3. Run from the project root (the folder with `default.project.json`):
   ```bash
   lune run <skill folder>/../../uikit/run.luau <name> [--size 1280x720] [--outline]
   ```
4. Read the PNGs in `artifacts/uikit/` with the Read tool. Crop to one element with
   `ui.shot("name", { crop = "Gui/Element" })`. `--outline` labels every element's box.
5. Read the run summary. Script errors are real errors in game code *or* missing emulation: read the
   trace. `WaitForChild(...) never resolved` and `not emulated` warnings usually mean the game expects
   something from the place file: add `ui.fixture("ReplicatedStorage.Thing", "Folder")`, answer remotes
   with `ui.remote(path, fn)`, or ask the user for a saved place to pass as `--placefile`.
6. Check at more than one size (1920x1080, 1280x720, and a phone such as 844x390) before calling a
   layout done.

## Keep in mind

- Offline limits: no 3D (ViewportFrames are hatched placeholders, SurfaceGui/BillboardGui skipped),
  `rbxassetid://` images are hatched unless `uikit-assets/<id>.png` exists, tweens show their end
  state. Don't report these as UI bugs.
- The faint rounded squares top-left are the Roblox top bar buttons; UI under them is a real collision.
- Scenarios can assert on state (`assert(ui.find("Gui/Coins").Text == "950")`) so a run fails loudly.
- Keep `artifacts/` out of version control.
