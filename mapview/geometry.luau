--[[
	Loads a model or place file and turns its visible parts into plain records the renderers use:
	world-space corners, bounds, colour, shape. Also finds the floor levels of a building.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3

local Geometry = {}

-- Place-file services whose contents are never part of the map.
local SKIP_IN_WORKSPACE = { Camera = true, Terrain = true }

-- Returns the instances to draw: the file's roots, or the instance at `path` ("Workspace.Map").
function Geometry.load(file: string, path: string?)
	local data = fs.readFile(file)
	-- Lune reads XML files only when they open with <roblox>; files written by other tools
	-- often start with an <?xml ...?> declaration first.
	data = string.gsub(data, "^%s*<%?xml.-%?>%s*", "")
	local lower = string.lower(file)
	local roots
	if string.match(lower, "%.rbxlx?$") then
		local game = roblox.deserializePlace(data)
		if path then
			roots = { game }
		else
			roots = {}
			for _, child in game:GetService("Workspace"):GetChildren() do
				if not SKIP_IN_WORKSPACE[child.ClassName] then
					table.insert(roots, child)
				end
			end
		end
	elseif string.match(lower, "%.rbxmx?$") then
		roots = roblox.deserializeModel(data)
	else
		error(`{file}: expected a .rbxm, .rbxmx, .rbxl or .rbxlx file`, 0)
	end
	if not path then
		return roots
	end
	local found
	local first = true
	for part in string.gmatch(path, "[^%.]+") do
		if first then
			first = false
			for _, root in roots do
				if root.ClassName == "DataModel" then
					found = root:FindFirstChild(part)
				elseif root.Name == part then
					found = root
				end
				if found then
					break
				end
			end
		else
			found = found and found:FindFirstChild(part)
		end
		if not found then
			error(`Nothing at {path} in {file}`, 0)
		end
	end
	return { found }
end

local function shapeOf(part): string
	local class = part.ClassName
	if class == "WedgePart" then
		return "Wedge"
	elseif class == "CornerWedgePart" then
		return "CornerWedge"
	elseif part:IsA("Part") then
		local ok, shape = pcall(function()
			return part.Shape.Name
		end)
		return if ok then shape else "Block"
	end
	return "Block" -- MeshParts and unions draw as their bounding box
end

-- Every visible BasePart under `roots`, with world corners and bounds.
function Geometry.collect(roots)
	local parts = {}
	local approximated = 0
	for _, root in roots do
		local list = root:GetDescendants()
		if root:IsA("BasePart") then
			table.insert(list, 1, root)
		end
		for _, d in list do
			if not d:IsA("BasePart") or d.ClassName == "NegateOperation" or d.Transparency >= 0.95 then
				continue
			end
			local cf, size = d.CFrame, d.Size
			local corners = {}
			local minX, minY, minZ = math.huge, math.huge, math.huge
			local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local c = cf * Vector3.new(sx * size.X / 2, sy * size.Y / 2, sz * size.Z / 2)
						table.insert(corners, c)
						minX, maxX = math.min(minX, c.X), math.max(maxX, c.X)
						minY, maxY = math.min(minY, c.Y), math.max(maxY, c.Y)
						minZ, maxZ = math.min(minZ, c.Z), math.max(maxZ, c.Z)
					end
				end
			end
			-- The ancestor directly under the drawn root names the group ("Kitchen", "Walls").
			local group = d
			while group.Parent and not table.find(roots, group.Parent) and group.Parent.ClassName ~= "Workspace" do
				group = group.Parent
			end
			local shape = shapeOf(d)
			if d:IsA("MeshPart") or d:IsA("PartOperation") then
				approximated += 1
			end
			table.insert(parts, {
				CFrame = cf,
				Size = size,
				Corners = corners,
				MinX = minX,
				MaxX = maxX,
				MinY = minY,
				MaxY = maxY,
				MinZ = minZ,
				MaxZ = maxZ,
				Color = d.Color,
				Transparency = d.Transparency,
				Material = d.Material.Name,
				Class = d.ClassName,
				Shape = shape,
				Name = d.Name,
				Group = group.Name,
				Instance = d,
			})
		end
	end
	return parts, approximated
end

-- Very large thin slabs (a Baseplate, a terrain stand-in) would swamp the framing.
local function isGround(part): boolean
	local dx, dy, dz = part.MaxX - part.MinX, part.MaxY - part.MinY, part.MaxZ - part.MinZ
	return dx * dz > 40000 and dy < 0.1 * math.min(dx, dz)
end
Geometry.isGround = isGround

-- The area to frame: everything but ground slabs and, unless `all`, distant scenery (parts
-- far outside where nearly all the others are, like a mountain backdrop). b.Outside counts
-- the parts left out of the framing; they are still drawn.
function Geometry.bounds(parts, all: boolean?)
	local b = { MinX = math.huge, MinY = math.huge, MinZ = math.huge, MaxX = -math.huge, MaxY = -math.huge, MaxZ = -math.huge, Outside = 0 }
	local function add(part)
		for _, key in { "X", "Y", "Z" } do
			b["Min" .. key] = math.min(b["Min" .. key], part["Min" .. key])
			b["Max" .. key] = math.max(b["Max" .. key], part["Max" .. key])
		end
	end
	local framed = {}
	for _, part in parts do
		if not isGround(part) then
			table.insert(framed, part)
		end
	end
	if #framed == 0 then
		framed = parts
	end
	local kept = framed
	if not all and #framed >= 20 then
		local xs, zs = {}, {}
		for _, part in framed do
			table.insert(xs, (part.MinX + part.MaxX) / 2)
			table.insert(zs, (part.MinZ + part.MaxZ) / 2)
		end
		table.sort(xs)
		table.sort(zs)
		local lo, hi = math.floor(#xs * 0.03) + 1, math.ceil(#xs * 0.97)
		local padX = (xs[hi] - xs[lo]) * 0.15 + 10
		local padZ = (zs[hi] - zs[lo]) * 0.15 + 10
		local x0, x1, z0, z1 = xs[lo] - padX, xs[hi] + padX, zs[lo] - padZ, zs[hi] + padZ
		kept = {}
		for _, part in framed do
			local cx, cz = (part.MinX + part.MaxX) / 2, (part.MinZ + part.MaxZ) / 2
			if cx >= x0 and cx <= x1 and cz >= z0 and cz <= z1 then
				table.insert(kept, part)
			end
		end
		b.Outside = #framed - #kept
	end
	for _, part in kept do
		add(part)
	end
	return b
end

-- Floor heights: the tops of large flat parts, clustered and weighted by area.
-- A level needs at least 12% of the biggest level's floor area to count.
function Geometry.levels(parts, bounds)
	local buckets = {}
	for _, part in parts do
		local dx, dy, dz = part.MaxX - part.MinX, part.MaxY - part.MinY, part.MaxZ - part.MinZ
		if dy <= 2.5 and dx * dz >= 64 then
			-- Clip ground slabs to the map so a baseplate doesn't outweigh every real floor.
			local area = math.max(0, math.min(part.MaxX, bounds.MaxX) - math.max(part.MinX, bounds.MinX))
				* math.max(0, math.min(part.MaxZ, bounds.MaxZ) - math.max(part.MinZ, bounds.MinZ))
			if area > 0 then
				table.insert(buckets, { y = part.MaxY, area = area })
			end
		end
	end
	table.sort(buckets, function(a, b)
		return a.y < b.y
	end)
	local clusters = {}
	for _, entry in buckets do
		local last = clusters[#clusters]
		if last and entry.y - last.top <= 3 then
			last.area += entry.area
			last.top = entry.y
			table.insert(last.entries, entry)
		else
			table.insert(clusters, { top = entry.y, area = entry.area, entries = { entry } })
		end
	end
	-- Within a cluster the floor is the highest surface with a real share of the area: a house
	-- floor sitting on a baseplate wins over the baseplate, a rug doesn't win over the floor.
	for _, c in clusters do
		local best = 0
		for _, entry in c.entries do
			best = math.max(best, entry.area)
		end
		for _, entry in c.entries do
			if entry.area >= best * 0.25 then
				c.y = entry.y
			end
		end
	end
	local biggest = 0
	for _, c in clusters do
		biggest = math.max(biggest, c.area)
	end
	local levels = {}
	for _, c in clusters do
		if c.area >= biggest * 0.12 then
			table.insert(levels, c.y)
		end
	end
	-- A floor less than 6 studs above the last is a raised platform or a ceiling slab, not a storey,
	-- and one with nothing wall-height standing on it is a roof.
	local function hasWalls(y: number): boolean
		for _, part in parts do
			if part.MinY >= y - 1 and part.MinY <= y + 1 and part.MaxY - part.MinY >= 4 then
				return true
			end
		end
		return false
	end
	local merged = {}
	for _, y in levels do
		if (#merged == 0 or y - merged[#merged] >= 6) and hasWalls(y) then
			table.insert(merged, y)
		end
	end
	if #merged == 0 then
		merged = { bounds.MinY }
	end
	while #merged > 8 do
		table.remove(merged)
	end
	local result = {}
	for index, y in merged do
		local ceiling = merged[index + 1] or (bounds.MaxY + 1)
		table.insert(result, { Id = tostring(index), Floor = y, Ceiling = ceiling })
	end
	return result
end

return Geometry
