--[[
	Builds SampleHouse.rbxm: a small two-storey house to try mapview on.

	    lune run examples/maps/build-sample.luau
	    lune run mapview/run.luau examples/maps/SampleHouse.rbxm --tags Loot
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Instance, Vector3, CFrame, Color3, Enum = roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Color3, roblox.Enum

local WALL_H = 14
local FLOOR2 = 15 -- top of the upper floor slab
local DOOR_W, DOOR_H = 6, 9

local map = Instance.new("Model")
map.Name = "SampleHouse"

local function group(name: string, parent)
	local folder = Instance.new("Model")
	folder.Name = name
	folder.Parent = parent or map
	return folder
end

local function part(parent, name: string, size, position, color, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = if typeof(position) == "CFrame" then position else CFrame.new(position)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	for key, value in props or {} do
		p[key] = value
	end
	p.Parent = parent
	return p
end

local function box(parent, name, x0, y0, z0, x1, y1, z1, color, props)
	return part(parent, name, Vector3.new(x1 - x0, y1 - y0, z1 - z0), Vector3.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), color, props)
end

local function prompt(target, action: string)
	local p = Instance.new("ProximityPrompt")
	p.ActionText = action
	p.Parent = target
end

local WALL = Color3.fromRGB(226, 214, 196)
local TRIM = Color3.fromRGB(120, 86, 60)
local FLOOR_WOOD = Color3.fromRGB(176, 128, 84)
local TILE = Color3.fromRGB(200, 206, 210)
local GLASS = Color3.fromRGB(150, 200, 230)

-- A straight wall along X or Z with openings: { at = distance along the wall, width, bottom, top, glass? }.
local function wall(parent, name, x0, z0, x1, z1, y, height, openings)
	local alongX = z0 == z1
	local length = if alongX then x1 - x0 else z1 - z0
	local thick = 1
	local function piece(a, b, bottom, top, color, props)
		if b - a < 0.05 or top - bottom < 0.05 then
			return
		end
		if alongX then
			box(parent, name, x0 + a, y + bottom, z0 - thick / 2, x0 + b, y + top, z0 + thick / 2, color, props)
		else
			box(parent, name, x0 - thick / 2, y + bottom, z0 + a, x0 + thick / 2, y + top, z0 + b, color, props)
		end
	end
	table.sort(openings or {}, function(a, b)
		return a.at < b.at
	end)
	local cursor = 0
	for _, o in openings or {} do
		local a, b = o.at - o.width / 2, o.at + o.width / 2
		piece(cursor, a, 0, height, WALL)
		piece(a, b, 0, o.bottom, WALL)
		piece(a, b, o.top, height, WALL)
		if o.glass then
			piece(a, b, o.bottom, o.top, GLASS, { Transparency = 0.55, Material = Enum.Material.Glass })
		end
		cursor = b
	end
	piece(cursor, length, 0, height, WALL)
end

local function door(parent, x, z, alongX, y)
	-- A door standing half open in its frame.
	local hinge = if alongX then Vector3.new(x - DOOR_W / 2, y + DOOR_H / 2, z) else Vector3.new(x, y + DOOR_H / 2, z - DOOR_W / 2)
	local turn = if alongX then CFrame.Angles(0, math.rad(-55), 0) else CFrame.Angles(0, math.rad(35), 0)
	local slab = part(parent, "Door", Vector3.new(DOOR_W - 0.4, DOOR_H - 0.2, 0.4), CFrame.new(hinge) * turn * CFrame.new(DOOR_W / 2, 0, 0), TRIM)
	slab:AddTag("Door")
	return slab
end

local function doorway(at)
	return { at = at, width = DOOR_W, bottom = 0, top = DOOR_H }
end

local function window(at)
	return { at = at, width = 8, bottom = 4, top = 10, glass = true }
end

-- Ground and spawn.
local outside = group("Outside")
part(outside, "Baseplate", Vector3.new(320, 2, 320), Vector3.new(0, -2, 0), Color3.fromRGB(106, 160, 84), { Material = Enum.Material.Grass })
box(outside, "Path", -24, -1.05, 30, -16, -0.95, 60, Color3.fromRGB(170, 160, 150))
local spawn = Instance.new("SpawnLocation")
spawn.Name = "Spawn"
spawn.Anchored = true
spawn.Size = Vector3.new(8, 1, 8)
spawn.CFrame = CFrame.new(-20, -0.5, 52)
spawn.Color = Color3.fromRGB(90, 140, 220)
spawn.Parent = outside

-- Shell: floors, outer walls, roof.
local shell = group("Shell")
box(shell, "GroundFloor", -40, -1, -30, 40, 0, 30, FLOOR_WOOD)
-- Upper floor with a hole over the stairs (x -38..-30, z -14..20).
box(shell, "UpperFloor", -30, FLOOR2 - 1, -30, 40, FLOOR2, 30, FLOOR_WOOD)
box(shell, "UpperFloor", -40, FLOOR2 - 1, -30, -30, FLOOR2, -14, FLOOR_WOOD)
box(shell, "UpperFloor", -40, FLOOR2 - 1, 20, -30, FLOOR2, 30, FLOOR_WOOD)
for _, y in { 0, FLOOR2 } do
	local h = if y == 0 then FLOOR2 - 1 else WALL_H
	wall(shell, "OuterWall", -40, 30, 40, 30, y, h, if y == 0 then { doorway(20), window(45), window(65) } else { window(20), window(45), window(65) })
	wall(shell, "OuterWall", -40, -30, 40, -30, y, h, { window(15), window(40), window(65) })
	wall(shell, "OuterWall", -40, -30, -40, 30, y, h, if y == 0 then {} else { window(30) })
	wall(shell, "OuterWall", 40, -30, 40, 30, y, h, { window(15), window(45) })
end
box(shell, "Roof", -41, FLOOR2 + WALL_H, -31, 41, FLOOR2 + WALL_H + 1, 31, Color3.fromRGB(90, 70, 64))
for _, side in { { -41, -31, 41, -30 }, { -41, 30, 41, 31 }, { -41, -31, -40, 31 }, { 40, -31, 41, 31 } } do
	box(shell, "Parapet", side[1], FLOOR2 + WALL_H + 1, side[2], side[3], FLOOR2 + WALL_H + 3, side[4], Color3.fromRGB(90, 70, 64))
end
door(shell, -20, 30, true, 0)
prompt(shell:FindFirstChild("Door"), "Open")

-- Ground floor rooms.
local lobby = group("Lobby")
wall(lobby, "Wall", 0, -30, 0, 30, 0, FLOOR2 - 1, { doorway(15), doorway(45) })
door(lobby, 0, -15, false, 0)
door(lobby, 0, 15, false, 0)
box(lobby, "Desk", -22, 0, -20, -10, 3.5, -16, TRIM)
prompt(box(lobby, "Bell", -16.5, 3.5, -18.5, -15.5, 4.2, -17.5, Color3.fromRGB(230, 190, 60)), "Ring")
box(lobby, "Couch", -26, 0, 4, -14, 3, 8, Color3.fromRGB(70, 110, 160))
box(lobby, "Rug", -26, 0, -4, -10, 0.1, 2, Color3.fromRGB(170, 60, 60))
-- Stairs up the west wall, one stud per step.
for step = 0, FLOOR2 - 1 do
	box(lobby, "Step", -38, 0, 20 - (step + 1) * 2.2, -31, step + 1, 20 - step * 2.2, Color3.fromRGB(150, 110, 76))
end

local kitchen = group("Kitchen")
wall(kitchen, "Wall", 0, 0, 40, 0, 0, FLOOR2 - 1, { doorway(20) })
door(kitchen, 20, 0, true, 0)
box(kitchen, "Floor", 0, 0, -30, 40, 0.05, 0, TILE)
box(kitchen, "Counter", 2, 0, -29, 38, 4, -25, Color3.fromRGB(90, 90, 96))
prompt(box(kitchen, "Fridge", 32, 0, -24, 38, 9, -19, Color3.fromRGB(235, 235, 240)), "Open")
box(kitchen, "Table", 12, 0, -16, 24, 3.2, -8, TRIM)

local storage = group("Storage")
for index, spot in { { 8, 8 }, { 14, 8 }, { 8, 14 }, { 30, 22 }, { 34, 22 } } do
	local crate = box(storage, `Crate{index}`, spot[1] - 2.5, 0, spot[2] - 2.5, spot[1] + 2.5, 5, spot[2] + 2.5, Color3.fromRGB(160, 120, 70), { Material = Enum.Material.WoodPlanks })
	crate:AddTag("Loot")
	prompt(crate, "Search")
end
box(storage, "Shelf", 38, 0, 4, 39.5, 10, 26, Color3.fromRGB(110, 110, 110))

-- Upper floor rooms.
local office = group("Office")
wall(office, "Wall", 0, -30, 0, 30, FLOOR2, WALL_H, { doorway(15), doorway(45) })
door(office, 0, -15, false, FLOOR2)
door(office, 0, 15, false, FLOOR2)
box(office, "Railing", -30, FLOOR2, -14, -29.5, FLOOR2 + 3.5, 20, TRIM)
local desk = box(office, "Desk", -22, FLOOR2, 18, -8, FLOOR2 + 3.5, 24, TRIM)
prompt(desk, "Use computer")
box(office, "Monitor", -17, FLOOR2 + 3.5, 22, -13, FLOOR2 + 6.5, 22.6, Color3.fromRGB(30, 30, 34), { Material = Enum.Material.Neon })
box(office, "Bookcase", -39, FLOOR2, -28, -33, FLOOR2 + 10, -26, Color3.fromRGB(100, 70, 50))

local bedroom = group("Bedroom")
wall(bedroom, "Wall", 0, 0, 40, 0, FLOOR2, WALL_H, { doorway(20) })
door(bedroom, 20, 0, true, FLOOR2)
box(bedroom, "Bed", 24, FLOOR2, -28, 38, FLOOR2 + 2.5, -18, Color3.fromRGB(200, 200, 230))
box(bedroom, "Pillow", 34, FLOOR2 + 2.5, -27, 37, FLOOR2 + 3.2, -19, WALL)
box(bedroom, "Wardrobe", 2, FLOOR2, -29, 10, FLOOR2 + 11, -25, Color3.fromRGB(110, 76, 56))

local bath = group("Bathroom")
box(bath, "Floor", 0, FLOOR2, 0, 40, FLOOR2 + 0.05, 30, TILE)
local tub = Instance.new("Part")
tub.Name = "Tub"
tub.Anchored = true
tub.Shape = Enum.PartType.Cylinder
tub.Size = Vector3.new(3, 8, 8)
tub.CFrame = CFrame.new(32, FLOOR2 + 1.5, 22) * CFrame.Angles(0, 0, math.rad(90))
tub.Color = Color3.fromRGB(240, 240, 245)
tub.Parent = bath

local out = "examples/maps/SampleHouse.rbxm"
fs.writeFile(out, roblox.serializeModel({ map }))
print(`wrote {out}`)
