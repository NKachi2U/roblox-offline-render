--[[
	The `ui` object a scenario drives. See README.md for the full API.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Runtime = require("./runtime")
local World = require("./world")
local Layout = require("./layout")
local Paint = require("./paint")
local Clock = require("./clock")

local Enum = roblox.Enum
local Vector2 = roblox.Vector2
local Vector3 = roblox.Vector3

local STATE = Runtime.STATE

local Harness = {}

local ABS_KEYS = { "AbsoluteSize", "AbsolutePosition", "AbsoluteContentSize", "AbsoluteWindowSize", "AbsoluteCanvasSize", "TextBounds" }

-- Fires AbsoluteSize/... change signals for anything watching them. Returns true if any fired.
local function fireAbsoluteChanges(): boolean
	Layout.ensure()
	local fired = false
	for inst in Runtime.absWatchers do
		local s = STATE[inst]
		if s.destroyed then
			continue
		end
		s.reported = s.reported or {}
		for _, key in ABS_KEYS do
			local sig = s.propSignals[key]
			if sig and sig:hasListeners() then
				local value = Layout.read(inst, key)
				local last = s.reported[key]
				if last == nil then
					last = Vector2.zero
				end
				if value ~= last then
					s.reported[key] = value
					sig:Fire()
					fired = true
				end
			end
		end
	end
	return fired
end

local function settle()
	for _ = 1, 16 do
		task.wait()
		Layout.ensure()
		local fired = fireAbsoluteChanges()
		task.wait()
		if not fired and not Runtime.dirty then
			return
		end
	end
end

local frameClock = 0
local function frame(dt: number)
	frameClock += dt
	local rs = Runtime.service("RunService")
	for _, name in { "PreRender", "RenderStepped" } do
		Runtime.fireIf(rs, name, dt)
	end
	local steps = {}
	for name, step in Runtime.renderSteps do
		table.insert(steps, { name = name, priority = step.priority, fn = step.fn })
	end
	table.sort(steps, function(a, b)
		return a.priority < b.priority
	end)
	for _, step in steps do
		Runtime.spawnGuarded(`RenderStep {step.name}`, step.fn, dt)
	end
	Runtime.fireIf(rs, "Stepped", frameClock, dt)
	Runtime.fireIf(rs, "PreSimulation", dt)
	Runtime.fireIf(rs, "Heartbeat", dt)
	Runtime.fireIf(rs, "PostSimulation", dt)
	fireAbsoluteChanges()
end

-- ── Finding things ────────────────────────────────────────────────────────────
local function effectivelyVisible(inst): boolean
	local cur = inst
	while cur do
		local s = STATE[cur]
		if s.info.isa.GuiObject and not cur.Visible then
			return false
		end
		if s.class == "ScreenGui" then
			return cur.Enabled
		end
		cur = s.parent
	end
	return false
end

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

local function matchesSegment(inst, segment: string): boolean
	local s = STATE[inst]
	local text = string.match(segment, "^text:(.+)$")
	if text then
		if not Layout.isTextObject(inst) then
			return false
		end
		local content = trim(string.lower(Runtime.text.stripRich(inst.Text)))
		return content == trim(string.lower(text))
	end
	local class = string.match(segment, "^class:(.+)$")
	if class then
		return s.info.isa[class] == true
	end
	return Runtime.nameOf(inst) == segment
end

local function searchDescendants(root, segment: string, out)
	for _, child in STATE[root].children do
		if matchesSegment(child, segment) then
			table.insert(out, child)
		end
		searchDescendants(child, segment, out)
	end
end

-- Query forms: an Instance; "ScreenGui/Name/Name" (each step searches descendants);
-- steps may be "text:PLAY" or "class:TextButton". Visible matches win.
local function findAll(query, root)
	if Runtime.isInstance(query) then
		return { query }
	end
	root = root or Runtime.playerGui
	local segments = {}
	if type(query) == "table" then
		segments = query
	else
		-- "text:" swallows the rest of the query so labels may contain "/".
		local head, text = string.match(query, "^(.-)/?(text:.*)$")
		for segment in string.gmatch(head or query, "[^/]+") do
			table.insert(segments, segment)
		end
		if text then
			table.insert(segments, text)
		end
	end
	local current = { root }
	for _, segment in segments do
		local nextSet = {}
		for _, node in current do
			searchDescendants(node, segment, nextSet)
		end
		current = nextSet
		if #current == 0 then
			return {}
		end
	end
	local visible, hidden = {}, {}
	for _, inst in current do
		table.insert(effectivelyVisible(inst) and visible or hidden, inst)
	end
	for _, inst in hidden do
		table.insert(visible, inst)
	end
	return visible
end

local function find(query, root)
	settle()
	return findAll(query, root)[1]
end

local function mustFind(query, action: string)
	local inst = find(query)
	if not inst then
		error(`ui.{action}: nothing matches {tostring(query)}`, 3)
	end
	if not effectivelyVisible(inst) then
		Runtime.warnOnce(`hidden:{action}:{tostring(query)}`, `ui.{action}({tostring(query)}): target is not visible on screen`)
	end
	return inst
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function inputObject(inputType, state, keyCode, position)
	return setmetatable({
		UserInputType = inputType,
		UserInputState = state,
		KeyCode = keyCode or Enum.KeyCode.Unknown,
		Position = position or Vector3.new(Runtime.mouse.X, Runtime.mouse.Y - Runtime.topInset, 0),
		Delta = Vector3.zero,
		IsModifierKeyDown = function()
			return false
		end,
	}, { __type = "InputObject" })
end

local hovered = nil

local function center(inst)
	Layout.ensure()
	local a = STATE[inst].abs
	if not Layout.valid(inst) then
		return Runtime.mouse.X, Runtime.mouse.Y
	end
	return a.x + a.w / 2, a.y + a.h / 2
end

local function moveTo(inst)
	local x, y = center(inst)
	Runtime.mouse = Vector2.new(x, y)
	local uis = Runtime.service("UserInputService")
	Runtime.fireIf(uis, "InputChanged", inputObject(Enum.UserInputType.MouseMovement, Enum.UserInputState.Change), false)
	if hovered ~= inst then
		if hovered and not STATE[hovered].destroyed then
			STATE[hovered].hovered = false
			Runtime.fireIf(hovered, "MouseLeave", x, y - Runtime.topInset)
		end
		hovered = inst
		STATE[inst].hovered = true
		Runtime.fireIf(inst, "MouseEnter", x, y - Runtime.topInset)
	end
	Runtime.fireIf(inst, "MouseMoved", x, y - Runtime.topInset)
	return x, y
end

local function isWithin(inst, ancestor)
	return inst == ancestor or inst:IsDescendantOf(ancestor)
end

-- ── The ui object ─────────────────────────────────────────────────────────────
function Harness.create(context)
	local ui = {}
	ui.game = Runtime.game
	ui.player = Runtime.player
	ui.playerGui = Runtime.playerGui
	ui.runtime = Runtime
	ui.Enum = Enum
	ui.shots = {}

	-- Runs the place's client scripts, then waits until nothing is parked in WaitForChild.
	-- opts.server = true also runs the place's real server scripts (loopback), so the UI gets
	-- real payloads from in-memory DataStores instead of scenario fixtures.
	local function waitQuiet(timeout: number)
		local deadline = os.clock() + timeout
		local quiet = 0
		while os.clock() < deadline and quiet < 3 do
			settle()
			if Clock.enabled then
				Clock.advance(1 / 30)
			end
			task.wait(0.03)
			quiet = (Runtime.pendingWaits == 0 and Runtime.pendingDelays == 0) and quiet + 1 or 0
		end
	end

	function ui.boot(opts)
		opts = opts or {}
		if opts.server then
			World.startServer()
			waitQuiet(opts.timeout or 10)
		end
		if opts.character then
			World.join()
			World.spawnCharacter()
		end
		World.startClient(opts)
		waitQuiet(opts.timeout or 10)
		if opts.wait then
			ui.wait(opts.wait)
		end
		settle()
	end

	-- context: "client" (default) or "server" — each side has its own module cache.
	function ui.require(path: string, context: string?)
		local inst = Runtime.game
		for part in string.gmatch(path, "[^%.]+") do
			inst = inst:FindFirstChild(part)
			assert(inst, `ui.require: no {part} in {path}`)
		end
		return Runtime.require(inst, context)
	end

	-- Creates stand-ins for world objects the place file would provide (e.g. camera parts).
	function ui.fixture(path: string, className: string?, props)
		local parent = Runtime.game
		local parts = string.split(path, ".")
		for i, part in parts do
			local child = parent:FindFirstChild(part)
			if not child then
				child = Runtime.Instance.new(i == #parts and (className or "Part") or "Folder")
				child.Name = part
				child.Parent = parent
			end
			parent = child
		end
		for key, value in props or {} do
			parent[key] = value
		end
		return parent
	end

	-- Spawns a bare character for the player (fires CharacterAdded) — also ui.boot({ character = true }).
	function ui.spawnCharacter()
		World.join()
		local character = World.spawnCharacter()
		settle()
		return character
	end

	-- A bare R15-shaped rig (Humanoid + HumanoidRootPart + body parts), unparented.
	-- parentPath (optional): dotted path to parent it under, e.g. "ReplicatedStorage.Models".
	function ui.rig(name: string?, parentPath: string?)
		local rig = World.buildRig(name or "Rig")
		if parentPath then
			local parent = Runtime.game
			for part in string.gmatch(parentPath, "[^%.]+") do
				parent = parent:FindFirstChild(part)
				assert(parent, `ui.rig: no {part} in {parentPath}`)
			end
			rig.Parent = parent
		end
		return rig
	end

	-- Installs a bare rig as StarterPlayer.StarterCharacter (places that ship a custom character).
	function ui.starterCharacter()
		local existing = Runtime.game.StarterPlayer:FindFirstChild("StarterCharacter")
		if existing then
			return existing
		end
		local rig = World.buildRig("StarterCharacter")
		rig.Parent = Runtime.game.StarterPlayer
		return rig
	end

	ui.find = find
	ui.findAll = function(query, root)
		settle()
		return findAll(query, root)
	end
	ui.settle = settle
	ui.visible = effectivelyVisible

	function ui.wait(seconds: number?)
		if Clock.enabled then
			-- virtual time: 60 steps per second, no real sleeping
			local target = Clock.now + (seconds or 0)
			while Clock.now < target - 1e-9 do
				local dt = math.min(1 / 60, target - Clock.now)
				Clock.advance(dt)
				frame(dt)
			end
			settle()
			return
		end
		local deadline = os.clock() + (seconds or 0)
		repeat
			local dt = task.wait(1 / 30)
			frame(dt)
		until os.clock() >= deadline
		settle()
	end

	function ui.hover(query)
		local inst = mustFind(query, "hover")
		moveTo(inst)
		settle()
		return inst
	end

	function ui.click(query, opts)
		opts = opts or {}
		local inst = mustFind(query, "click")
		-- Clicking a label inside a button clicks the button, as in Roblox.
		if not STATE[inst].info.isa.GuiButton and STATE[inst].class ~= "TextBox" then
			local button = inst:FindFirstAncestorWhichIsA("GuiButton")
			if button then
				inst = button
			end
		end
		settle()
		local x, y = moveTo(inst)
		local hits = Layout.hitTest(x, y, true)
		local top
		for _, hit in hits do
			if hit.Active or STATE[hit].info.isa.GuiButton or STATE[hit].class == "TextBox" then
				top = hit
				break
			end
		end
		if top and not isWithin(top, inst) and not isWithin(inst, top) then
			local message = `ui.click({tostring(query)}): {top:GetFullName()} is on top at that point — in-game the click would land there`
			print(`\27[33m[uikit] {message}\27[0m`)
			table.insert(Runtime.warnings, message)
		end
		local uis = Runtime.service("UserInputService")
		local button = opts.right and Enum.UserInputType.MouseButton2 or Enum.UserInputType.MouseButton1
		local down = inputObject(button, Enum.UserInputState.Begin)
		Runtime.fireIf(inst, "InputBegan", down)
		Runtime.fireIf(uis, "InputBegan", down, true)
		local rx, ry = x - STATE[inst].abs.x, y - STATE[inst].abs.y
		if opts.right then
			Runtime.fireIf(inst, "MouseButton2Down", x, y - Runtime.topInset)
		else
			Runtime.fireIf(inst, "MouseButton1Down", x, y - Runtime.topInset)
		end
		task.wait()
		local up = inputObject(button, Enum.UserInputState.End)
		Runtime.fireIf(inst, "InputEnded", up)
		Runtime.fireIf(uis, "InputEnded", up, true)
		if opts.right then
			Runtime.fireIf(inst, "MouseButton2Up", x, y - Runtime.topInset)
			Runtime.fireIf(inst, "MouseButton2Click")
		else
			Runtime.fireIf(inst, "MouseButton1Up", x, y - Runtime.topInset)
			Runtime.fireIf(inst, "MouseButton1Click")
			Runtime.fireIf(inst, "Activated", up, 1)
		end
		if STATE[inst].class == "TextBox" then
			inst:CaptureFocus()
		end
		local _ = rx + ry
		settle()
		return inst
	end

	function ui.type(query, text: string, submit: boolean?)
		local box = mustFind(query, "type")
		box:CaptureFocus()
		Runtime.focusedTextBox = box
		box.Text = text
		box.CursorPosition = #text + 1
		Runtime.focusedTextBox = nil
		box:ReleaseFocus(submit == true)
		settle()
		return box
	end

	function ui.key(keyCode, opts)
		opts = opts or {}
		if type(keyCode) == "string" then
			keyCode = (Enum.KeyCode :: any)[keyCode]
		end
		local uis = Runtime.service("UserInputService")
		local down = inputObject(Enum.UserInputType.Keyboard, Enum.UserInputState.Begin, keyCode)
		Runtime.keysDown[keyCode] = true
		Runtime.fireIf(uis, "InputBegan", down, opts.processed == true)
		for name, action in Runtime.actions do
			if table.find(action.keys, keyCode) then
				Runtime.spawnGuarded(`action {name}`, action.fn, name, Enum.UserInputState.Begin, down)
			end
		end
		task.wait()
		local up = inputObject(Enum.UserInputType.Keyboard, Enum.UserInputState.End, keyCode)
		Runtime.keysDown[keyCode] = nil
		Runtime.fireIf(uis, "InputEnded", up, opts.processed == true)
		for name, action in Runtime.actions do
			if table.find(action.keys, keyCode) then
				Runtime.spawnGuarded(`action {name}`, action.fn, name, Enum.UserInputState.End, up)
			end
		end
		settle()
	end

	function ui.set(query, key: string, value)
		local inst = mustFind(query, "set")
		inst[key] = value
		settle()
		return inst
	end

	-- Plays the server: fires the client's Red :On handlers (queued until one connects, like remotes).
	function ui.server(service: string, event: string, ...)
		Runtime.red.deliver(service, event, ...)
		settle()
	end

	-- Seeds an in-memory DataStore before a loopback server reads it.
	-- Teleport data this player "arrived" with (GetLocalPlayerTeleportData / GetJoinData).
	function ui.teleportData(data)
		World.teleportData = data
	end

	-- The ScreenGui last handed to TeleportService:SetTeleportGui (nil if none).
	function ui.teleportGui()
		return World.teleportGui
	end

	function ui.datastore(name: string, key: string, value)
		Runtime.datastores[name] = Runtime.datastores[name] or {}
		Runtime.datastores[name][key] = Runtime.deepCopy(value)
	end

	-- Answers client Fire/Call traffic: fn(...) runs when the client sends service.event.
	function ui.reply(service: string, event: string, fn)
		Runtime.red.replies[service] = Runtime.red.replies[service] or {}
		Runtime.red.replies[service][event] = fn
	end

	-- A RemoteEvent / RemoteFunction by DataModel path ("ReplicatedStorage.Remotes.Buy"),
	-- created as `className` if the game hasn't made it yet.
	local function remoteAt(path: string, className: string)
		local inst = Runtime.game
		local parts = string.split(path, ".")
		for index, part in parts do
			local child = inst:FindFirstChild(part)
			if not child then
				child = Runtime.Instance.new(if index == #parts then className else "Folder")
				child.Name = part
				child.Parent = inst
			end
			inst = child
		end
		return inst
	end

	-- Plays the server for a plain remote: fn(player, ...) handles FireServer, and for a
	-- RemoteFunction its return value answers InvokeServer. A missing remote is created as
	-- `className` (default RemoteEvent; pass "RemoteFunction" when the server isn't running).
	function ui.remote(path: string, fn, className: string?)
		local inst = remoteAt(path, className or "RemoteEvent")
		if inst:IsA("RemoteFunction") then
			inst.OnServerInvoke = fn
		else
			inst.OnServerEvent:Connect(fn)
		end
	end

	-- Server -> client on a plain RemoteEvent (fires OnClientEvent; queued until the client listens).
	function ui.fireClient(path: string, ...)
		remoteAt(path, "RemoteEvent"):FireAllClients(...)
	end

	function ui.traffic()
		for _, line in Runtime.red.traffic do
			print(`  {line}`)
		end
	end

	-- Prints the GUI tree with screen rects (what Claude reads instead of eyeballing).
	function ui.dump(query, opts)
		opts = opts or {}
		settle()
		local root = query and mustFind(query, "dump") or Runtime.playerGui
		local maxDepth = opts.depth or 99
		local lines = {}
		local function visit(inst, depth)
			local s = STATE[inst]
			if not (s.info.isa.GuiBase2d or opts.all) then
				return
			end
			local a = s.abs
			local rect = Layout.valid(inst) and a.x
				and string.format("(%d,%d %dx%d)", math.round(a.x), math.round(a.y), math.round(a.w), math.round(a.h))
				or "(not laid out)"
			local flags = {}
			if s.info.isa.GuiObject and not inst.Visible then
				table.insert(flags, "hidden")
			end
			if s.class == "ScreenGui" and not inst.Enabled then
				table.insert(flags, "disabled")
			end
			local text = ""
			if Layout.isTextObject(inst) then
				local t = Runtime.text.stripRich(inst.Text)
				if #t > 40 then
					t = string.sub(t, 1, 40) .. "…"
				end
				text = ` "{string.gsub(t, "\n", "⏎")}"`
			end
			table.insert(lines, `{string.rep("  ", depth)}{Runtime.nameOf(inst)} [{s.class}] {rect}{text}{#flags > 0 and " {" .. table.concat(flags, ",") .. "}" or ""}`)
			if depth < maxDepth and (opts.hidden or not table.find(flags, "hidden")) then
				for _, child in s.children do
					visit(child, depth + 1)
				end
			end
		end
		for _, child in (root == Runtime.playerGui and STATE[root].children or { root }) do
			visit(child, 0)
		end
		local out = table.concat(lines, "\n")
		print(out)
		return out
	end

	-- Renders the current screen to <out>/<scenario>-<name>.html and .png.
	function ui.shot(name: string?, opts)
		opts = opts or {}
		name = name or `shot{#ui.shots + 1}`
		settle()
		local base = `{context.outDir}/{context.scenario}-{name}`
		local html = Paint.html({
			outline = opts.outline or context.outline,
			topbar = opts.topbar,
			backdrop = opts.backdrop or context.backdrop,
			title = `{context.scenario} — {name}`,
		})
		fs.writeFile(`{base}.html`, html)
		local png = `{base}.png`
		if context.png ~= false then
			context.screenshot(`{base}.html`, png, opts.crop and find(opts.crop))
		end
		table.insert(ui.shots, png)
		print(`\27[32m[uikit] {name}: {png}\27[0m`)
		return png
	end

	-- Animate mode: a shot every `step` seconds for `duration`, plus a contact sheet
	-- (<scenario>-<name>-sheet.png) laying the frames out in order with their timestamps.
	function ui.filmstrip(name: string, duration: number, step: number, opts)
		opts = opts or {}
		assert(Clock.enabled, "ui.filmstrip needs `animate = true` in the scenario")
		local frames = {}
		local t0 = Clock.now
		local elapsed = 0
		while true do
			local shot = ui.shot(string.format("%s-%02d", name, #frames + 1), { topbar = false })
			table.insert(frames, { png = shot, t = elapsed })
			if elapsed >= duration - 1e-6 then
				break
			end
			local dt = math.min(step, duration - elapsed)
			ui.wait(dt)
			elapsed = Clock.now - t0
		end
		local cols = opts.columns or 4
		local vp = Runtime.viewport
		local thumbW = 440
		local thumbH = math.floor(thumbW * vp.Y / vp.X)
		local cells = {}
		for _, f in frames do
			local file = string.match(f.png, "([^/\]+)$")
			table.insert(cells, `<figure><img src="{file}" width="{thumbW}" height="{thumbH}"><figcaption>t = {string.format("%.2f", f.t)}s</figcaption></figure>`)
		end
		local rows = math.ceil(#frames / cols)
		local sheetW = cols * (thumbW + 16) + 16
		local sheetH = rows * (thumbH + 40) + 16
		local html = `<!doctype html><html><head><meta charset="utf-8"><style>body\{margin:0;background:#050404;width:{sheetW}px;height:{sheetH}px;display:flex;flex-wrap:wrap;padding:8px;box-sizing:border-box\}figure\{margin:8px;width:{thumbW}px\}img\{display:block;outline:1px solid #2a2820\}figcaption\{font:12px monospace;color:#8a7c5c;padding-top:4px\}</style></head><body>{table.concat(cells)}</body></html>`
		local base = `{context.outDir}/{context.scenario}-{name}-sheet`
		fs.writeFile(`{base}.html`, html)
		if context.png ~= false then
			context.screenshot(`{base}.html`, `{base}.png`, nil, { sheetW, sheetH })
		end
		print(`[32m[uikit] {name} filmstrip: {base}.png ({#frames} frames)[0m`)
		return `{base}.png`
	end

	function ui.log()
		for _, line in Runtime.log do
			print(`  │ {line}`)
		end
	end

	ui.exit = function(code)
		process.exit(code or 0)
	end

	return ui
end

return Harness
