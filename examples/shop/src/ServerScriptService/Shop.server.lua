-- Keeps each player's coins and owned items, and handles purchases from the shop menu.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShopItems = require(ReplicatedStorage.ShopItems)

local START_COINS = 1250

local remotes = Instance.new("Folder")
remotes.Name = "ShopRemotes"

local buy = Instance.new("RemoteFunction")
buy.Name = "Buy"
buy.Parent = remotes

local stateChanged = Instance.new("RemoteEvent")
stateChanged.Name = "StateChanged"
stateChanged.Parent = remotes

remotes.Parent = ReplicatedStorage

local itemsById = {}
for _, item in ShopItems do
	itemsById[item.id] = item
end

local wallets = {}

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

local function ownedList(wallet)
	local list = {}
	for id in wallet.owned do
		table.insert(list, id)
	end
	return list
end

local function onPlayerAdded(player)
	local wallet = { coins = START_COINS, owned = { blob = true } }
	wallets[player] = wallet
	stateChanged:FireClient(player, wallet.coins, ownedList(wallet))
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
Players.PlayerRemoving:Connect(function(player)
	wallets[player] = nil
end)

buy.OnServerInvoke = function(player, itemId)
	local wallet = wallets[player]
	local item = itemsById[itemId]
	if not wallet or not item then
		return { ok = false, reason = "That item isn't for sale" }
	end
	if wallet.owned[itemId] then
		return { ok = false, reason = "You already own " .. item.name }
	end
	if wallet.coins < item.price then
		return { ok = false, reason = "You need " .. formatNumber(item.price - wallet.coins) .. " more coins" }
	end
	wallet.coins -= item.price
	wallet.owned[itemId] = true
	stateChanged:FireClient(player, wallet.coins, ownedList(wallet))
	return { ok = true }
end
