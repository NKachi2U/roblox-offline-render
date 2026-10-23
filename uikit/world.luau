--[[
	Builds the fake client world: the DataModel and its services, the local player, the Red
	networking stub, and the global environment every script and module runs in.
]]

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Runtime = require("./runtime")
local Clock = require("./clock")

local Enum = roblox.Enum
local Vector2 = roblox.Vector2
local Vector3 = roblox.Vector3
-- Lune's CFrame.lookAt / CFrame.new(pos, lookAt) face the opposite way to Roblox's
-- (LookVector points away from the target). Game code gets a CFrame table with
-- those two rebuilt from fromMatrix; everything else is Lune's.
local CFrame
do
	local base = roblox.CFrame
	local UP = roblox.Vector3.new(0, 1, 0)
	local function lookAt(at, target, up)
		local look = target - at
		if look.Magnitude < 1e-9 then
			return base.new(at)
		end
		look = look.Unit
		up = up or UP
		local right = look:Cross(up)
		if right.Magnitude < 1e-6 then
			-- looking straight up/down: pick any perpendicular
			right = look:Cross(roblox.Vector3.new(0, 0, 1))
		end
		right = right.Unit
		return base.fromMatrix(at, right, right:Cross(look), -look)
	end
	CFrame = setmetatable({
		lookAt = lookAt,
		new = function(...)
			local a, b = ...
			if select("#", ...) == 2 and typeof(a) == "Vector3" and typeof(b) == "Vector3" then
				return lookAt(a, b)
			end
			return base.new(...)
		end,
	}, { __index = base })
end

local Instance = Runtime.Instance
local STATE = Runtime.STATE
local Signal = Runtime.Signal
local define = Runtime.define
local signalOf = Runtime.signalOf

local World = {}

local function noop() end
local function returns(value)
	return function()
		return value
	end
end

-- Stores a value without firing change events or warnings (used for engine-owned state).
local function raw(inst, key, value)
	STATE[inst].props[key] = value
end

-- ── Services ──────────────────────────────────────────────────────────────────
define("DataModel", {
	GetService = function(game, className)
		return Runtime.service(className)
	end,
	FindService = function(game, className)
		return game:FindFirstChildOfClass(className)
	end,
	IsLoaded = returns(true),
	BindToClose = noop,
	GetJobsInfo = returns({}),
})
define("ServiceProvider", {})

define("Workspace", {
	Raycast = returns(nil),
	Blockcast = returns(nil),
	Spherecast = returns(nil),
	Shapecast = returns(nil),
	GetPartBoundsInBox = returns({}),
	GetPartBoundsInRadius = returns({}),
	GetPartsInPart = returns({}),
	FindPartOnRay = returns(nil),
	FindPartOnRayWithIgnoreList = returns(nil),
	FindPartOnRayWithWhitelist = returns(nil),
	GetServerTimeNow = function()
		return os.time()
	end,
	GetRealPhysicsFPS = returns(60),
})

define("Camera", {
	WorldToViewportPoint = function()
		return Vector3.new(Runtime.viewport.X / 2, Runtime.viewport.Y / 2, 10), true
	end,
	WorldToScreenPoint = function()
		return Vector3.new(Runtime.viewport.X / 2, Runtime.viewport.Y / 2 - Runtime.topInset, 10), true
	end,
	ViewportPointToRay = function()
		return roblox.Ray.new(Vector3.zero, Vector3.new(0, 0, -1))
	end,
	ScreenPointToRay = function()
		return roblox.Ray.new(Vector3.zero, Vector3.new(0, 0, -1))
	end,
	GetPartsObscuringTarget = returns({}),
	Interpolate = noop,
	GetRenderCFrame = function(cam)
		return cam.CFrame
	end,
})
Runtime.classMethods.__getters.ViewportSize = function(inst)
	if STATE[inst].class == "Camera" then
		return Runtime.viewport
	end
	return nil
end

define("Players", {
	GetPlayers = function(players)
		local out = {}
		for _, child in players:GetChildren() do
			if child:IsA("Player") then
				table.insert(out, child)
			end
		end
		return out
	end,
	GetPlayerByUserId = function(players, id)
		for _, p in players:GetChildren() do
			if p:IsA("Player") and p.UserId == id then
				return p
			end
		end
		return nil
	end,
	GetPlayerFromCharacter = function(players, character)
		for _, p in players:GetChildren() do
			if p:IsA("Player") and p.Character == character and character ~= nil then
				return p
			end
		end
		return nil
	end,
	GetUserThumbnailAsync = function()
		return "rbxasset://textures/ui/GuiImagePlaceholder.png", true
	end,
	GetNameFromUserIdAsync = returns("Player1"),
	GetUserIdFromNameAsync = returns(1),
	GetFriendsAsync = function()
		return {
			GetCurrentPage = returns({}),
			IsFinished = true,
			AdvanceToNextPageAsync = noop,
		}
	end,
	GetHumanoidDescriptionFromUserId = function()
		return Instance.new("HumanoidDescription")
	end,
	GetCharacterAppearanceInfoAsync = returns({ assets = {}, bodyColors = {} }),
})

define("Player", {
	GetMouse = function(player)
		local s = STATE[player]
		if not s.mouse then
			local mouse = {
				X = 0,
				Y = 0,
				Hit = CFrame.new(),
				Target = nil,
				Icon = "",
				ViewSizeX = Runtime.viewport.X,
				ViewSizeY = Runtime.viewport.Y,
				UnitRay = roblox.Ray.new(Vector3.zero, Vector3.new(0, 0, -1)),
				TargetFilter = nil,
			}
			for _, name in { "Move", "Button1Down", "Button1Up", "Button2Down", "Button2Up", "WheelForward", "WheelBackward", "Idle", "KeyDown", "KeyUp" } do
				mouse[name] = Signal.new(`Mouse.{name}`)
			end
			s.mouse = mouse
		end
		return s.mouse
	end,
	Kick = function(_, reason)
		Runtime.warnOnce("kick", `Player:Kick("{reason}") called`)
	end,
	IsInGroup = returns(false),
	GetRankInGroup = returns(0),
	GetRoleInGroup = returns("Guest"),
	LoadCharacter = noop,
	HasAppearanceLoaded = returns(true),
	GetFriendsOnline = returns({}),
	IsFriendsWith = returns(false),
	GetNetworkPing = returns(0.05),
	RequestStreamAroundAsync = noop,
	GetJoinData = function()
		return { TeleportData = World.teleportData }
	end,
	SetAttribute = Runtime.methods.SetAttribute,
})

define("BasePlayerGui", {
	GetGuiObjectsAtPosition = function(_, x, y)
		return Runtime.layout.hitTest(x, y)
	end,
	SetTopbarTransparency = noop,
	GetTopbarTransparency = returns(0),
})

define("GuiService", {
	GetGuiInset = function()
		return Vector2.new(0, Runtime.topInset), Vector2.new(0, 0)
	end,
	IsTenFootInterface = returns(false),
	AddSelectionParent = noop,
	RemoveSelectionGroup = noop,
	Select = noop,
	CloseInspectMenu = noop,
	InspectPlayerFromUserId = noop,
	GetEmotesMenuOpen = returns(false),
	SetEmotesMenuOpen = noop,
	GetInspectMenuEnabled = returns(false),
	SetInspectMenuEnabled = noop,
	OpenBrowserWindow = noop,
})
Runtime.classMethods.__getters.TopbarInset = function(inst)
	if STATE[inst].class == "GuiService" then
		-- The free strip of the top bar between Roblox's left and right buttons.
		return roblox.Rect.new(Vector2.new(120, 0), Vector2.new(Runtime.viewport.X - 60, Runtime.topInset))
	end
	return nil
end

define("UserInputService", {
	GetMouseLocation = function()
		return Runtime.mouse
	end,
	GetMouseDelta = function()
		return Vector2.zero
	end,
	IsKeyDown = function(_, key)
		return Runtime.keysDown[key] == true
	end,
	IsMouseButtonPressed = returns(false),
	GetLastInputType = function()
		return Enum.UserInputType.MouseMovement
	end,
	GetFocusedTextBox = function()
		return Runtime.focusedTextBox
	end,
	GetKeysPressed = returns({}),
	GetMouseButtonsPressed = returns({}),
	GetStringForKeyCode = function(_, key)
		return key.Name
	end,
	GetImageForKeyCode = returns(""),
	GetConnectedGamepads = returns({}),
	GetNavigationGamepads = returns({}),
	GetGamepadConnected = returns(false),
	GetGamepadState = returns({}),
	GetSupportedGamepadKeyCodes = returns({}),
	GetDeviceRotation = function()
		return nil
	end,
	GetDeviceAcceleration = returns(nil),
	GetDeviceGravity = returns(nil),
	GetPlatform = function()
		return Enum.Platform.Windows
	end,
	GamepadSupports = returns(false),
})

-- ── Tweens ────────────────────────────────────────────────────────────────────
-- Renders are snapshots, so a tween jumps straight to its goal. Completed still fires after
-- the tween's real duration, so chained or looping tweens keep behaving.
local Tween = {}
Tween.__index = Tween
Tween.__type = "Instance"

function Tween:Play()
	local info = self.TweenInfo
	if Clock.enabled then
		self.PlaybackState = Enum.PlaybackState.Playing
		Clock.startTween(self)
		return
	end
	local endsAtStart = info.Reverses and info.RepeatCount >= 0
	if not endsAtStart then
		for key, value in self._goals do
			self.Instance[key] = value
		end
	end
	self.PlaybackState = Enum.PlaybackState.Playing
	if info.RepeatCount < 0 then
		return
	end
	local duration = (info.Time * (info.Reverses and 2 or 1)) * (info.RepeatCount + 1) + info.DelayTime
	local token = {}
	self._token = token
	task.delay(math.min(duration, 5), function()
		if self._token == token then
			self.PlaybackState = Enum.PlaybackState.Completed
			self.Completed:Fire(Enum.PlaybackState.Completed)
		end
	end)
end
function Tween:Pause()
	self.PlaybackState = Enum.PlaybackState.Paused
end
function Tween:Cancel()
	Clock.cancelTween(self)
	self._token = nil
	self.PlaybackState = Enum.PlaybackState.Cancelled
end
function Tween:Destroy()
	self._token = nil
end

define("TweenService", {
	Create = function(_, inst, info, goals)
		assert(Runtime.isInstance(inst), "TweenService:Create expects an Instance")
		return setmetatable({
			Instance = inst,
			TweenInfo = info,
			_goals = goals,
			PlaybackState = Enum.PlaybackState.Begin,
			Completed = Signal.new("Tween.Completed"),
		}, Tween)
	end,
	GetValue = function(_, alpha)
		return alpha
	end,
	SmoothDamp = function(_, current)
		return current
	end,
})

define("RunService", {
	IsStudio = function()
		return Runtime.isStudio
	end,
	-- Loopback runs server and client code in one process; ask who is calling.
	IsClient = function()
		return Runtime.callerContext(1) == "client"
	end,
	IsServer = function()
		return Runtime.callerContext(1) == "server"
	end,
	IsRunning = returns(true),
	IsRunMode = returns(false),
	IsEdit = returns(false),
	BindToRenderStep = function(_, name, priority, fn)
		Runtime.renderSteps[name] = { priority = priority, fn = fn }
	end,
	UnbindFromRenderStep = function(_, name)
		Runtime.renderSteps[name] = nil
	end,
	Set3dRenderingEnabled = noop,
})

define("ContextActionService", {
	BindAction = function(_, name, fn, _touch, ...)
		Runtime.actions[name] = { fn = fn, keys = { ... } }
	end,
	BindActionAtPriority = function(_, name, fn, _touch, _priority, ...)
		Runtime.actions[name] = { fn = fn, keys = { ... } }
	end,
	UnbindAction = function(_, name)
		Runtime.actions[name] = nil
	end,
	UnbindAllActions = function()
		table.clear(Runtime.actions)
	end,
	GetButton = returns(nil),
	SetTitle = noop,
	SetImage = noop,
	SetPosition = noop,
	SetDescription = noop,
	GetBoundActionInfo = returns({}),
	GetAllBoundActionInfo = returns({}),
})

define("CollectionService", {
	GetTagged = function(_, tag)
		local out = {}
		Runtime.eachDescendant(Runtime.game, function(inst)
			if STATE[inst].tags[tag] then
				table.insert(out, inst)
			end
		end)
		return out
	end,
	GetInstanceAddedSignal = function(_, tag)
		return Signal.new(`TagAdded:{tag}`)
	end,
	GetInstanceRemovedSignal = function(_, tag)
		return Signal.new(`TagRemoved:{tag}`)
	end,
	AddTag = function(_, inst, tag)
		inst:AddTag(tag)
	end,
	RemoveTag = function(_, inst, tag)
		inst:RemoveTag(tag)
	end,
	HasTag = function(_, inst, tag)
		return inst:HasTag(tag)
	end,
	GetTags = function(_, inst)
		return inst:GetTags()
	end,
	GetAllTags = returns({}),
})

define("Debris", {
	AddItem = function(_, inst, lifetime)
		task.delay(math.min(lifetime or 10, 5), function()
			inst:Destroy()
		end)
	end,
})

define("ContentProvider", {
	PreloadAsync = function(_, list, callback)
		if callback then
			for _, item in list do
				task.spawn(callback, typeof(item) == "string" and item or "", Enum.AssetFetchStatus.Success)
			end
		end
	end,
	GetAssetFetchStatus = function()
		return Enum.AssetFetchStatus.Success
	end,
})

define("StarterGui", {
	SetCoreGuiEnabled = noop,
	GetCoreGuiEnabled = returns(true),
	SetCore = noop,
	GetCore = returns(nil),
	RegisterGetCore = noop,
	RegisterSetCore = noop,
})

define("TextService", {
	GetTextSize = function(_, text, size, font, frameSize)
		return Runtime.text.getTextSize(text, size, roblox.Font.fromEnum(font), frameSize)
	end,
	GetTextBoundsAsync = function(_, params)
		return Runtime.text.getTextSize(params.Text, params.Size, params.Font, Vector2.new(params.Width or math.huge, math.huge), params.RichText)
	end,
	FilterStringAsync = function(_, text)
		return {
			GetNonChatStringForBroadcastAsync = returns(text),
			GetNonChatStringForUserAsync = returns(text),
			GetChatForUserAsync = returns(text),
		}
	end,
})

define("HttpService", {
	JSONEncode = function(_, value)
		return serde.encode("json", value)
	end,
	JSONDecode = function(_, text)
		return serde.decode("json", text)
	end,
	GenerateGUID = function(_, wrap)
		local id = string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
			local v = c == "x" and math.random(0, 15) or math.random(8, 11)
			return string.format("%X", v)
		end)
		return wrap == false and id or `\{{id}\}`
	end,
	UrlEncode = function(_, text)
		return (string.gsub(text, "[^%w%-_%.~]", function(c)
			return string.format("%%%02X", string.byte(c))
		end))
	end,
})

define("MarketplaceService", {
	PromptProductPurchase = noop,
	PromptGamePassPurchase = noop,
	PromptPurchase = noop,
	PromptPremiumPurchase = noop,
	UserOwnsGamePassAsync = returns(false),
	PlayerOwnsAsset = returns(false),
	GetProductInfo = returns({ Name = "Product", PriceInRobux = 0, Description = "" }),
})
define("TeleportService", {
	GetLocalPlayerTeleportData = function()
		return World.teleportData
	end,
	Teleport = noop,
	TeleportAsync = noop,
	TeleportToPlaceInstance = noop,
	SetTeleportGui = function(_, gui)
		World.teleportGui = gui
	end,
	GetArrivingTeleportGui = returns(nil),
	GetTeleportSetting = returns(nil),
	SetTeleportSetting = noop,
})
define("SocialService", {
	CanSendGameInviteAsync = returns(false),
	PromptGameInvite = noop,
	CanSendCallInviteAsync = returns(false),
})
define("PolicyService", {
	GetPolicyInfoForPlayerAsync = returns({
		AreAdsAllowed = true,
		ArePaidRandomItemsRestricted = false,
		AllowedExternalLinkReferences = {},
		IsPaidItemTradingAllowed = true,
		IsSubjectToChinaPolicies = false,
	}),
})
define("LocalizationService", {
	GetTranslatorForPlayerAsync = function()
		return {
			LocaleId = "en-us",
			Translate = function(_, _context, text)
				return text
			end,
			FormatByKey = function(_, key)
				return key
			end,
		}
	end,
	GetCountryRegionForPlayerAsync = returns("US"),
})
define("BadgeService", { UserHasBadgeAsync = returns(false), AwardBadge = returns(false) })
define("SoundService", { PlayLocalSound = noop, GetListener = returns(nil), SetListener = noop })
define("ReplicatedFirst", { RemoveDefaultLoadingScreen = noop, SetDefaultLoadingGuiEnabled = noop, IsFinishedReplicating = returns(true) })
define("Lighting", { GetMinutesAfterMidnight = returns(720), SetMinutesAfterMidnight = noop, GetSunDirection = returns(Vector3.new(0, 1, 0)), GetMoonDirection = returns(Vector3.new(0, -1, 0)) })
define("VRService", { GetUserCFrame = returns(CFrame.new()), GetUserCFrameEnabled = returns(false), RecenterUserHeadCFrame = noop })
define("HapticService", { IsVibrationSupported = returns(false), IsMotorSupported = returns(false), SetMotor = noop })
define("GroupService", { GetGroupInfoAsync = returns({}), GetGroupsAsync = returns({}) })
define("AvatarEditorService", { PromptAllowInventoryReadAccess = noop })
define("UserGameSettings", { GetCameraYInvertValue = returns(1), InFullScreen = returns(true), InStudioMode = returns(false) })

-- In-memory DataStores. Scenarios can seed them: ui.datastore("Name", "key", value).
Runtime.datastores = {}

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[deepCopy(k)] = deepCopy(v)
	end
	return out
end
Runtime.deepCopy = deepCopy

local function dataStore(name: string)
	Runtime.datastores[name] = Runtime.datastores[name] or {}
	local data = Runtime.datastores[name]
	local store = {}
	function store:GetAsync(key)
		return deepCopy(data[key]), { Version = "1", CreatedTime = 0, UpdatedTime = 0 }
	end
	function store:SetAsync(key, value)
		data[key] = deepCopy(value)
		return "1"
	end
	function store:UpdateAsync(key, fn)
		local new = fn(deepCopy(data[key]), { Version = "1" })
		if new ~= nil then
			data[key] = deepCopy(new)
		end
		return deepCopy(new)
	end
	function store:IncrementAsync(key, delta)
		data[key] = (data[key] or 0) + (delta or 1)
		return data[key]
	end
	function store:RemoveAsync(key)
		local old = data[key]
		data[key] = nil
		return old
	end
	function store:GetSortedAsync()
		return { GetCurrentPage = returns({}), IsFinished = true, AdvanceToNextPageAsync = noop }
	end
	function store:ListKeysAsync()
		return { GetCurrentPage = returns({}), IsFinished = true, AdvanceToNextPageAsync = noop }
	end
	return store
end
define("DataStoreService", {
	GetDataStore = function(_, name, scope)
		return dataStore(scope and `{name}/{scope}` or name)
	end,
	GetOrderedDataStore = function(_, name)
		return dataStore(`ordered:{name}`)
	end,
	GetGlobalDataStore = function()
		return dataStore("global")
	end,
	GetRequestBudgetForRequestType = returns(100),
})
define("MessagingService", {
	PublishAsync = noop,
	SubscribeAsync = function()
		return { Disconnect = noop, Connected = true }
	end,
})
local function memoryStructure()
	return setmetatable({}, {
		__index = function()
			return returns(nil)
		end,
	})
end
define("MemoryStoreService", {
	GetSortedMap = memoryStructure,
	GetQueue = memoryStructure,
	GetHashMap = memoryStructure,
})
define("TeleportOptions", {
	SetTeleportData = function(inst, data)
		STATE[inst].teleportData = data
	end,
	GetTeleportData = function(inst)
		return STATE[inst].teleportData
	end,
})
Runtime.classMethods.TeleportService.ReserveServer = function()
	return "reserved-server-code", "private-server-id"
end
Runtime.classMethods.TeleportService.TeleportAsync = function(_, placeId)
	Runtime.warnOnce(`teleport:{placeId}`, `TeleportService:TeleportAsync({placeId}) called — the player would leave this place here`)
	return nil
end

local SERVICE_ALIASES = { workspace = "Workspace" }

function Runtime.service(className: string)
	className = SERVICE_ALIASES[className] or className
	local game = Runtime.game
	local existing = game:FindFirstChildOfClass(className)
	if existing then
		return existing
	end
	local service = Instance.new(className)
	service.Name = className
	service.Parent = game
	return service
end

-- ── Red networking ────────────────────────────────────────────────────────────
-- Client and (optional) loopback server talk through here. Like Roblox remotes, events sent
-- before anyone listens are queued and delivered when the listener connects.
--   ui.server("ShopService", "StockUpdated", list)   -> plays the server: fires client :On handlers
--   ui.reply("LoadoutService", "GetLoadout", fn)          -> answers client Fire/Call instead of a server
Runtime.red = { handlers = {}, serverHandlers = {}, replies = {}, clientQueue = {}, serverQueue = {}, traffic = {} }

local function describeArgs(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		local text = type(v) == "string" and `"{v}"` or type(v) == "table" and not Runtime.isInstance(v) and "{…}" or tostring(v)
		table.insert(parts, text)
	end
	return table.concat(parts, ", ")
end

local function bucket(root, name, event)
	root[name] = root[name] or {}
	root[name][event] = root[name][event] or {}
	return root[name][event]
end

-- Server -> client.
function Runtime.red.deliver(name: string, event: string, ...)
	local red = Runtime.red
	table.insert(red.traffic, `← {name}.{event}({describeArgs(...)})`)
	local handlers = red.handlers[name] and red.handlers[name][event]
	if handlers and #handlers > 0 then
		for _, cb in handlers do
			Runtime.spawnGuarded(`{name}.{event} (client handler)`, cb, ...)
		end
	else
		table.insert(bucket(red.clientQueue, name, event), table.pack(...))
	end
end

-- Client -> server: a loopback server handler, else a scenario reply, else queued for a server.
local function toServer(name: string, event: string, args)
	local red = Runtime.red
	local handlers = red.serverHandlers[name] and red.serverHandlers[name][event]
	if handlers and #handlers > 0 then
		for _, cb in handlers do
			Runtime.spawnGuarded(`{name}.{event} (server handler)`, cb, Runtime.player, table.unpack(args, 1, args.n))
		end
		return
	end
	local reply = red.replies[name] and red.replies[name][event]
	if reply then
		Runtime.spawnGuarded(`reply {name}.{event}`, reply, table.unpack(args, 1, args.n))
		return
	end
	if Runtime.serverRunning then
		table.insert(bucket(red.serverQueue, name, event), args)
	end
end

local function makeRed(realRed)
	local red = Runtime.red
	local function client(name: string)
		local c = {}
		function c:Fire(event, ...)
			table.insert(red.traffic, `→ {name}.{event}({describeArgs(...)})`)
			toServer(name, event, table.pack(...))
		end
		function c:Call(event, ...)
			table.insert(red.traffic, `⇄ {name}.{event}({describeArgs(...)})`)
			local args = table.pack(...)
			local handlers = red.serverHandlers[name] and red.serverHandlers[name][event]
			local answer
			if handlers and handlers[1] then
				answer = function(...)
					return handlers[1](Runtime.player, ...)
				end
			else
				answer = red.replies[name] and red.replies[name][event]
			end
			local Promise = realRed and realRed.Promise
			if Promise then
				return Promise.Promise(function(resolve)
					resolve(if answer then answer(table.unpack(args, 1, args.n)) else nil)
				end)
			end
			return if answer then answer(...) else nil
		end
		function c:On(event, callback)
			table.insert(bucket(red.handlers, name, event), callback)
			local queue = red.clientQueue[name] and red.clientQueue[name][event]
			if queue and #queue > 0 then
				red.clientQueue[name][event] = {}
				for _, args in queue do
					Runtime.spawnGuarded(`{name}.{event} (queued)`, callback, table.unpack(args, 1, args.n))
				end
			end
		end
		function c:Folder()
			return Instance.new("Folder")
		end
		c.LocalFolder = c.Folder
		return c
	end
	local function server(name: string)
		local sv = {}
		local function isLocal(player)
			return player == Runtime.player
		end
		function sv:Fire(player, event, ...)
			if isLocal(player) then
				Runtime.red.deliver(name, event, ...)
			end
		end
		function sv:FireAll(event, ...)
			Runtime.red.deliver(name, event, ...)
		end
		function sv:FireAllExcept(player, event, ...)
			if not isLocal(player) then
				Runtime.red.deliver(name, event, ...)
			end
		end
		function sv:FireList(list, event, ...)
			if table.find(list, Runtime.player) then
				Runtime.red.deliver(name, event, ...)
			end
		end
		function sv:FireWithFilter(filter, event, ...)
			if filter(Runtime.player) then
				Runtime.red.deliver(name, event, ...)
			end
		end
		function sv:On(event, callback)
			table.insert(bucket(red.serverHandlers, name, event), callback)
			local queue = red.serverQueue[name] and red.serverQueue[name][event]
			if queue and #queue > 0 then
				red.serverQueue[name][event] = {}
				for _, args in queue do
					Runtime.spawnGuarded(`{name}.{event} (queued)`, callback, Runtime.player, table.unpack(args, 1, args.n))
				end
			end
		end
		function sv:Folder()
			return Instance.new("Folder")
		end
		return sv
	end
	return setmetatable({
		Client = client,
		Server = server,
	}, {
		__index = function(_, key)
			return realRed and realRed[key]
		end,
	})
end

-- Loads Red's utility modules (Promise, Signal, ...) for real, replacing only the networking.
function World.installRed()
	local packages = Runtime.game.ReplicatedStorage:FindFirstChild("Packages")
	local redModule = packages and packages:FindFirstChild("Red")
	local utils
	if redModule then
		local util = redModule:FindFirstChild("Util")
		if util then
			utils = setmetatable({}, {
				__index = function(t, key)
					local module = util:FindFirstChild(key)
					local value = module and Runtime.require(module)
					rawset(t, key, value)
					return value
				end,
			})
		end
		Runtime.overrideModule(redModule:GetFullName(), makeRed(utils))
	end
end

-- ── Global environment ────────────────────────────────────────────────────────
local luneTypeof = typeof

local function customTypeof(value)
	if Runtime.isInstance(value) then
		return "Instance"
	end
	if type(value) == "table" then
		local mt = getmetatable(value)
		if mt == Signal then
			return "RBXScriptSignal"
		elseif type(mt) == "table" and rawget(mt, "Disconnect") then
			return "RBXScriptConnection"
		elseif type(mt) == "table" and rawget(mt, "__type") then
			return mt.__type
		end
	end
	return luneTypeof(value)
end

local started = os.clock()

local function makeTask()
	return {
		spawn = function(fn, ...)
			if type(fn) == "thread" then
				return task.spawn(fn, ...)
			end
			return Runtime.spawnGuarded("task.spawn", fn, ...)
		end,
		defer = function(fn, ...)
			if type(fn) == "thread" then
				return task.defer(fn, ...)
			end
			local args = table.pack(...)
			return task.defer(function()
				Runtime.spawnGuarded("task.defer", fn, table.unpack(args, 1, args.n))
			end)
		end,
		delay = function(t, fn, ...)
			local args = table.pack(...)
			if Clock.enabled then
				Clock.delay(t, function(...)
					if type(fn) == "thread" then
						task.spawn(fn, ...)
					else
						Runtime.spawnGuarded("task.delay", fn, ...)
					end
				end, args)
				return nil
			end
			-- Short delays count as start-up work that ui.boot waits for.
			local tracked = (t or 0) <= 2
			if tracked then
				Runtime.pendingDelays += 1
			end
			return task.delay(t or 0, function()
				if tracked then
					Runtime.pendingDelays -= 1
				end
				if type(fn) == "thread" then
					coroutine.resume(fn, table.unpack(args, 1, args.n))
				else
					Runtime.spawnGuarded("task.delay", fn, table.unpack(args, 1, args.n))
				end
			end)
		end,
		wait = function(t)
			if Clock.enabled then
				return Clock.sleep(t)
			end
			return task.wait(t)
		end,
		cancel = function(thread)
			pcall(task.cancel, thread)
		end,
		synchronize = noop,
		desynchronize = noop,
	}
end

local function paramsType(name, defaults)
	return {
		new = function()
			local t = table.clone(defaults)
			t.__uikit = name
			return setmetatable(t, { __type = name })
		end,
	}
end

function World.environment(context: string)
	local game = Runtime.game
	local userSettings = Instance.new("UserSettings")
	local gameSettings = Instance.new("UserGameSettings")
	gameSettings.Parent = userSettings
	STATE[userSettings].strict = false
	Runtime.define("UserSettings", {
		GetService = function(_, name)
			return name == "UserGameSettings" and gameSettings or Runtime.service(name)
		end,
	})
	local taskLib = makeTask()
	local env = {
		game = game,
		Game = game,
		workspace = game:GetService("Workspace"),
		Workspace = game:GetService("Workspace"),
		script = nil,
		Instance = {
			new = Instance.new,
			fromExisting = function(inst)
				return inst:Clone()
			end,
		},
		typeof = customTypeof,
		task = taskLib,
		wait = function(t)
			if Clock.enabled then
				return Clock.sleep(t), Clock.now
			end
			return task.wait(t), os.clock() - started
		end,
		spawn = function(fn)
			taskLib.defer(fn)
		end,
		delay = function(t, fn)
			taskLib.delay(t, fn)
		end,
		tick = function()
			return Clock.enabled and (1.7e9 + Clock.now) or (os.time() + (os.clock() % 1))
		end,
		time = function()
			return Clock.enabled and Clock.now or (os.clock() - started)
		end,
		elapsedTime = function()
			return Clock.enabled and Clock.now or (os.clock() - started)
		end,
		-- os.clock follows the virtual clock in animate mode (e.g. minimum loading-screen time)
		os = setmetatable({
			clock = function()
				return Clock.enabled and Clock.now or os.clock()
			end,
		}, { __index = os }),
		version = returns("0.700.0.0"),
		settings = function()
			return {
				Rendering = { QualityLevel = Enum.QualityLevel.Automatic },
				Network = {},
				Physics = {},
				GameSettings = {},
			}
		end,
		UserSettings = function()
			return userSettings
		end,
		shared = {},
		_G = {},
		plugin = nil,
		printidentity = noop,
		require = function(target)
			return Runtime.require(target, context)
		end,
		__context = context,
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			local line = table.concat(parts, " ")
			table.insert(Runtime.log, line)
			if Runtime.echo then
				print(`  │ {line}`)
			end
		end,
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			local line = "WARN " .. table.concat(parts, " ")
			table.insert(Runtime.log, line)
			print(`\27[33m  │ {line}\27[0m`)
		end,
		Enum = Enum,
		Vector2 = Vector2,
		Vector3 = Vector3,
		CFrame = CFrame,
		Color3 = roblox.Color3,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Rect = roblox.Rect,
		Font = roblox.Font,
		BrickColor = roblox.BrickColor,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		PhysicalProperties = roblox.PhysicalProperties,
		Ray = roblox.Ray,
		Region3 = roblox.Region3,
		Region3int16 = roblox.Region3int16,
		Vector2int16 = roblox.Vector2int16,
		Vector3int16 = roblox.Vector3int16,
		Axes = roblox.Axes,
		Faces = roblox.Faces,
		TweenInfo = Runtime.TweenInfo,
		Random = Runtime.Random,
		DateTime = Runtime.DateTime,
		RaycastParams = paramsType("RaycastParams", { FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude, IgnoreWater = false, CollisionGroup = "Default", RespectCanCollide = false }),
		OverlapParams = paramsType("OverlapParams", { FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude, MaxParts = 0, CollisionGroup = "Default" }),
		PathWaypoint = paramsType("PathWaypoint", {}),
		CatalogSearchParams = paramsType("CatalogSearchParams", {}),
		SharedTable = {
			new = function(t)
				return table.clone(t or {})
			end,
		},
	}
	return env
end

-- ── Assembling the world ──────────────────────────────────────────────────────
function World.create(opts)
	Runtime.viewport = opts.viewport or Runtime.viewport
	Runtime.isStudio = opts.studio == true
	Runtime.mouse = Vector2.new(Runtime.viewport.X / 2, Runtime.viewport.Y / 2)
	Runtime.keysDown = {}
	Runtime.renderSteps = {}
	Runtime.actions = {}

	local game = Instance.new("DataModel")
	game.Name = "Game"
	Runtime.game = game

	for _, name in {
		"Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService",
		"ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "SoundService", "Teams", "TestService",
	} do
		Runtime.service(name)
	end
	local workspace = game.Workspace
	local camera = Instance.new("Camera")
	camera.Name = "Camera"
	camera.Parent = workspace
	raw(workspace, "CurrentCamera", camera)
	local starterPlayer = game.StarterPlayer
	for _, name in { "StarterPlayerScripts", "StarterCharacterScripts" } do
		local folder = Instance.new(name)
		folder.Name = name
		folder.Parent = starterPlayer
	end

	local uis = Runtime.service("UserInputService")
	raw(uis, "TouchEnabled", false)
	raw(uis, "KeyboardEnabled", true)
	raw(uis, "MouseEnabled", true)
	raw(uis, "GamepadEnabled", false)
	raw(uis, "VREnabled", false)
	raw(uis, "AccelerometerEnabled", false)
	raw(uis, "GyroscopeEnabled", false)
	raw(uis, "MouseIconEnabled", true)
	raw(uis, "MouseBehavior", Enum.MouseBehavior.Default)
	raw(uis, "PreferredInput", Enum.PreferredInput.KeyboardAndMouse)

	local gui = Runtime.service("GuiService")
	raw(gui, "MenuIsOpen", false)
	raw(gui, "SelectedObject", nil)
	raw(gui, "ReducedMotionEnabled", false)
	raw(gui, "PreferredTransparency", 1)
	raw(gui, "PreferredTextSize", Enum.PreferredTextSize.Medium)

	local players = game.Players
	local player = Instance.new("Player")
	player.Name = opts.playerName or "Player1"
	raw(player, "DisplayName", opts.playerName or "Player1")
	raw(player, "UserId", opts.userId or 1)
	raw(player, "AccountAge", 365)
	raw(player, "MembershipType", Enum.MembershipType.None)
	raw(player, "LocaleId", "en-us")
	raw(player, "Character", nil)
	raw(players, "LocalPlayer", player) -- parented to Players when it joins (World.join)
	local playerGui = Instance.new("PlayerGui")
	playerGui.Name = "PlayerGui"
	playerGui.Parent = player
	local playerScripts = Instance.new("PlayerScripts")
	playerScripts.Name = "PlayerScripts"
	playerScripts.Parent = player
	local backpack = Instance.new("Backpack")
	backpack.Name = "Backpack"
	backpack.Parent = player
	Runtime.player = player
	Runtime.playerGui = playerGui

	return game
end

-- The local player joins: parented to Players and PlayerAdded fires (server code sees the join).
function World.join()
	local player = Runtime.player
	if player.Parent then
		return
	end
	player.Parent = Runtime.game.Players
	Runtime.fireIf(Runtime.game.Players, "PlayerAdded", player)
end

-- A bare R15-shaped rig: parts + Humanoid + Animator.
function World.buildRig(name: string)
	local model = Instance.new("Model")
	model.Name = name
	local parts = {
		{ "HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0) },
		{ "Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 4.6, 0) },
		{ "UpperTorso", Vector3.new(2, 1.6, 1), Vector3.new(0, 3.4, 0) },
		{ "LowerTorso", Vector3.new(2, 0.4, 1), Vector3.new(0, 2.4, 0) },
		{ "LeftUpperArm", Vector3.new(1, 1.2, 1), Vector3.new(-1.5, 3.6, 0) },
		{ "RightUpperArm", Vector3.new(1, 1.2, 1), Vector3.new(1.5, 3.6, 0) },
		{ "LeftLowerArm", Vector3.new(1, 1, 1), Vector3.new(-1.5, 2.6, 0) },
		{ "RightLowerArm", Vector3.new(1, 1, 1), Vector3.new(1.5, 2.6, 0) },
		{ "LeftHand", Vector3.new(1, 0.3, 1), Vector3.new(-1.5, 1.9, 0) },
		{ "RightHand", Vector3.new(1, 0.3, 1), Vector3.new(1.5, 1.9, 0) },
		{ "LeftUpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(-0.5, 1.6, 0) },
		{ "RightUpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(0.5, 1.6, 0) },
		{ "LeftLowerLeg", Vector3.new(1, 1, 1), Vector3.new(-0.5, 0.6, 0) },
		{ "RightLowerLeg", Vector3.new(1, 1, 1), Vector3.new(0.5, 0.6, 0) },
		{ "LeftFoot", Vector3.new(1, 0.3, 1), Vector3.new(-0.5, 0, 0) },
		{ "RightFoot", Vector3.new(1, 0.3, 1), Vector3.new(0.5, 0, 0) },
	}
	for _, spec in parts do
		local part = Instance.new("MeshPart")
		part.Name = spec[1]
		part.Size = spec[2]
		part.CFrame = CFrame.new(spec[3])
		part.Parent = model
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.Parent = model
	local animator = Instance.new("Animator")
	animator.Name = "Animator"
	animator.Parent = humanoid
	STATE[model].props.PrimaryPart = model.HumanoidRootPart
	return model
end

-- Spawns the player's character like Roblox: a clone of StarterPlayer.StarterCharacter if the
-- place has one, otherwise a bare rig.
function World.spawnCharacter()
	local player = Runtime.player
	if player.Character then
		return player.Character
	end
	local template = Runtime.game.StarterPlayer:FindFirstChild("StarterCharacter")
	local model = template and template:Clone() or World.buildRig(player.Name)
	model.Name = player.Name
	model.Parent = Runtime.game.Workspace
	raw(player, "Character", model)
	Runtime.propChanged(player, "Character", model)
	Runtime.fireIf(player, "CharacterAdded", model)
	return model
end

-- Runs the place's server scripts in the server context (loopback mode).
function World.startServer()
	Runtime.serverRunning = true
	local game = Runtime.game
	for _, root in { game.ServerScriptService, game.Workspace } do
		for _, inst in root:GetDescendants() do
			if STATE[inst].class == "Script" and inst.Enabled ~= false and STATE[inst].props.Disabled ~= true then
				if inst.RunContext ~= Enum.RunContext.Client then
					Runtime.runScript(inst, "server")
				end
			end
		end
	end
end

-- Copies Starter* contents into the player and runs every client script, in Roblox's order.
function World.startClient(opts)
	opts = opts or {}
	local game = Runtime.game
	local player = Runtime.player
	World.join()
	local skip = {}
	for _, name in opts.skipScripts or {} do
		skip[name] = true
	end

	local function runAll(root)
		local list = { root }
		for _, d in root:GetDescendants() do
			table.insert(list, d)
		end
		for _, inst in list do
			local s = STATE[inst]
			if s.class == "LocalScript" and not skip[inst.Name] and inst.Enabled ~= false and s.props.Disabled ~= true then
				if not inst:FindFirstAncestorOfClass("LocalScript") or inst == root then
					Runtime.runScript(inst)
				end
			end
		end
	end

	-- ReplicatedFirst runs first, then PlayerScripts, then the PlayerGui copy of StarterGui.
	-- The loading screen holds for several seconds; only run it when a scenario asks for it.
	if opts.loadingScreen then
		for _, child in game.ReplicatedFirst:GetChildren() do
			runAll(child)
		end
	end
	for _, child in game.StarterPlayer.StarterPlayerScripts:GetChildren() do
		local copy = child:Clone()
		copy.Parent = player.PlayerScripts
		runAll(copy)
	end
	for _, child in game.StarterGui:GetChildren() do
		local copy = child:Clone()
		copy.Parent = player.PlayerGui
		runAll(copy)
	end
end

return World
