-- The shop: a coin counter and SHOP button on the HUD, and a window with category tabs,
-- an item grid and a detail panel. Purchases go through ReplicatedStorage.ShopRemotes.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ShopItems = require(ReplicatedStorage:WaitForChild("ShopItems"))
local remotes = ReplicatedStorage:WaitForChild("ShopRemotes")
local buyRemote = remotes:WaitForChild("Buy")
local stateChanged = remotes:WaitForChild("StateChanged")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 230)
local WHITE = Color3.fromRGB(255, 255, 255)
local INK = Color3.fromRGB(64, 42, 30)
local ORANGE = Color3.fromRGB(255, 146, 48)
local ORANGE_DARK = Color3.fromRGB(206, 98, 18)
local GREEN = Color3.fromRGB(80, 200, 96)
local GREEN_DARK = Color3.fromRGB(40, 142, 58)
local RED = Color3.fromRGB(238, 72, 72)
local GOLD = Color3.fromRGB(255, 205, 50)
local GREY = Color3.fromRGB(176, 166, 156)

local RARITY_COLORS = {
	Common = Color3.fromRGB(140, 150, 160),
	Rare = Color3.fromRGB(60, 140, 255),
	Epic = Color3.fromRGB(170, 90, 255),
	Legendary = Color3.fromRGB(255, 160, 0),
}

local CATEGORIES = { "Pets", "Trails", "Boosts" }
local TITLE_FONT = Enum.Font.FredokaOne
local BODY_FONT = Enum.Font.GothamBold

local coins = 0
local owned = {}
local category = "Pets"
local selected = nil

local function firstIn(name)
	for _, item in ShopItems do
		if item.category == name then
			return item
		end
	end
	return nil
end
selected = firstIn(category)

-- ── Building blocks ──────────────────────────────────────────────────────────
local function make(className, props, children)
	local inst = Instance.new(className)
	local parent = props.Parent
	props.Parent = nil
	for key, value in props do
		inst[key] = value
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function corner(radius)
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function round()
	return make("UICorner", { CornerRadius = UDim.new(1, 0) })
end

local function outline(color, thickness)
	return make("UIStroke", { Color = color, Thickness = thickness, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function textOutline(color, thickness)
	return make("UIStroke", { Color = color, Thickness = thickness })
end

local function label(props, children)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.Font = props.Font or BODY_FONT
	props.TextColor3 = props.TextColor3 or INK
	return make("TextLabel", props, children)
end

local function coinIcon(size, position)
	return make("Frame", {
		Name = "Coin",
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = GOLD,
	}, {
		round(),
		outline(ORANGE_DARK, math.max(2, size // 10)),
		make("Frame", {
			Size = UDim2.fromScale(0.45, 0.45),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.fromRGB(255, 232, 140),
		}, { round() }),
	})
end

local function formatNumber(n)
	local text = tostring(n)
	while true do
		local replaced, count = string.gsub(text, "^(-?%d+)(%d%d%d)", "%1,%2")
		text = replaced
		if count == 0 then
			return text
		end
	end
end

-- The picture on a tile: a face for pets, streaks for trails, a multiplier for boosts.
local function itemArt(item, size)
	local art = make("Frame", {
		Name = "Art",
		Size = size,
		BackgroundColor3 = item.color,
	}, {
		corner(14),
		make("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(WHITE, Color3.fromRGB(200, 200, 200)),
		}),
	})
	if item.category == "Pets" then
		local body = make("Frame", {
			Size = UDim2.fromScale(0.42, 0.62),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			Position = UDim2.fromScale(0.5, 0.56),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = item.color:Lerp(INK, 0.15),
			Parent = art,
		}, { corner(22), outline(INK, 3) })
		make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = body })
		for _, x in { 0.32, 0.68 } do
			make("Frame", {
				Size = UDim2.fromScale(0.14, 0.22),
				Position = UDim2.fromScale(x, 0.42),
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = INK,
				Parent = body,
			}, { round() })
		end
		make("Frame", {
			Size = UDim2.fromScale(0.3, 0.08),
			Position = UDim2.fromScale(0.5, 0.7),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = INK,
			Parent = body,
		}, { round() })
	elseif item.category == "Trails" then
		for index, width in { 0.7, 0.55, 0.4 } do
			make("Frame", {
				Size = UDim2.fromScale(width, 0.1),
				Position = UDim2.fromScale(0.5, 0.3 + index * 0.13),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Rotation = -14,
				BackgroundColor3 = item.color:Lerp(WHITE, 0.25 * (index - 1)),
				Parent = art,
			}, { round(), outline(INK, 2) })
		end
	else
		label({
			Text = string.match(item.stat, "^(%d+x)") or "x",
			Font = TITLE_FONT,
			TextScaled = true,
			TextColor3 = WHITE,
			Size = UDim2.fromScale(0.8, 0.6),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Parent = art,
		}, { textOutline(INK, 3) })
	end
	return art
end

local function chunkyButton(props, color, shadow)
	-- A darker copy sits under the button so it reads as raised.
	local holder = make("Frame", {
		Name = props.Name,
		Size = props.Size,
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		BackgroundColor3 = shadow,
		Parent = props.Parent,
	}, { corner(props.Radius or 16) })
	local button = make("TextButton", {
		Name = "Button",
		Size = UDim2.new(1, 0, 1, -5),
		BackgroundColor3 = color,
		AutoButtonColor = false,
		Font = TITLE_FONT,
		Text = props.Text,
		TextSize = props.TextSize or 26,
		TextColor3 = WHITE,
		Parent = holder,
	}, { corner(props.Radius or 16), textOutline(shadow, 2) })
	return holder, button
end

-- ── Screen ───────────────────────────────────────────────────────────────────
local gui = make("ScreenGui", {
	Name = "ShopGui",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

local uiScale = make("UIScale", { Parent = gui })
local function rescale()
	local viewport = workspace.CurrentCamera.ViewportSize
	uiScale.Scale = math.clamp(math.min(viewport.X / 1366, viewport.Y / 768), 0.5, 1.3)
end
rescale()
workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)

-- Coin counter, top right.
local wallet = make("Frame", {
	Name = "Wallet",
	Size = UDim2.fromOffset(210, 54),
	Position = UDim2.new(1, -20, 0, 16),
	AnchorPoint = Vector2.new(1, 0),
	BackgroundColor3 = WHITE,
	Parent = gui,
}, { round(), outline(INK, 3) })
coinIcon(40, UDim2.new(0, 8, 0.5, 0)).Parent = wallet
local coinsLabel = label({
	Name = "Amount",
	Text = "0",
	Font = TITLE_FONT,
	TextSize = 30,
	TextXAlignment = Enum.TextXAlignment.Right,
	Size = UDim2.new(1, -70, 1, 0),
	Position = UDim2.fromOffset(52, 0),
	Parent = wallet,
})

-- SHOP button, left edge.
local _, shopButton = chunkyButton({
	Name = "ShopButton",
	Text = "SHOP",
	TextSize = 30,
	Size = UDim2.fromOffset(112, 112),
	Position = UDim2.new(0, 20, 0.5, 0),
	AnchorPoint = Vector2.new(0, 0.5),
	Radius = 26,
	Parent = gui,
}, ORANGE, ORANGE_DARK)

-- ── Window ───────────────────────────────────────────────────────────────────
local window = make("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(980, 600),
	Position = UDim2.fromScale(0.5, 0.55),
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = CREAM,
	Visible = false,
	Parent = gui,
}, { corner(28), outline(INK, 4) })

local header = make("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 76),
	BackgroundColor3 = ORANGE,
	Parent = window,
}, { corner(28) })
-- Squares off the header's bottom corners.
make("Frame", {
	Size = UDim2.new(1, 0, 0, 28),
	Position = UDim2.new(0, 0, 1, -28),
	BackgroundColor3 = ORANGE,
	BorderSizePixel = 0,
	Parent = header,
})
make("Frame", {
	Size = UDim2.new(1, 0, 0, 4),
	Position = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = INK,
	BorderSizePixel = 0,
	Parent = header,
})
label({
	Name = "Title",
	Text = "Shop",
	Font = TITLE_FONT,
	TextSize = 44,
	TextColor3 = WHITE,
	TextXAlignment = Enum.TextXAlignment.Left,
	Size = UDim2.new(1, -120, 1, 0),
	Position = UDim2.fromOffset(28, 0),
	Parent = header,
}, { textOutline(ORANGE_DARK, 3) })
local _, closeButton = chunkyButton({
	Name = "Close",
	Text = "X",
	TextSize = 30,
	Size = UDim2.fromOffset(56, 56),
	Position = UDim2.new(1, -16, 0.5, 0),
	AnchorPoint = Vector2.new(1, 0.5),
	Radius = 14,
	Parent = header,
}, RED, Color3.fromRGB(170, 40, 40))

local body = make("Frame", {
	Name = "Body",
	Size = UDim2.new(1, -40, 1, -80 - 40),
	Position = UDim2.fromOffset(20, 80 + 20),
	BackgroundTransparency = 1,
	Parent = window,
})

local tabs = make("Frame", {
	Name = "Tabs",
	Size = UDim2.new(0, 150, 1, 0),
	BackgroundTransparency = 1,
	Parent = body,
}, {
	make("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }),
})

local grid = make("ScrollingFrame", {
	Name = "Grid",
	Size = UDim2.new(1, -150 - 16 - 276, 1, 0),
	Position = UDim2.fromOffset(166, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 8,
	ScrollBarImageColor3 = ORANGE_DARK,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = body,
}, {
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(150, 186),
		CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4) }),
})

local detail = make("Frame", {
	Name = "Detail",
	Size = UDim2.new(0, 260, 1, 0),
	Position = UDim2.new(1, 0, 0, 0),
	AnchorPoint = Vector2.new(1, 0),
	BackgroundColor3 = WHITE,
	Parent = body,
}, {
	corner(20),
	outline(INK, 3),
	make("UIPadding", {
		PaddingTop = UDim.new(0, 16),
		PaddingBottom = UDim.new(0, 16),
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
	}),
})

local toast = label({
	Name = "Toast",
	Text = "",
	Font = TITLE_FONT,
	TextSize = 26,
	TextColor3 = WHITE,
	BackgroundTransparency = 0,
	BackgroundColor3 = INK,
	AutomaticSize = Enum.AutomaticSize.X,
	Size = UDim2.fromOffset(0, 52),
	Position = UDim2.new(0.5, 0, 1, -40),
	AnchorPoint = Vector2.new(0.5, 1),
	Visible = false,
	Parent = gui,
}, {
	round(),
	make("UIPadding", { PaddingLeft = UDim.new(0, 28), PaddingRight = UDim.new(0, 28) }),
})

local toastToken = 0
local function showToast(text, color)
	toastToken += 1
	local token = toastToken
	toast.Text = text
	toast.BackgroundColor3 = color
	toast.Visible = true
	task.delay(2.5, function()
		if toastToken == token then
			toast.Visible = false
		end
	end)
end

-- ── Contents ─────────────────────────────────────────────────────────────────
local refresh

local function renderDetail()
	detail:ClearAllChildren()
	corner(20).Parent = detail
	outline(INK, 3).Parent = detail
	make("UIPadding", {
		PaddingTop = UDim.new(0, 16),
		PaddingBottom = UDim.new(0, 16),
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		Parent = detail,
	})
	local item = selected
	if not item then
		label({
			Text = "Pick something to see it here.",
			TextWrapped = true,
			TextSize = 18,
			TextColor3 = GREY,
			Size = UDim2.fromScale(1, 1),
			Parent = detail,
		})
		return
	end
	itemArt(item, UDim2.new(1, 0, 0, 150)).Parent = detail
	label({
		Name = "ItemName",
		Text = item.name,
		Font = TITLE_FONT,
		TextSize = 32,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 38),
		Position = UDim2.fromOffset(0, 160),
		Parent = detail,
	})
	label({
		Name = "Rarity",
		Text = string.upper(item.rarity),
		TextSize = 15,
		TextColor3 = RARITY_COLORS[item.rarity],
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 198),
		Parent = detail,
	})
	label({
		Name = "Description",
		Text = item.text,
		Font = Enum.Font.Gotham,
		TextSize = 17,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 48),
		Position = UDim2.fromOffset(0, 226),
		Parent = detail,
	})
	label({
		Name = "Stat",
		Text = item.stat,
		TextSize = 18,
		TextColor3 = GREEN_DARK,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.fromOffset(0, 280),
		Parent = detail,
	})

	local isOwned = owned[item.id]
	local holder, buy = chunkyButton({
		Name = "Buy",
		Text = if isOwned then "Owned" else "Buy for " .. formatNumber(item.price),
		TextSize = 26,
		Size = UDim2.new(1, 0, 0, 64),
		Position = UDim2.fromScale(0, 1),
		AnchorPoint = Vector2.new(0, 1),
		Parent = detail,
	}, if isOwned then GREY else GREEN, if isOwned then Color3.fromRGB(130, 120, 110) else GREEN_DARK)
	holder.Name = "Buy"
	if isOwned then
		return
	end
	buy.MouseButton1Click:Connect(function()
		local result = buyRemote:InvokeServer(item.id)
		if result and result.ok then
			showToast("You got " .. item.name .. "!", GREEN_DARK)
		else
			showToast(result and result.reason or "Something went wrong", RED)
		end
	end)
end

local function renderGrid()
	for _, child in grid:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local order = 0
	for _, item in ShopItems do
		if item.category ~= category then
			continue
		end
		order += 1
		local isSelected = selected == item
		local tile = make("TextButton", {
			Name = item.id,
			LayoutOrder = order,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = WHITE,
			Parent = grid,
		}, { corner(18), outline(if isSelected then ORANGE else INK, if isSelected then 5 else 3) })
		local art = itemArt(item, UDim2.new(1, -16, 0, 104))
		art.Position = UDim2.fromOffset(8, 8)
		art.Parent = tile
		local tag = label({
			Name = "Rarity",
			Text = string.upper(item.rarity),
			TextSize = 11,
			TextColor3 = WHITE,
			BackgroundTransparency = 0,
			BackgroundColor3 = RARITY_COLORS[item.rarity],
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 20),
			Position = UDim2.fromOffset(6, 6),
			Parent = art,
		}, { round(), make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) })
		tag.ZIndex = 2
		label({
			Name = "ItemName",
			Text = item.name,
			Font = TITLE_FONT,
			TextSize = 22,
			Size = UDim2.new(1, -16, 0, 26),
			Position = UDim2.fromOffset(8, 116),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = tile,
		})
		if owned[item.id] then
			label({
				Name = "Price",
				Text = "OWNED",
				TextSize = 16,
				TextColor3 = GREEN_DARK,
				Size = UDim2.new(1, -16, 0, 26),
				Position = UDim2.fromOffset(8, 146),
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = tile,
			})
		else
			coinIcon(22, UDim2.new(0, 8, 0, 159)).Parent = tile
			label({
				Name = "Price",
				Text = formatNumber(item.price),
				TextSize = 18,
				TextColor3 = if coins >= item.price then INK else RED,
				Size = UDim2.new(1, -44, 0, 26),
				Position = UDim2.fromOffset(36, 146),
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = tile,
			})
		end
		tile.MouseButton1Click:Connect(function()
			selected = item
			refresh()
		end)
	end
end

local tabButtons = {}
for index, name in CATEGORIES do
	local tab = make("TextButton", {
		Name = name,
		LayoutOrder = index,
		Text = name,
		Font = TITLE_FONT,
		TextSize = 24,
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 58),
		Parent = tabs,
	}, { corner(16) })
	outline(INK, 3).Parent = tab
	tabButtons[name] = tab
	tab.MouseButton1Click:Connect(function()
		category = name
		selected = firstIn(name)
		refresh()
	end)
end

function refresh()
	coinsLabel.Text = formatNumber(coins)
	for name, tab in tabButtons do
		local active = name == category
		tab.BackgroundColor3 = if active then ORANGE else WHITE
		tab.TextColor3 = if active then WHITE else INK
	end
	renderGrid()
	renderDetail()
end

local function setOpen(open)
	window.Visible = open
	if open then
		local scale = make("UIScale", { Scale = 0.9, Parent = window })
		local tween = TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		tween.Completed:Connect(function()
			scale:Destroy()
		end)
		tween:Play()
	end
end

shopButton.MouseButton1Click:Connect(function()
	setOpen(not window.Visible)
end)
closeButton.MouseButton1Click:Connect(function()
	setOpen(false)
end)

stateChanged.OnClientEvent:Connect(function(newCoins, ownedIds)
	coins = newCoins
	owned = {}
	for _, id in ownedIds do
		owned[id] = true
	end
	refresh()
end)

refresh()
