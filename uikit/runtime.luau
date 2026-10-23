--[[
	A small stand-in for the Roblox client, written in Luau so the game's real UI code can run in Lune.

	Lune's own roblox.Instance has no events and is missing many GUI defaults, so instances here
	are plain tables: properties come from Lune's reflection database (plus the overrides below),
	events are real signals, tweens jump straight to their goal, and Absolute* / TextBounds are
	computed on demand by layout.luau. Everything the UI code touches that isn't GUI (Players,
	GuiService, UserInputService, Red, ...) is a light stub that behaves plausibly for a menu.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Enum = roblox.Enum
local Vector2 = roblox.Vector2
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
local Color3 = roblox.Color3
local Font = roblox.Font

local Runtime = {}

local db = roblox.getReflectionDatabase()

-- ── Shared state ──────────────────────────────────────────────────────────────
local STATE = setmetatable({}, { __mode = "k" }) -- instance -> internal state
Runtime.STATE = STATE
Runtime.dirty = true
Runtime.generation = 0
Runtime.viewport = Vector2.new(1920, 1080)
Runtime.topInset = 58 -- height of the Roblox top bar (GetGuiInset().Y) since the 2024 top bar
Runtime.errors = {}
Runtime.warnings = {}
Runtime.log = {}
Runtime.layout = nil -- set by run.luau (layout.luau)
Runtime.text = nil -- set by run.luau (text.luau)

local warnedOnce = {}
local function warnOnce(key: string, message: string)
	if warnedOnce[key] then
		return
	end
	warnedOnce[key] = true
	table.insert(Runtime.warnings, message)
	print(`\27[33m[uikit] {message}\27[0m`)
end
Runtime.warnOnce = warnOnce

local function reportError(where: string, err: any, trace: string?)
	if string.find(tostring(err), "Requested module experienced an error", 1, true) then
		return -- already reported where it happened
	end
	local message = `{where}: {tostring(err)}`
	if trace then
		-- Keep only frames from game code; the runtime's own frames are noise.
		local kept = {}
		for line in string.gmatch(trace, "[^\n]+") do
			if string.find(line, "[string", 1, true) then
				table.insert(kept, "    " .. string.gsub(line, '%[string "(.-)"%]', "%1"))
			end
		end
		if #kept > 0 then
			message ..= "\n" .. table.concat(kept, "\n")
		end
	end
	table.insert(Runtime.errors, message)
	print(`\27[31m[uikit] error in {message}\27[0m`)
end
Runtime.reportError = reportError

-- Runs fn in a new thread like task.spawn, but reports errors instead of losing them.
local function spawnGuarded(where: string, fn, ...)
	local args = table.pack(...)
	return task.spawn(function()
		local ok, err = xpcall(function()
			return fn(table.unpack(args, 1, args.n))
		end, function(e)
			return { e = e, trace = debug.traceback(nil, 2) }
		end)
		if not ok then
			reportError(where, err.e, err.trace)
		end
	end)
end
Runtime.spawnGuarded = spawnGuarded

-- ── Signals ───────────────────────────────────────────────────────────────────
local Connection = {}
Connection.__index = Connection
function Connection:Disconnect()
	self.Connected = false
end
Connection.disconnect = Connection.Disconnect

local Signal = {}
Signal.__index = Signal
Runtime.Signal = Signal

function Signal.new(name: string?)
	return setmetatable({ _conns = {}, _waiting = {}, _name = name or "Signal" }, Signal)
end

function Signal:Connect(fn)
	assert(type(fn) == "function", "Attempt to connect failed: Passed value is not a function")
	local conn = setmetatable({ Connected = true, _fn = fn }, Connection)
	table.insert(self._conns, conn)
	if self._onConnect then
		self._onConnect()
	end
	return conn
end
Signal.connect = Signal.Connect
Signal.ConnectParallel = Signal.Connect

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Wait()
	table.insert(self._waiting, coroutine.running())
	return coroutine.yield()
end
Signal.wait = Signal.Wait

function Signal:Fire(...)
	local conns = table.clone(self._conns)
	local live = {}
	for _, conn in self._conns do
		if conn.Connected then
			table.insert(live, conn)
		end
	end
	self._conns = live
	for _, conn in conns do
		if conn.Connected then
			spawnGuarded(`handler for {self._name}`, conn._fn, ...)
		end
	end
	local waiting = self._waiting
	self._waiting = {}
	for _, thread in waiting do
		task.spawn(thread, ...)
	end
end

function Signal:hasListeners()
	return #self._conns > 0 or #self._waiting > 0
end

-- ── Datatypes Lune doesn't provide ────────────────────────────────────────────
local TweenInfo = {}
TweenInfo.__index = TweenInfo
TweenInfo.__type = "TweenInfo"
function TweenInfo.new(time, style, direction, repeatCount, reverses, delayTime)
	return setmetatable({
		Time = time or 1,
		EasingStyle = style or Enum.EasingStyle.Quad,
		EasingDirection = direction or Enum.EasingDirection.Out,
		RepeatCount = repeatCount or 0,
		Reverses = reverses or false,
		DelayTime = delayTime or 0,
	}, TweenInfo)
end

local Random = {}
Random.__index = Random
Random.__type = "Random"
function Random.new(seed)
	local state = math.floor(seed or 1) % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return setmetatable({ _s = state }, Random)
end
function Random:_next()
	self._s = (self._s * 16807) % 2147483647
	return (self._s - 1) / 2147483646
end
function Random:NextNumber(min, max)
	min, max = min or 0, max or 1
	return min + (max - min) * self:_next()
end
function Random:NextInteger(min, max)
	return math.floor(min + (max - min + 1) * self:_next())
end
function Random:NextUnitVector()
	local v = Vector3.new(self:NextNumber(-1, 1), self:NextNumber(-1, 1), self:NextNumber(-1, 1))
	return v.Unit
end
function Random:Shuffle(list)
	for i = #list, 2, -1 do
		local j = self:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
end
function Random:Clone()
	return setmetatable({ _s = self._s }, Random)
end

local DateTime = {}
DateTime.__index = DateTime
DateTime.__type = "DateTime"
local function makeDateTime(millis)
	return setmetatable({ UnixTimestampMillis = millis, UnixTimestamp = millis // 1000 }, DateTime)
end
function DateTime.now()
	return makeDateTime(math.floor(os.time() * 1000))
end
function DateTime.fromUnixTimestamp(t)
	return makeDateTime(math.floor(t * 1000))
end
function DateTime.fromUnixTimestampMillis(t)
	return makeDateTime(t)
end
function DateTime:ToIsoDate()
	return os.date("!%Y-%m-%dT%H:%M:%SZ", self.UnixTimestamp)
end
function DateTime:ToUniversalTime()
	local t = os.date("!*t", self.UnixTimestamp)
	return { Year = t.year, Month = t.month, Day = t.day, Hour = t.hour, Minute = t.min, Second = t.sec, Millisecond = 0 }
end
DateTime.ToLocalTime = DateTime.ToUniversalTime
function DateTime:FormatLocalTime(format, _locale)
	local t = os.date("*t", self.UnixTimestamp)
	local map = {
		YYYY = string.format("%04d", t.year),
		MM = string.format("%02d", t.month),
		DD = string.format("%02d", t.day),
		HH = string.format("%02d", t.hour),
		mm = string.format("%02d", t.min),
		ss = string.format("%02d", t.sec),
	}
	return (string.gsub(format, "%a+", function(token)
		return map[token] or token
	end))
end
DateTime.FormatUniversalTime = DateTime.FormatLocalTime

Runtime.TweenInfo = TweenInfo
Runtime.Random = Random
Runtime.DateTime = DateTime

-- ── Class data from the reflection database ───────────────────────────────────
local classCache = {}

-- Engine defaults that Lune's database lacks or has stale.
local DEFAULT_OVERRIDES = {
	GuiObject = {
		AutomaticSize = Enum.AutomaticSize.None,
		SizeConstraint = Enum.SizeConstraint.RelativeXY,
		BorderMode = Enum.BorderMode.Outline,
		Interactable = true,
		Visible = true,
	},
	-- Layout enums have no defaults in Lune's database; these are Roblox's Instance.new values.
	UIListLayout = {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalPadding = roblox.UDim.new(0, 0),
		VerticalPadding = roblox.UDim.new(0, 0),
		Wraps = false,
	},
	UIGridLayout = {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	},
	UICorner = { CornerRadius = roblox.UDim.new(0, 8) },
	ImageLabel = { Image = "" },
	ImageButton = { Image = "" },
	LayerCollector = { ZIndexBehavior = Enum.ZIndexBehavior.Sibling },
	ScreenGui = { IgnoreGuiInset = false, Enabled = true, DisplayOrder = 0 },
	TextLabel = { Text = "Label", TextSize = 14 },
	TextButton = { Text = "Button", TextSize = 14 },
	TextBox = { Text = "TextBox", TextSize = 14 },
	UIStroke = { Enabled = true, Thickness = 1, Transparency = 0 },
	UIFlexItem = { FlexMode = Enum.UIFlexMode.None, GrowRatio = 1, ShrinkRatio = 1 },
	ScrollingFrame = { ScrollBarThickness = 12 },
	Camera = { FieldOfView = 70 },
	BasePart = { AssemblyLinearVelocity = roblox.Vector3.zero },
	Humanoid = {
		Health = 100,
		MaxHealth = 100,
		WalkSpeed = 16,
		MoveDirection = Vector3.zero,
		JumpPower = 50,
		JumpHeight = 7.2,
		HipHeight = 2,
		RigType = Enum.HumanoidRigType.R15,
		DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer,
	},
}

local function classInfo(className: string)
	local cached = classCache[className]
	if cached then
		return cached
	end
	local info = { name = className, chain = {}, props = {}, defaults = {} }
	local ok, class = pcall(function()
		return db:GetClass(className)
	end)
	local chain = {}
	while ok and class do
		table.insert(chain, class.Name)
		for name in class.Properties do
			info.props[name] = true
		end
		local parent = class.Superclass
		if not parent then
			break
		end
		ok, class = pcall(function()
			return db:GetClass(parent)
		end)
	end
	if #chain == 0 then
		chain = { className, "Instance" }
		info.unknown = true
	end
	info.chain = chain
	info.isa = {}
	for _, name in chain do
		info.isa[name] = true
	end
	local ok2, defaults = pcall(function()
		return db:GetClass(className).DefaultProperties
	end)
	if ok2 and defaults then
		for key, value in defaults do
			info.defaults[key] = value
		end
	end
	for i = #chain, 1, -1 do
		for key, value in DEFAULT_OVERRIDES[chain[i]] or {} do
			info.defaults[key] = value
			info.props[key] = true
		end
	end
	info.defaults.Name = className
	info.isGui = info.isa.GuiBase2d or info.isa.UIComponent or false
	classCache[className] = info
	return info
end
Runtime.classInfo = classInfo

-- ── Instances ─────────────────────────────────────────────────────────────────
local Instance = {}
local InstanceMT = {}
local methods = {} -- methods on every instance
local classMethods = {} -- className -> { name -> fn }
Runtime.classMethods = classMethods

local EVENT_NAMES = {}
for _, name in
	{
		"MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down",
		"MouseButton2Up", "MouseEnter", "MouseLeave", "MouseMoved", "MouseWheelForward", "MouseWheelBackward",
		"Activated", "InputBegan", "InputEnded", "InputChanged", "FocusLost", "Focused", "ReturnPressedFromOnScreenKeyboard",
		"Changed", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged",
		"Destroying", "AttributeChanged", "SelectionGained", "SelectionLost", "TouchTap", "TouchLongPress",
		"TouchPan", "TouchPinch", "TouchSwipe", "TouchRotate", "CharacterAdded", "CharacterRemoving",
		"CharacterAppearanceLoaded", "PlayerAdded", "PlayerRemoving", "Idled", "Chatted", "RenderStepped",
		"Heartbeat", "Stepped", "PreRender", "PreAnimation", "PreSimulation", "PostSimulation", "Completed",
		"Event", "OnClientEvent", "OnServerEvent", "Touched", "TouchEnded", "Died", "HealthChanged",
		"StateChanged", "Running", "Jumping", "MoveToFinished", "AnimationPlayed", "Played", "Ended",
		"Loaded", "DidLoop", "Stopped", "Paused", "Resumed", "KeyframeReached", "JumpRequest",
		"WindowFocused", "WindowFocusReleased", "LastInputTypeChanged", "TextBoxFocused", "TextBoxFocusReleased",
		"MenuOpened", "MenuClosed", "GamepadConnected", "GamepadDisconnected", "PageEnter", "PageLeave",
		"Stopped", "Triggered", "TriggerEnded", "PromptShown", "PromptHidden", "PromptButtonHoldBegan",
		"PromptButtonHoldEnded", "Close", "Move", "Button1Down", "Button1Up", "Button2Down", "Button2Up",
		"WheelForward", "WheelBackward", "Idle", "ServiceAdded", "ServiceRemoving", "OnTeleport",
		"PromptProductPurchaseFinished", "PromptGamePassPurchaseFinished", "PromptPurchaseFinished",
		"LocalToolEquipped", "Equipped", "Unequipped", "ProximityPromptTriggered", "ObjectFocused",
		"MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave", "PromptTriggered", "OnInvoke",
	}
do
	EVENT_NAMES[name] = true
end

local function isInstance(value)
	return type(value) == "table" and STATE[value] ~= nil
end
Runtime.isInstance = isInstance

local function markDirty()
	Runtime.dirty = true
end
Runtime.markDirty = markDirty

local function signalOf(inst, key: string)
	local s = STATE[inst]
	local sig = s.signals[key]
	if not sig then
		sig = Signal.new(`{s.props.Name or s.class}.{key}`)
		s.signals[key] = sig
	end
	return sig
end
Runtime.signalOf = signalOf

local function fireIf(inst, key: string, ...)
	local sig = STATE[inst].signals[key]
	if sig then
		sig:Fire(...)
	end
end
Runtime.fireIf = fireIf

local function propChanged(inst, key: string, value)
	local s = STATE[inst]
	local ps = s.propSignals[key]
	if ps then
		ps:Fire()
	end
	if s.signals.Changed then
		if s.info.isa.ValueBase then
			if key == "Value" then
				s.signals.Changed:Fire(value)
			end
		else
			s.signals.Changed:Fire(key)
		end
	end
end
Runtime.propChanged = propChanged

local instanceCount = 0

function Instance.new(className: string, parent)
	local info = classInfo(className)
	if info.unknown and not classMethods[className] then
		warnOnce(`class:{className}`, `Instance.new("{className}") — class not in the reflection DB, created as a bare instance`)
	end
	local inst = setmetatable({}, InstanceMT)
	instanceCount += 1
	STATE[inst] = {
		class = className,
		info = info,
		props = {},
		children = {},
		parent = nil,
		signals = {},
		propSignals = {},
		attributes = {},
		attrSignals = {},
		tags = {},
		id = instanceCount,
	}
	local init = classMethods[className] and classMethods[className].__init
	if init then
		init(inst)
	end
	if parent ~= nil then
		inst.Parent = parent
	end
	return inst
end

local function isDescendantOf(inst, ancestor)
	local p = STATE[inst].parent
	while p do
		if p == ancestor then
			return true
		end
		p = STATE[p].parent
	end
	return false
end

local function fireDescendant(ancestorStart, key: string, inst)
	local p = ancestorStart
	while p do
		fireIf(p, key, inst)
		p = STATE[p].parent
	end
end

local function eachDescendant(inst, fn)
	for _, child in STATE[inst].children do
		fn(child)
		eachDescendant(child, fn)
	end
end
Runtime.eachDescendant = eachDescendant

local function setParent(inst, newParent)
	local s = STATE[inst]
	if s.parent == newParent then
		return
	end
	if s.destroyed then
		error(`The Parent property of {s.props.Name or s.class} is locked, current parent: NULL, new parent {newParent and newParent.Name}`, 3)
	end
	if newParent ~= nil and not isInstance(newParent) then
		error(`Parent must be an Instance, got {typeof(newParent)}`, 3)
	end
	if newParent == inst or (newParent and isDescendantOf(newParent, inst)) then
		error("Attempt to set parent of an instance to itself or a descendant", 3)
	end
	local old = s.parent
	if old then
		local list = STATE[old].children
		local index = table.find(list, inst)
		if index then
			table.remove(list, index)
		end
		fireIf(old, "ChildRemoved", inst)
		fireDescendant(old, "DescendantRemoving", inst)
	end
	s.parent = newParent
	if newParent then
		table.insert(STATE[newParent].children, inst)
		fireIf(newParent, "ChildAdded", inst)
		fireDescendant(newParent, "DescendantAdded", inst)
	end
	fireIf(inst, "AncestryChanged", inst, newParent)
	eachDescendant(inst, function(d)
		fireIf(d, "AncestryChanged", inst, newParent)
	end)
	propChanged(inst, "Parent", newParent)
	markDirty()
end

local ABSOLUTE = {
	AbsoluteSize = true,
	AbsolutePosition = true,
	AbsoluteRotation = true,
	AbsoluteContentSize = true,
	AbsoluteCanvasSize = true,
	AbsoluteWindowSize = true,
	TextBounds = true,
	TextFits = true,
	ContentText = true,
	AbsoluteCellSize = true,
	AbsoluteCellCount = true,
}

local function findMethod(info, key)
	for _, className in info.chain do
		local m = classMethods[className]
		if m and m[key] then
			return m[key]
		end
	end
	return methods[key]
end

InstanceMT.__index = function(inst, key)
	local s = STATE[inst]
	if key == "ClassName" then
		return s.class
	elseif key == "Parent" then
		return s.parent
	end
	local m = findMethod(s.info, key)
	if m then
		return m
	end
	local value = s.props[key]
	if value ~= nil then
		return value
	end
	if ABSOLUTE[key] and s.info.isGui then
		return Runtime.layout.read(inst, key)
	end
	local info = s.info
	if info.props[key] then
		local getter = classMethods.__getters[key]
		if getter then
			local v = getter(inst)
			if v ~= nil then
				return v
			end
		end
		local default = info.defaults[key]
		if default ~= nil then
			return default
		end
	end
	for _, child in s.children do
		if STATE[child].props.Name == key or (STATE[child].props.Name == nil and STATE[child].class == key) then
			return child
		end
	end
	if info.props[key] then
		return nil -- an unset reference property (PrimaryPart, NextSelectionUp, ...)
	end
	if EVENT_NAMES[key] then
		return signalOf(inst, key)
	end
	if info.defaults[key] ~= nil then
		return info.defaults[key]
	end
	local getter = classMethods.__getters[key]
	if getter then
		return getter(inst)
	end
	if not info.isGui and s.class ~= "DataModel" and not s.strict then
		-- Non-GUI members are mostly world objects the place file would provide; be lenient.
		warnOnce(`member:{s.class}.{key}`, `{s.class}.{key} is not emulated (read returned nil)`)
		return nil
	end
	error(`{key} is not a valid member of {s.class} "{methods.GetFullName(inst)}"`, 2)
end

local SETTER_ALIASES = {
	TextWrap = "TextWrapped",
}

InstanceMT.__newindex = function(inst, key, value)
	local s = STATE[inst]
	if key == "Parent" then
		setParent(inst, value)
		return
	elseif key == "ClassName" then
		error("ClassName is read-only", 2)
	elseif ABSOLUTE[key] and s.info.isGui then
		error(`Unable to assign property {key}. Property is read only`, 2)
	end
	key = SETTER_ALIASES[key] or key
	local setter = classMethods.__setters[key]
	if setter and setter(inst, value) then
		return
	end
	if not s.info.props[key] and not s.info.unknown and s.info.isGui and s.info.defaults[key] == nil then
		warnOnce(`set:{s.class}.{key}`, `set {s.class}.{key} — not a known property (stored anyway)`)
	end
	local old = s.props[key]
	if old == nil then
		old = s.info.defaults[key]
	end
	s.props[key] = value
	if old ~= value then
		if s.info.isGui then
			markDirty()
		end
		propChanged(inst, key, value)
	end
end

InstanceMT.__tostring = function(inst)
	local s = STATE[inst]
	return s.props.Name or s.class
end

-- ── Instance methods ──────────────────────────────────────────────────────────
local function nameOf(inst)
	local s = STATE[inst]
	return s.props.Name or s.class
end
Runtime.nameOf = nameOf

function methods.GetFullName(inst)
	local parts = {}
	local cur = inst
	while cur and STATE[cur].class ~= "DataModel" do
		table.insert(parts, 1, nameOf(cur))
		cur = STATE[cur].parent
	end
	return table.concat(parts, ".")
end

function methods.GetChildren(inst)
	return table.clone(STATE[inst].children)
end

function methods.GetDescendants(inst)
	local out = {}
	eachDescendant(inst, function(d)
		table.insert(out, d)
	end)
	return out
end

function methods.FindFirstChild(inst, name, recursive)
	for _, child in STATE[inst].children do
		if nameOf(child) == name then
			return child
		end
	end
	if recursive then
		for _, child in STATE[inst].children do
			local found = methods.FindFirstChild(child, name, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function methods.FindFirstDescendant(inst, name)
	return methods.FindFirstChild(inst, name, true)
end

function methods.FindFirstChildOfClass(inst, className)
	for _, child in STATE[inst].children do
		if STATE[child].class == className then
			return child
		end
	end
	return nil
end

function methods.FindFirstChildWhichIsA(inst, className, recursive)
	for _, child in STATE[inst].children do
		if STATE[child].info.isa[className] then
			return child
		end
	end
	if recursive then
		for _, child in STATE[inst].children do
			local found = methods.FindFirstChildWhichIsA(child, className, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function methods.FindFirstAncestor(inst, name)
	local p = STATE[inst].parent
	while p do
		if nameOf(p) == name then
			return p
		end
		p = STATE[p].parent
	end
	return nil
end

function methods.FindFirstAncestorOfClass(inst, className)
	local p = STATE[inst].parent
	while p do
		if STATE[p].class == className then
			return p
		end
		p = STATE[p].parent
	end
	return nil
end

function methods.FindFirstAncestorWhichIsA(inst, className)
	local p = STATE[inst].parent
	while p do
		if STATE[p].info.isa[className] then
			return p
		end
		p = STATE[p].parent
	end
	return nil
end

Runtime.waitForChildTimeout = 0.2
Runtime.pendingWaits = 0
Runtime.pendingDelays = 0 -- short task.delay timers still pending -- threads currently parked in WaitForChild (ui.boot waits for this to reach 0)

function methods.WaitForChild(inst, name, timeout)
	local found = methods.FindFirstChild(inst, name)
	if found then
		return found
	end
	local deadline = os.clock() + math.min(timeout or math.huge, Runtime.waitForChildTimeout)
	Runtime.pendingWaits += 1
	while os.clock() < deadline do
		task.wait(0.02)
		found = methods.FindFirstChild(inst, name)
		if found then
			Runtime.pendingWaits -= 1
			return found
		end
	end
	Runtime.pendingWaits -= 1
	if timeout then
		return nil
	end
	-- Roblox would yield forever here. Hand back a stand-in so the rest of the UI still builds.
	local path = methods.GetFullName(inst)
	warnOnce(`wait:{path}.{name}`, `WaitForChild("{name}") on {path} never resolved — created an empty Folder stand-in`)
	local stub = Instance.new("Folder")
	stub.Name = name
	STATE[stub].stub = true
	stub.Parent = inst
	return stub
end

function methods.IsA(inst, className)
	return STATE[inst].info.isa[className] == true
end

function methods.IsDescendantOf(inst, ancestor)
	return isDescendantOf(inst, ancestor)
end

function methods.IsAncestorOf(inst, descendant)
	return isDescendantOf(descendant, inst)
end

function methods.Destroy(inst)
	local s = STATE[inst]
	if s.destroyed then
		return
	end
	fireIf(inst, "Destroying")
	for _, child in table.clone(s.children) do
		methods.Destroy(child)
	end
	if s.parent then
		setParent(inst, nil)
	end
	s.destroyed = true
	for _, sig in s.signals do
		sig._conns = {}
	end
	for _, sig in s.propSignals do
		sig._conns = {}
	end
	markDirty()
end
methods.Remove = function(inst)
	inst.Parent = nil
end

function methods.ClearAllChildren(inst)
	for _, child in table.clone(STATE[inst].children) do
		methods.Destroy(child)
	end
end

function methods.Clone(inst)
	local s = STATE[inst]
	if s.props.Archivable == false then
		return nil
	end
	local copy = Instance.new(s.class)
	local cs = STATE[copy]
	for key, value in s.props do
		cs.props[key] = value
	end
	for key, value in s.attributes do
		cs.attributes[key] = value
	end
	for key in s.tags do
		cs.tags[key] = true
	end
	cs.source = s.source
	cs.sourcePath = s.sourcePath
	for _, child in s.children do
		local c = methods.Clone(child)
		if c then
			c.Parent = copy
		end
	end
	return copy
end

function methods.GetAttribute(inst, key)
	return STATE[inst].attributes[key]
end

function methods.GetAttributes(inst)
	return table.clone(STATE[inst].attributes)
end

function methods.SetAttribute(inst, key, value)
	local s = STATE[inst]
	if s.attributes[key] == value then
		return
	end
	s.attributes[key] = value
	fireIf(inst, "AttributeChanged", key)
	local sig = s.attrSignals[key]
	if sig then
		sig:Fire()
	end
end

function methods.GetAttributeChangedSignal(inst, key)
	local s = STATE[inst]
	s.attrSignals[key] = s.attrSignals[key] or Signal.new(`AttributeChanged:{key}`)
	return s.attrSignals[key]
end

Runtime.absWatchers = setmetatable({}, { __mode = "k" })

function methods.GetPropertyChangedSignal(inst, key)
	local s = STATE[inst]
	if ABSOLUTE[key] then
		Runtime.absWatchers[inst] = true
	end
	s.propSignals[key] = s.propSignals[key] or Signal.new(`{nameOf(inst)}:{key}Changed`)
	return s.propSignals[key]
end

function methods.GetDebugId(inst)
	return tostring(STATE[inst].id)
end

function methods.AddTag(inst, tag)
	STATE[inst].tags[tag] = true
end
function methods.RemoveTag(inst, tag)
	STATE[inst].tags[tag] = nil
end
function methods.HasTag(inst, tag)
	return STATE[inst].tags[tag] == true
end
function methods.GetTags(inst)
	local out = {}
	for tag in STATE[inst].tags do
		table.insert(out, tag)
	end
	return out
end
function methods.GetActor()
	return nil
end
function methods.GetStyled(inst, key)
	return inst[key]
end
function methods.IsPropertyModified(inst, key)
	return STATE[inst].props[key] ~= nil
end
function methods.ResetPropertyToDefault(inst, key)
	STATE[inst].props[key] = nil
	markDirty()
end

-- ── Getters / setters that need more than storage ─────────────────────────────
classMethods.__getters = {}
classMethods.__setters = {}

classMethods.__setters.Font = function(inst, value)
	local s = STATE[inst]
	if not s.info.props.FontFace then
		return false
	end
	s.props.Font = value
	inst.FontFace = Font.fromEnum(value)
	return true
end

classMethods.__getters.Name = function(inst)
	return STATE[inst].class
end

-- ── Class-specific behaviour ──────────────────────────────────────────────────
local function define(className, tbl)
	classMethods[className] = classMethods[className] or {}
	for key, value in tbl do
		classMethods[className][key] = value
	end
end
Runtime.define = define

local function noop() end

define("GuiObject", {
	TweenPosition = function(inst, position, _dir, _style, _time, _override, callback)
		inst.Position = position
		if callback then
			task.spawn(callback, Enum.TweenStatus.Completed)
		end
		return true
	end,
	TweenSize = function(inst, size, _dir, _style, _time, _override, callback)
		inst.Size = size
		if callback then
			task.spawn(callback, Enum.TweenStatus.Completed)
		end
		return true
	end,
	TweenSizeAndPosition = function(inst, size, position, _dir, _style, _time, _override, callback)
		inst.Size = size
		inst.Position = position
		if callback then
			task.spawn(callback, Enum.TweenStatus.Completed)
		end
		return true
	end,
})

define("TextBox", {
	CaptureFocus = function(inst)
		STATE[inst].focused = true
		fireIf(inst, "Focused")
	end,
	ReleaseFocus = function(inst, submitted)
		STATE[inst].focused = false
		fireIf(inst, "FocusLost", submitted == true, nil)
	end,
	IsFocused = function(inst)
		return STATE[inst].focused == true
	end,
})

define("UIPageLayout", {
	JumpTo = function(inst, page)
		STATE[inst].currentPage = page
		markDirty()
	end,
	JumpToIndex = function(inst, index)
		STATE[inst].currentIndex = index
		markDirty()
	end,
	Next = noop,
	Previous = noop,
})

define("BindableEvent", {
	Fire = function(inst, ...)
		signalOf(inst, "Event"):Fire(...)
	end,
})
define("BindableFunction", {
	Invoke = function(inst, ...)
		local cb = STATE[inst].props.OnInvoke
		if cb then
			return cb(...)
		end
		return nil
	end,
})
classMethods.__setters.OnInvoke = function(inst, value)
	STATE[inst].props.OnInvoke = value
	return true
end
-- Remotes loop back through the same instance: the client's FireServer reaches the loopback
-- server's (or a scenario's ui.remote) OnServerEvent, and FireClient / FireAllClients reach
-- OnClientEvent. Like Roblox, events sent before anyone listens wait for the first handler.
local function remoteSignal(inst, key: string)
	local sig = signalOf(inst, key)
	if not sig._queue then
		sig._queue = {}
		sig._onConnect = function()
			local queued = sig._queue
			sig._queue = {}
			for _, args in queued do
				sig:Fire(table.unpack(args, 1, args.n))
			end
		end
	end
	return sig
end

local function deliverRemote(inst, key: string, call: string, ...)
	table.insert(Runtime.log, `{STATE[inst].class} {methods.GetFullName(inst)}:{call}`)
	local sig = remoteSignal(inst, key)
	if sig:hasListeners() then
		sig:Fire(...)
	else
		table.insert(sig._queue, table.pack(...))
	end
end

local remoteEventMethods = {
	FireServer = function(inst, ...)
		deliverRemote(inst, "OnServerEvent", "FireServer", Runtime.player, ...)
	end,
	FireClient = function(inst, _player, ...)
		deliverRemote(inst, "OnClientEvent", "FireClient", ...)
	end,
	FireAllClients = function(inst, ...)
		deliverRemote(inst, "OnClientEvent", "FireAllClients", ...)
	end,
}
define("RemoteEvent", remoteEventMethods)
define("UnreliableRemoteEvent", remoteEventMethods)
define("RemoteFunction", {
	InvokeServer = function(inst, ...)
		table.insert(Runtime.log, `RemoteFunction {methods.GetFullName(inst)}:InvokeServer`)
		local cb = STATE[inst].props.OnServerInvoke
		if cb then
			return cb(Runtime.player, ...)
		end
		warnOnce(`invoke:{methods.GetFullName(inst)}`, `{methods.GetFullName(inst)}:InvokeServer() has no OnServerInvoke (boot with server = true, or answer it with ui.remote) — returned nil`)
		return nil
	end,
	InvokeClient = function(inst, _player, ...)
		local cb = STATE[inst].props.OnClientInvoke
		if cb then
			return cb(...)
		end
		return nil
	end,
})
for _, key in { "OnServerInvoke", "OnClientInvoke" } do
	classMethods.__setters[key] = classMethods.__setters[key]
		or function(inst, value)
			STATE[inst].props[key] = value
			return true
		end
end

define("Sound", {
	Play = function(inst)
		STATE[inst].props.IsPlaying = true
		fireIf(inst, "Played", inst.SoundId)
	end,
	Stop = function(inst)
		STATE[inst].props.IsPlaying = false
	end,
	Pause = function(inst)
		STATE[inst].props.IsPlaying = false
	end,
	Resume = function(inst)
		STATE[inst].props.IsPlaying = true
	end,
})

local function animationTrack(animation)
	local track = {
		Animation = animation,
		IsPlaying = false,
		Length = 1,
		Speed = 1,
		TimePosition = 0,
		WeightCurrent = 1,
		WeightTarget = 1,
		Looped = false,
		Priority = Enum.AnimationPriority.Core,
		Stopped = Signal.new("Stopped"),
		Ended = Signal.new("Ended"),
		DidLoop = Signal.new("DidLoop"),
		KeyframeReached = Signal.new("KeyframeReached"),
	}
	function track:Play()
		self.IsPlaying = true
	end
	function track:Stop()
		self.IsPlaying = false
	end
	function track:AdjustSpeed(speed)
		self.Speed = speed
	end
	function track:AdjustWeight(w)
		self.WeightCurrent = w
	end
	function track:GetMarkerReachedSignal()
		return Signal.new("MarkerReached")
	end
	function track:GetTimeOfKeyframe()
		return 0
	end
	function track:Destroy() end
	return track
end
define("Animator", {
	LoadAnimation = function(_, animation)
		return animationTrack(animation)
	end,
	GetPlayingAnimationTracks = function()
		return {}
	end,
})
define("Humanoid", {
	LoadAnimation = function(_, animation)
		return animationTrack(animation)
	end,
	GetPlayingAnimationTracks = function()
		return {}
	end,
	GetState = function()
		return Enum.HumanoidStateType.Running
	end,
	ChangeState = noop,
	SetStateEnabled = noop,
	MoveTo = noop,
	Move = noop,
	TakeDamage = noop,
	UnequipTools = noop,
	EquipTool = noop,
	ApplyDescription = noop,
	ApplyDescriptionReset = noop,
	GetAppliedDescription = function()
		return Instance.new("HumanoidDescription")
	end,
	BuildRigFromAttachments = noop,
})

local function pivotOf(inst)
	local s = STATE[inst]
	if s.info.isa.BasePart then
		return inst.CFrame or CFrame.new()
	end
	local primary = s.props.PrimaryPart
	if primary then
		return primary.CFrame
	end
	return s.props.WorldPivot or CFrame.new()
end
define("PVInstance", {
	GetPivot = pivotOf,
	PivotTo = function(inst, cf)
		local s = STATE[inst]
		if s.info.isa.BasePart then
			inst.CFrame = cf
		else
			-- move every part rigidly with the pivot, like Roblox
			local old = pivotOf(inst)
			local delta = cf * old:Inverse()
			for _, d in methods.GetDescendants(inst) do
				if STATE[d] and STATE[d].info.isa.BasePart then
					d.CFrame = delta * (d.CFrame or CFrame.new())
				end
			end
			if not s.props.PrimaryPart then
				s.props.WorldPivot = cf
			end
		end
	end,
})
define("Model", {
	GetBoundingBox = function(inst)
		return pivotOf(inst), Vector3.new(4, 5, 2)
	end,
	GetExtentsSize = function()
		return Vector3.new(4, 5, 2)
	end,
	SetPrimaryPartCFrame = function(inst, cf)
		STATE[inst].props.WorldPivot = cf
	end,
	GetPrimaryPartCFrame = pivotOf,
	MoveTo = noop,
	TranslateBy = noop,
	ScaleTo = noop,
	GetScale = function()
		return 1
	end,
})
define("BasePart", {
	GetMass = function()
		return 1
	end,
	SetNetworkOwner = noop,
	ApplyImpulse = noop,
	GetTouchingParts = function()
		return {}
	end,
	GetConnectedParts = function()
		return {}
	end,
	CanSetNetworkOwnership = function()
		return false
	end,
})
classMethods.__setters.Position = function(inst, value)
	if STATE[inst].info.isa.BasePart and typeof(value) == "Vector3" then
		local cf = inst.CFrame or CFrame.new()
		inst.CFrame = cf - cf.Position + value
		return true
	end
	return false
end
classMethods.__getters.Position = function(inst)
	if STATE[inst].info.isa.BasePart then
		local cf = STATE[inst].props.CFrame
		return cf and cf.Position or Vector3.zero
	end
	return nil
end

-- ── Loading source code ───────────────────────────────────────────────────────
-- Scripts run in a "client" or "server" context. Each context has its own module cache and
-- environment (as separate Roblox peers would); env.__context tells RunService who is asking.
local moduleCache = { client = {}, server = {} }
local moduleLoading = { client = {}, server = {} }
local envs = {}
local requireOverrides = {} -- full name -> value

function Runtime.setEnvironment(context: string, env)
	envs[context] = env
end

function Runtime.overrideModule(fullName: string, value)
	requireOverrides[fullName] = value
end

-- The context of the game code `depth` frames above the function calling this.
function Runtime.callerContext(depth: number): string
	local ok, env = pcall(getfenv, depth + 3) -- +1 for this function, +1 for pcall, +1 for the asker
	if ok and type(env) == "table" then
		return rawget(env, "__context") or "client"
	end
	return "client"
end

-- Lune copies the environment's fields rather than honouring __index, so each script gets a copy.
local function scriptEnv(scriptInst, context: string)
	local env = table.clone(envs[context])
	env.script = scriptInst
	return env
end

local function compile(scriptInst, context: string)
	local s = STATE[scriptInst]
	local source = s.props.Source or s.source or ""
	local debugName = s.sourcePath or methods.GetFullName(scriptInst)
	return luau.load(source, {
		debugName = debugName,
		environment = scriptEnv(scriptInst, context),
		injectGlobals = true,
	})
end

local function requireModule(target, context: string?)
	context = context or "client"
	if type(target) == "number" then
		error(`require({target}) — asset-id modules can't be loaded offline`, 2)
	end
	assert(isInstance(target), `Attempted to call require with invalid argument(s).`)
	local key = methods.GetFullName(target)
	local override = requireOverrides[key]
	if override ~= nil then
		return override
	end
	local cache = moduleCache[context]
	if cache[target] ~= nil then
		return cache[target]
	end
	if STATE[target].class ~= "ModuleScript" then
		error(`Attempted to call require with a {STATE[target].class} ({key})`, 2)
	end
	if moduleLoading[context][target] then
		error(`Requested module was required recursively: {key}`, 2)
	end
	moduleLoading[context][target] = true
	local chunk = compile(target, context)
	local ok, result = xpcall(chunk, function(e)
		return { e = e, trace = debug.traceback(nil, 2) }
	end)
	moduleLoading[context][target] = nil
	if not ok then
		reportError(`require {key}{context == "server" and " (server)" or ""}`, result.e, result.trace)
		error(`Requested module experienced an error while loading: {key}`, 0)
	end
	if result == nil then
		error(`Module code did not return exactly one value: {key}`, 2)
	end
	cache[target] = result
	return result
end
Runtime.require = requireModule

function Runtime.runScript(scriptInst, context: string?)
	context = context or "client"
	local key = methods.GetFullName(scriptInst)
	local ok, chunk = pcall(compile, scriptInst, context)
	if not ok then
		reportError(`compile {key}`, chunk)
		return
	end
	spawnGuarded(key, chunk)
end

-- ── Rojo project mounting ─────────────────────────────────────────────────────
local function applyProperties(inst, properties)
	for key, value in properties or {} do
		local ok, err = pcall(function()
			if type(value) == "table" then
				local info = STATE[inst].info
				local default = info.defaults[key]
				local kind = default ~= nil and typeof(default) or nil
				if kind == "Color3" and #value == 3 then
					value = Color3.new(value[1], value[2], value[3])
				elseif kind == "Vector3" and #value == 3 then
					value = Vector3.new(value[1], value[2], value[3])
				elseif kind == "Vector2" and #value == 2 then
					value = Vector2.new(value[1], value[2])
				elseif kind == "EnumItem" and value.Enum then
					value = (Enum :: any)[tostring(default.EnumType):gsub("^Enum%.", "")][value.Enum]
				else
					return
				end
			elseif type(value) == "string" then
				local default = STATE[inst].info.defaults[key]
				if typeof(default) == "EnumItem" then
					value = (Enum :: any)[tostring(default.EnumType):gsub("^Enum%.", "")][value]
				end
			end
			inst[key] = value
		end)
		if not ok then
			warnOnce(`prop:{key}`, `couldn't apply project property {key}: {err}`)
		end
	end
end

-- Converts a Lune roblox.Instance (from an .rbxm/.rbxmx) into a runtime instance.
-- World objects only need a few properties for UI code; GUI objects get all of them.
local WORLD_PROPS = { "CFrame", "Size", "Color", "Transparency", "Anchored", "CanCollide", "Value", "Enabled", "Disabled", "RunContext", "AnimationId", "SoundId", "Texture", "TextureID", "MeshId", "RigType", "WorldPivot" }

local function convertLune(luneInst)
	local className = luneInst.ClassName
	local inst = Instance.new(className)
	local s = STATE[inst]
	local names = s.info.isGui and s.info.props or nil
	local function copy(name)
		local ok, value = pcall(function()
			return luneInst[name]
		end)
		if ok and value ~= nil and typeof(value) ~= "Instance" and value ~= s.info.defaults[name] then
			s.props[name] = value
		end
	end
	if names then
		for name in names do
			copy(name)
		end
	else
		for _, name in WORLD_PROPS do
			if s.info.props[name] then
				copy(name)
			end
		end
	end
	s.props.Name = luneInst.Name
	if className == "ModuleScript" or className == "LocalScript" or className == "Script" then
		s.source = luneInst.Source
		s.sourcePath = `(place) {luneInst:GetFullName()}`
	end
	local okAttr, attrs = pcall(function()
		return luneInst:GetAttributes()
	end)
	if okAttr then
		for k, v in attrs do
			s.attributes[k] = v
		end
	end
	local okTags, tags = pcall(function()
		return luneInst:GetTags()
	end)
	if okTags then
		for _, tag in tags do
			s.tags[tag] = true
		end
	end
	for _, child in luneInst:GetChildren() do
		convertLune(child).Parent = inst
	end
	-- Object references (PrimaryPart, etc.) are dropped; menus rarely rely on them.
	return inst
end
Runtime.convertLune = convertLune

local function scriptClassFor(fileName: string)
	if string.match(fileName, "%.server%.luau?$") then
		return "Script", string.gsub(fileName, "%.server%.luau?$", "")
	elseif string.match(fileName, "%.client%.luau?$") then
		return "LocalScript", string.gsub(fileName, "%.client%.luau?$", "")
	elseif string.match(fileName, "%.luau?$") then
		return "ModuleScript", string.gsub(fileName, "%.luau?$", "")
	end
	return nil
end

local mountPath

local function readMeta(path: string)
	if fs.isFile(path) then
		local ok, data = pcall(serde.decode, "json", fs.readFile(path))
		if ok then
			return data
		end
	end
	return nil
end

-- Mounts a file or directory the way Rojo would and returns the instance (or nil to skip).
function mountPath(path: string, name: string?, classOverride: string?)
	if fs.isDir(path) then
		local initFile, initClass
		for _, candidate in { "init.luau", "init.lua", "init.client.luau", "init.client.lua", "init.server.luau", "init.server.lua" } do
			if fs.isFile(`{path}/{candidate}`) then
				initFile = candidate
				initClass = scriptClassFor(candidate)
				break
			end
		end
		local meta = readMeta(`{path}/init.meta.json`)
		local folderName = name or string.match(path, "([^/\\]+)$")
		local inst = Instance.new(classOverride or initClass or (meta and meta.className) or "Folder")
		inst.Name = folderName
		if initFile then
			STATE[inst].source = fs.readFile(`{path}/{initFile}`)
			STATE[inst].sourcePath = `{path}/{initFile}`
		end
		if meta then
			applyProperties(inst, meta.properties)
		end
		local entries = fs.readDir(path)
		table.sort(entries)
		for _, entry in entries do
			if string.match(entry, "^init%.") then
				continue
			end
			local child = mountPath(`{path}/{entry}`)
			if child then
				child.Parent = inst
			end
		end
		return inst
	end
	local fileName = string.match(path, "([^/\\]+)$")
	local className, baseName = scriptClassFor(fileName)
	if className then
		local inst = Instance.new(classOverride or className)
		inst.Name = name or baseName
		STATE[inst].source = fs.readFile(path)
		STATE[inst].sourcePath = path
		local meta = readMeta(string.gsub(path, "%.[%w%.]+$", "") .. ".meta.json")
		if meta then
			applyProperties(inst, meta.properties)
		end
		return inst
	elseif string.match(fileName, "%.rbxmx?$") then
		local ok, result = pcall(function()
			return roblox.deserializeModel(fs.readFile(path))
		end)
		if not ok then
			warnOnce(`rbxm:{path}`, `couldn't read {path}: {result}`)
			return nil
		end
		if #result == 1 then
			local inst = convertLune(result[1])
			inst.Name = name or string.gsub(fileName, "%.rbxmx?$", "")
			return inst
		end
		local folder = Instance.new("Folder")
		folder.Name = name or string.gsub(fileName, "%.rbxmx?$", "")
		for _, item in result do
			convertLune(item).Parent = folder
		end
		return folder
	elseif string.match(fileName, "%.txt$") then
		local inst = Instance.new("StringValue")
		inst.Name = name or string.gsub(fileName, "%.txt$", "")
		inst.Value = fs.readFile(path)
		return inst
	elseif string.match(fileName, "%.json$") and not string.match(fileName, "%.meta%.json$") and not string.match(fileName, "%.project%.json$") then
		if string.match(fileName, "%.model%.json$") then
			warnOnce(`modeljson:{path}`, `.model.json files are not mounted yet ({path})`)
			return nil
		end
		local inst = Instance.new("ModuleScript")
		inst.Name = name or string.gsub(fileName, "%.json$", "")
		STATE[inst].source = "return game:GetService('HttpService'):JSONDecode([==[" .. fs.readFile(path) .. "]==])"
		STATE[inst].sourcePath = path
		return inst
	end
	return nil
end

-- Rojo infers these classes from the node name when $className is left out.
local INFERRED_CLASSES = { StarterPlayerScripts = true, StarterCharacterScripts = true }

local function mountNode(node, name: string, parent, projectDir: string)
	local inst
	local inferred = node["$className"]
	if not inferred and parent and (STATE[parent].class == "DataModel" or INFERRED_CLASSES[name]) then
		inferred = name
	end
	if node["$path"] then
		local path = `{projectDir}/{node["$path"]}`
		if fs.isDir(path) or fs.isFile(path) then
			inst = mountPath(path, name, if fs.isDir(path) then inferred else node["$className"])
		end
	end
	if not inst then
		local className = inferred or "Folder"
		if parent and STATE[parent].class == "DataModel" then
			inst = Runtime.service(className)
		else
			inst = Instance.new(className)
			inst.Name = name
		end
	elseif parent and STATE[parent].class == "DataModel" then
		-- Merge the mounted folder into the real service.
		local service = Runtime.service(node["$className"] or name)
		for _, child in inst:GetChildren() do
			child.Parent = service
		end
		inst = service
	end
	applyProperties(inst, node["$properties"])
	if parent and inst.Parent ~= parent and STATE[parent].class ~= "DataModel" then
		-- Merge into a container the world already made (e.g. StarterPlayerScripts).
		local existing = methods.FindFirstChild(parent, name)
		if existing and STATE[existing].class == STATE[inst].class and not STATE[inst].source then
			for _, child in methods.GetChildren(inst) do
				child.Parent = existing
			end
			inst = existing
		else
			inst.Parent = parent
		end
	end
	for key, child in node do
		if string.sub(key, 1, 1) ~= "$" and type(child) == "table" then
			mountNode(child, key, inst, projectDir)
		end
	end
	return inst
end

-- Merges a saved place (.rbxl/.rbxlx) underneath the Rojo tree, like `rojo serve` into that place:
-- anything Rojo provides wins; place-only instances (maps, Studio-built UI, assets) are added.
local PLACE_SERVICES = {
	"Workspace", "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPlayer", "StarterPack",
	"Lighting", "SoundService", "ServerStorage", "ServerScriptService", "Teams", "MaterialService",
}

function Runtime.mountPlaceFile(path: string)
	local place = roblox.deserializePlace(fs.readFile(path))
	local added = 0
	local function merge(luneParent, target)
		for _, child in luneParent:GetChildren() do
			local class = child.ClassName
			if class == "Camera" or class == "Terrain" then
				continue
			end
			local existing = methods.FindFirstChild(target, child.Name)
			if existing then
				if STATE[existing].class == class and not STATE[existing].source then
					merge(child, existing)
				end
			else
				convertLune(child).Parent = target
				added += 1
			end
		end
	end
	for _, serviceName in PLACE_SERVICES do
		local service = place:FindFirstChildOfClass(serviceName)
		if service then
			merge(service, Runtime.service(serviceName))
		end
	end
	return added
end

function Runtime.mountProject(projectDir: string)
	local project = serde.decode("json", fs.readFile(`{projectDir}/default.project.json`))
	mountNode(project.tree, "game", Runtime.game, projectDir)
end

Runtime.Instance = Instance
Runtime.methods = methods
return Runtime
