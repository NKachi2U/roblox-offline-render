# uikit: render Roblox UI without Studio

Runs your place's **real client scripts** (and, if you want, its real server scripts) in Lune against
a stand-in Roblox client, lays the GUI out with Roblox's rules, and screenshots it with headless
Chrome or Edge.

Run it from your Rojo project (the folder with `default.project.json`):

```bash
lune run path/to/uikit/run.luau shop-open                  # ./ui-scenarios/shop-open.luau
lune run path/to/uikit/run.luau shop-open --outline        # magenta boxes + names on every element
lune run path/to/uikit/run.luau hud --size 1366x768
```

Outputs: `artifacts/uikit/<scenario>-<shot>.png` plus a self-contained `.html` (fonts embedded; open it
in a browser and hover elements to see their full path).

| Flag | |
|---|---|
| `--place <dir>` | Rojo project to load (default: the current folder) |
| `--size WxH` | Screen size (default 1920x1080) |
| `--outline` | Draw every element's box and name |
| `--studio` | `RunService:IsStudio()` returns true |
| `--echo` | Show the game's `print` output |
| `--no-png` | HTML only |
| `--scenarios <dir>` | Where bare scenario names are looked up (default `./ui-scenarios`) |
| `--out <dir>` | Output folder (default `./artifacts/uikit`) |
| `--assets <dir>` | Where `<id>.png` files for `rbxassetid://` images live (default `./uikit-assets`) |
| `--backdrop <image>` | Drawn behind the UI, e.g. a screenshot of your game |
| `--placefile <file.rbxl>` | Merge a saved place's non-Rojo content (maps, rigs, Studio-built UI), like `rojo serve` into that place |
| `--animate` | Run tweens over time instead of jumping to the end (needed for `ui.filmstrip`) |
| `--rebuild-fonts` | Re-read font metrics from the Roblox install |

## Setup

- [Lune](https://github.com/lune-org/lune) 0.10 (`rokit add lune-org/lune` in your project).
- Roblox Studio installed, for the fonts. The first run measures them into `uikit/fonts.json`
  (a few seconds). Elsewhere, set `ROBLOX_CONTENT_DIR` to a folder that contains `fonts/families`.
- Chrome or Edge for the PNGs. Without one you still get the HTML.

## Scenarios

A scenario is a Lune module returning `{ place?, size?, studio?, animate?, run = function(ui) ... end }`.
Files starting with `_` are helpers you can `require` from scenarios; they aren't listed as scenarios.

```lua
return {
	size = "1280x720",
	run = function(ui)
		ui.boot({ server = true })             -- real server scripts in loopback
		ui.click("ShopGui/ShopButton/Button")
		ui.shot("open")
		assert(ui.find("ShopGui/Wallet/Amount").Text == "1,250")
	end,
}
```

## The `ui` API

| Call | What it does |
|---|---|
| `ui.boot(opts)` | Runs client scripts (StarterPlayerScripts, StarterGui) and waits until they settle. `server = true` runs ServerScriptService first, in loopback (PlayerAdded, remotes, in-memory DataStores). `character = true` spawns a character. `loadingScreen = true` runs ReplicatedFirst. `wait = s` waits longer. |
| `ui.shot(name, { crop = query, outline = true })` | Screenshot, optionally cropped to one element. |
| `ui.dump(query?, { depth, hidden })` | Prints the GUI tree with screen rects. The fastest way to check layout in numbers. |
| `ui.click(query)` / `ui.hover(query)` / `ui.type(query, text, submit)` / `ui.key("E")` | Input. Clicks warn when another Active element covers the target. |
| `ui.find(query)` / `ui.findAll(query)` / `ui.visible(inst)` | Queries: `"ShopGui/Window/Grid"` (each step searches descendants), `"text:PLAY"`, `"class:TextButton"`, or `{ "A", "B" }`. Visible matches win. |
| `ui.remote(path, fn, className?)` | Plays the server for a RemoteEvent or RemoteFunction at a DataModel path: `fn(player, ...)` handles `FireServer`, and its return value answers `InvokeServer`. |
| `ui.fireClient(path, ...)` | Fires a RemoteEvent's `OnClientEvent` (queued until the client connects, like Roblox). |
| `ui.datastore(name, key, value)` | Seeds a DataStore before `ui.boot({ server = true })`. |
| `ui.fixture("ReplicatedStorage.Thing", "Folder", props)` | Creates stand-ins for place-file objects (skipped if present). |
| `ui.starterCharacter()` / `ui.spawnCharacter()` | Custom StarterCharacter rig / spawn the player. |
| `ui.wait(s)` | Advances time, firing RenderStepped/Heartbeat. |
| `ui.filmstrip(name, duration, step)` | With `--animate`: a frame every `step` seconds plus a contact sheet. |
| `ui.server(service, event, ...)` / `ui.reply(service, event, fn)` / `ui.traffic()` | The same for games that use the [Red](https://github.com/red-blox/Red) networking library. |
| `ui.set(query, prop, value)` · `ui.log()` · `ui.require("ReplicatedStorage.X")` · `ui.teleportData(data)` | Misc. |

## What's emulated, and what isn't

- **Layout:** UDim2/AnchorPoint/SizeConstraint, UIScale, UIPadding, UIListLayout (wrap, flex, UIFlexItem),
  UIGridLayout, AutomaticSize, ScrollingFrame canvases + AutomaticCanvasSize + scrollbars,
  UIAspectRatio / UISize / UITextSize constraints, ZIndexBehavior, ClipsDescendants, CanvasGroup
  transparency, Rotation. `AbsoluteSize`/`AbsolutePosition`/`AbsoluteContentSize`/`TextBounds` are live
  and their change signals fire. UIPageLayout and UITableLayout fall back to list layout.
- **Paint:** backgrounds, borders, UICorner, UIStroke, UIGradient, text (real Roblox fonts, wrapping,
  RichText, TextScaled, truncation, stroke), images from `rbxasset://`.
- **Scripts:** Rojo projects (`$path`, `init` files, `.meta.json`, `.rbxm`, `.json`, `.txt`), ModuleScripts,
  `task`, signals, TweenService, RemoteEvents/RemoteFunctions in loopback, BindableEvents, in-memory
  DataStores, Players/LocalPlayer, attributes.
- **Tweens** jump to their goal (renders are snapshots); `Completed` still fires after the real duration.
- **Not rendered:** 3D (ViewportFrames draw as a hatched placeholder, SurfaceGui/BillboardGui are skipped),
  and `rbxassetid://` images, which draw hatched with their id. Drop `<id>.png` into `uikit-assets/` to
  use the real image.
- Anything the game reads that isn't emulated is reported as a warning rather than crashing the render.
  If you hit one, extending `world.luau` (services) or `runtime.luau` (instance behaviour) is usually a
  few lines.

## Files

`run.luau` command line · `harness.luau` the `ui` API · `runtime.luau` instances, signals, module loading,
Rojo mount · `world.luau` services, networking, DataStores · `layout.luau` Roblox layout · `text.luau`
text metrics and wrapping · `paint.luau` HTML painter · `browser.luau` headless Chrome over the DevTools
protocol · `fonts.luau` font metrics from the Roblox install · `content.luau` finds the Roblox install ·
`clock.luau` tween timing.
