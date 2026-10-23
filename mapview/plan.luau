--[[
	Floor plans as SVG: a horizontal section through each level, like an architect's plan.
	  - floor surfaces at the level's height are drawn faintly in their own colour
	  - anything crossing the cut line (walls, tall furniture) is drawn solid with an outline
	  - shorter things on the floor (tables, crates) are drawn lighter
	  - a 10-stud grid and scale bar, so distances and door widths can be read off the image
	  - markers: SpawnLocations (blue), ProximityPrompts (yellow, with their action text),
	    parts with a requested CollectionService tag (magenta), and group names
]]

local fs = require("@lune/fs")

local Geometry = require("./geometry")

local Plan = {}

local function hex(color): string
	return string.format(
		"#%02x%02x%02x",
		math.clamp(math.floor(color.R * 255 + 0.5), 0, 255),
		math.clamp(math.floor(color.G * 255 + 0.5), 0, 255),
		math.clamp(math.floor(color.B * 255 + 0.5), 0, 255)
	)
end

local function shade(color, factor: number): string
	return hex({ R = math.min(1, color.R * factor), G = math.min(1, color.G * factor), B = math.min(1, color.B * factor) })
end

local function escape(text: string): string
	return (string.gsub(text, "[<>&\"]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" }))
end

-- Convex hull (monotone chain) of 2D points {x, y}.
local function hull(points)
	table.sort(points, function(a, b)
		return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
	end)
	local function cross(o, a, b)
		return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
	end
	local lower, upper = {}, {}
	for _, p in points do
		while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do
			table.remove(lower)
		end
		table.insert(lower, p)
	end
	for index = #points, 1, -1 do
		local p = points[index]
		while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do
			table.remove(upper)
		end
		table.insert(upper, p)
	end
	table.remove(lower)
	table.remove(upper)
	for _, p in upper do
		table.insert(lower, p)
	end
	return lower
end

local function polygon(points, fill: string, opacity: number, stroke: string?): string
	local coords = {}
	for _, p in points do
		table.insert(coords, string.format("%.1f,%.1f", p[1], p[2]))
	end
	return string.format(
		'<polygon points="%s" fill="%s" fill-opacity="%.2f"%s/>',
		table.concat(coords, " "),
		fill,
		opacity,
		if stroke then string.format(' stroke="%s" stroke-width="0.6"', stroke) else ""
	)
end

-- Writes one level's plan; returns its pixel size.
function Plan.write(parts, bounds, level, opts, path: string): (number, number)
	local floorY, ceiling = level.Floor, level.Ceiling
	local cutY = floorY + math.min(4, (ceiling - floorY) / 2)
	local margin = 12
	local x0, z0 = bounds.MinX - margin, bounds.MinZ - margin
	local x1, z1 = bounds.MaxX + margin, bounds.MaxZ + margin
	local scale = math.min(8, 2000 / math.max(x1 - x0, z1 - z0))
	local width, height = math.ceil((x1 - x0) * scale), math.ceil((z1 - z0) * scale)
	local footer = 88
	local function px(x, z)
		return { (x - x0) * scale, (z - z0) * scale }
	end
	local out = {
		string.format(
			'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" style="background:#1b1d22;font-family:Segoe UI,Helvetica,Arial,sans-serif">',
			width,
			height + footer,
			width,
			height + footer
		),
		string.format('<clipPath id="map"><rect width="%d" height="%d"/></clipPath><g clip-path="url(#map)">', width, height),
	}

	-- Grid: every 10 studs, stronger every 50.
	for gx = math.ceil(x0 / 10) * 10, x1, 10 do
		local p = px(gx, z0)
		table.insert(out, string.format('<line x1="%.1f" y1="0" x2="%.1f" y2="%d" stroke="#ffffff" stroke-opacity="%.2f" stroke-width="1"/>', p[1], p[1], height, if gx % 50 == 0 then 0.12 else 0.05))
	end
	for gz = math.ceil(z0 / 10) * 10, z1, 10 do
		local p = px(x0, gz)
		table.insert(out, string.format('<line x1="0" y1="%.1f" x2="%d" y2="%.1f" stroke="#ffffff" stroke-opacity="%.2f" stroke-width="1"/>', p[2], width, p[2], if gz % 50 == 0 then 0.12 else 0.05))
	end

	local floors, low, tall = {}, {}, {}
	for _, part in parts do
		if part.MaxY > floorY - 0.45 and part.MaxY < floorY + 0.45 then
			table.insert(floors, part)
		elseif part.MinY <= cutY and part.MaxY > floorY + 0.3 and part.MinY < ceiling then
			if part.MaxY >= cutY then
				table.insert(tall, part)
			elseif part.MaxY >= cutY - 3.2 then
				table.insert(low, part)
			end
		end
	end
	local function footprint(part)
		local pts = {}
		for _, c in part.Corners do
			table.insert(pts, px(c.X, c.Z))
		end
		return hull(pts)
	end
	for _, part in floors do
		table.insert(out, polygon(footprint(part), hex(part.Color), if Geometry.isGround(part) then 0.3 else 0.55))
	end
	table.sort(low, function(a, b)
		return a.MaxY < b.MaxY
	end)
	for _, part in low do
		table.insert(out, polygon(footprint(part), hex(part.Color), 0.8))
	end
	for _, part in tall do
		table.insert(out, polygon(footprint(part), shade(part.Color, 0.8), 0.95 - part.Transparency * 0.5, "#000000"))
	end

	-- Labels that would overlap one already drawn are left off (the marker still shows).
	local placed = {}
	local function claim(x: number, y: number, text: string, size: number, centered: boolean): boolean
		local w = #text * size * 0.58
		local left = if centered then x - w / 2 else x
		local box = { left - 2, y - size, left + w + 2, y + 3 }
		for _, other in placed do
			if box[1] < other[3] and box[3] > other[1] and box[2] < other[4] and box[4] > other[2] then
				return false
			end
		end
		table.insert(placed, box)
		return true
	end

	local function onLevel(y: number): boolean
		return y >= floorY - 1 and y < ceiling - 0.5
	end

	-- Group names at the middle of each group that sits on this level (skipped for groups
	-- spanning most of the map, like a "Walls" folder).
	local groups = {}
	for _, part in parts do
		if onLevel(part.MinY) or (part.MinY < floorY and part.MaxY > floorY + 1) then
			local g = groups[part.Group]
			if not g then
				g = { MinX = math.huge, MinZ = math.huge, MaxX = -math.huge, MaxZ = -math.huge, Count = 0 }
				groups[part.Group] = g
			end
			g.MinX, g.MaxX = math.min(g.MinX, part.MinX), math.max(g.MaxX, part.MaxX)
			g.MinZ, g.MaxZ = math.min(g.MinZ, part.MinZ), math.max(g.MaxZ, part.MaxZ)
			g.Count += 1
		end
	end
	local mapArea = (bounds.MaxX - bounds.MinX) * (bounds.MaxZ - bounds.MinZ)
	local labels = {}
	for name, g in groups do
		if (g.MaxX - g.MinX) * (g.MaxZ - g.MinZ) < mapArea * 0.4 then
			table.insert(labels, { name = name, x = (g.MinX + g.MaxX) / 2, z = (g.MinZ + g.MaxZ) / 2 })
		end
	end
	if #labels <= 80 then
		for _, label in labels do
			local p = px(label.x, label.z)
			if not claim(p[1], p[2], label.name, 13, true) then
				continue
			end
			table.insert(out, string.format('<text x="%.1f" y="%.1f" fill="#ffffff" fill-opacity="0.9" font-size="13" text-anchor="middle" stroke="#000" stroke-width="3" paint-order="stroke">%s</text>', p[1], p[2], escape(label.name)))
		end
	end

	-- Markers.
	local wanted = {}
	for _, tag in opts.tags or {} do
		wanted[tag] = true
	end
	-- One marker and one label per part: "Search [Loot]" for a tagged part with a prompt.
	local counts = { spawns = 0, prompts = 0, tagged = 0 }
	for _, part in parts do
		local inst = part.Instance
		local position = part.CFrame.Position
		if not onLevel(position.Y - part.Size.Y / 2) then
			continue
		end
		local p = px(position.X, position.Z)
		if part.Class == "SpawnLocation" then
			counts.spawns += 1
			table.insert(out, string.format('<circle cx="%.1f" cy="%.1f" r="7" fill="#3aa0ff" stroke="#fff" stroke-width="1.5"/>', p[1], p[2]))
		end
		local texts = {}
		local hasPrompt = false
		for _, child in inst:GetChildren() do
			if child.ClassName == "ProximityPrompt" then
				hasPrompt = true
				counts.prompts += 1
				local text = child.ActionText ~= "" and child.ActionText or child.ObjectText
				if text ~= "" then
					table.insert(texts, text)
				end
			end
		end
		local tagged = {}
		if next(wanted) then
			for _, tag in inst:GetTags() do
				if wanted[tag] then
					table.insert(tagged, tag)
				end
			end
		end
		if #tagged > 0 then
			counts.tagged += 1
			table.insert(texts, `[{table.concat(tagged, ", ")}]`)
			table.insert(out, string.format('<rect x="%.1f" y="%.1f" width="12" height="12" fill="#ff4fd8" stroke="#fff" stroke-width="1"/>', p[1] - 6, p[2] - 6))
		end
		if hasPrompt then
			table.insert(out, string.format('<rect x="%.1f" y="%.1f" width="9" height="9" transform="rotate(45 %.1f %.1f)" fill="#ffd400" stroke="#000" stroke-width="1"/>', p[1] - 4.5, p[2] - 4.5, p[1], p[2]))
		end
		if #texts > 0 and claim(p[1] + 10, p[2] + 4, table.concat(texts, " "), 12, false) then
			local color = if hasPrompt then "#ffe680" else "#ffb3f0"
			table.insert(out, string.format('<text x="%.1f" y="%.1f" fill="%s" font-size="12" stroke="#000" stroke-width="2.5" paint-order="stroke">%s</text>', p[1] + 10, p[2] + 4, color, escape(table.concat(texts, " "))))
		end
	end
	table.insert(out, "</g>")

	-- Footer: scale bar and key.
	local bar = 50 * scale
	local fy = height + 20
	table.insert(out, string.format('<line x1="14" y1="%d" x2="%.1f" y2="%d" stroke="#ddd" stroke-width="3"/>', fy, 14 + bar, fy))
	table.insert(out, string.format('<text x="14" y="%d" fill="#ddd" font-size="12">50 studs</text>', fy + 18))
	local key = {}
	if counts.spawns > 0 then
		table.insert(key, "Blue = spawns.")
	end
	if counts.prompts > 0 then
		table.insert(key, "Yellow = prompts.")
	end
	if counts.tagged > 0 then
		table.insert(key, "Magenta = tagged.")
	end
	table.insert(out, string.format('<text x="%.1f" y="%d" fill="#ddd" font-size="13">Level %s: floor y=%.1f, cut at y=%.1f</text>', 30 + bar, fy + 4, level.Id, floorY, cutY))
	table.insert(out, string.format('<text x="%.1f" y="%d" fill="#aaa" font-size="12">Outlined = crosses the cut (walls). Lighter = lower objects. Grid = 10 studs.</text>', 30 + bar, fy + 24))
	if #key > 0 then
		table.insert(out, string.format('<text x="%.1f" y="%d" fill="#aaa" font-size="12">%s</text>', 30 + bar, fy + 44, escape(table.concat(key, " "))))
	end
	table.insert(out, "</svg>")
	fs.writeFile(path, table.concat(out, "\n"))
	return width, height + footer
end

return Plan
