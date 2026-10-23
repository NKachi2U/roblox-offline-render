--[[
	Offline map viewer (Lune). Renders a Roblox model or place file without Studio:
	floor plans of every level (SVG + PNG) and 3D views from outside and cut away per level (PNG),
	plus a text summary of what's in it.

	    lune run path/to/mapview/run.luau MyMap.rbxm
	    lune run path/to/mapview/run.luau place.rbxl --path Workspace.Map
	    lune run path/to/mapview/run.luau MyMap.rbxm --levels 0,16 --tags Door,Loot --size 1600x1000

	Outputs go to artifacts/mapview/<name>-*.png|svg|txt (change it with --out <dir>).
	Flags: --path <A.B.C>   draw only this instance (place files default to Workspace's children)
	       --levels <y,y>   floor heights, when the automatic ones are wrong
	       --tags <A,B>     mark parts with these CollectionService tags on the plans
	       --size WxH       3D view size (default 1400x900)
	       --views <json>   extra camera views: { "name": { eye, target, fov?, size?, ortho?, maxBottom? } }
	       --all            frame every part (by default distant scenery is left out of the framing)
	       --plans-only / --views-only   skip the other kind
	       --no-png         keep plans as SVG only (PNG conversion needs Chrome or Edge)
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Geometry = require("./geometry")
local Plan = require("./plan")
local Raster = require("./raster")
local Browser = require("../uikit/browser")

-- ── Paths ─────────────────────────────────────────────────────────────────────
local function normalize(path: string): string
	path = string.gsub(path, "\\", "/")
	local leading = if string.sub(path, 1, 1) == "/" then "/" else ""
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return leading .. table.concat(parts, "/")
end

local CWD = normalize(process.cwd)

local function absolute(path: string): string
	path = normalize(path)
	if string.match(path, "^%a:/") or string.sub(path, 1, 1) == "/" then
		return path
	end
	return normalize(`{CWD}/{path}`)
end

local function fileUrl(path: string): string
	return if string.sub(path, 1, 1) == "/" then `file://{path}` else `file:///{path}`
end

-- ── Arguments ─────────────────────────────────────────────────────────────────
local VALUE_FLAGS = { path = true, levels = true, tags = true, out = true, size = true, views = true }
local flags, positional = {}, {}
do
	local args = process.args
	local i = 1
	while i <= #args do
		local key = string.match(args[i], "^%-%-(.+)$")
		if key and VALUE_FLAGS[key] then
			flags[key] = args[i + 1]
			i += 2
		elseif key then
			flags[key] = true
			i += 1
		else
			table.insert(positional, args[i])
			i += 1
		end
	end
end

local file = positional[1]
if not file then
	print("usage: lune run <path>/mapview/run.luau <file.rbxm|.rbxmx|.rbxl|.rbxlx> [--path Workspace.Map] [--levels 0,16] [--tags A,B] [--size 1400x900]")
	process.exit(1)
end
file = absolute(file)
assert(fs.isFile(file), `{file} not found`)

local OUT_DIR = absolute(flags.out or "artifacts/mapview")
local name = if flags.path
	then string.match(flags.path, "([^%.]+)$")
	else string.gsub(string.match(file, "([^/]+)$"), "%.%w+$", "")
local viewW, viewH = 1400, 900
if flags.size then
	local w, h = string.match(flags.size, "^(%d+)x(%d+)$")
	assert(w, "--size must look like 1400x900")
	viewW, viewH = tonumber(w), tonumber(h)
end
local tags = {}
for tag in string.gmatch(flags.tags or "", "[^,]+") do
	table.insert(tags, tag)
end

-- ── Load ──────────────────────────────────────────────────────────────────────
local started = os.clock()
local ok, roots = pcall(Geometry.load, file, flags.path)
if not ok then
	print(`\27[31m[mapview] {roots}\27[0m`)
	process.exit(1)
end
local parts, approximated = Geometry.collect(roots)
if #parts == 0 then
	print("\27[31m[mapview] no visible parts to draw\27[0m")
	process.exit(1)
end
local bounds = Geometry.bounds(parts, flags.all == true)
local levels
if flags.levels then
	local ys = {}
	for y in string.gmatch(flags.levels, "[^,]+") do
		table.insert(ys, assert(tonumber(y), `--levels: {y} is not a number`))
	end
	table.sort(ys)
	levels = {}
	for index, y in ys do
		table.insert(levels, { Id = tostring(index), Floor = y, Ceiling = ys[index + 1] or (bounds.MaxY + 1) })
	end
else
	levels = Geometry.levels(parts, bounds)
end
print(string.format("[mapview] %s: %d parts, %d level(s), %.0f x %.0f x %.0f studs", name, #parts, #levels, bounds.MaxX - bounds.MinX, bounds.MaxY - bounds.MinY, bounds.MaxZ - bounds.MinZ))

if not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end
for _, entry in fs.readDir(OUT_DIR) do
	if string.sub(entry, 1, #name + 1) == name .. "-" then
		fs.removeFile(`{OUT_DIR}/{entry}`)
	end
end
local written = {}

-- ── Plans ─────────────────────────────────────────────────────────────────────
if not flags["views-only"] then
	local browser = not flags["no-png"] and Browser.find()
	if not flags["no-png"] and not browser then
		print("\27[33m[mapview] no Chrome/Edge found: plans are SVG only\27[0m")
	end
	for _, level in levels do
		local svg = `{OUT_DIR}/{name}-plan-{level.Id}.svg`
		local w, h = Plan.write(parts, bounds, level, { tags = tags }, svg)
		table.insert(written, svg)
		if browser then
			local png = string.gsub(svg, "%.svg$", ".png")
			local shot, err = pcall(Browser.screenshot, browser, `{OUT_DIR}/.browser-profile`, fileUrl(svg), png, w, h)
			if shot then
				table.insert(written, png)
			else
				print(`\27[31m[mapview] couldn't convert {svg}: {err}\27[0m`)
			end
		end
	end
	Browser.close()
end

-- ── 3D views ──────────────────────────────────────────────────────────────────
if not flags["plans-only"] then
	local center = { (bounds.MinX + bounds.MaxX) / 2, (bounds.MinY + bounds.MaxY) / 2, (bounds.MinZ + bounds.MaxZ) / 2 }
	local dx, dy, dz = bounds.MaxX - bounds.MinX, bounds.MaxY - bounds.MinY, bounds.MaxZ - bounds.MinZ
	local radius = math.sqrt(dx * dx + dy * dy + dz * dz) / 2
	local fov = 50
	local distance = radius / math.sin(math.rad(fov) / 2) * 0.95
	-- Compass directions: Roblox's -Z is north.
	local function from(sx: number, sz: number, target)
		local elevation, flat = math.rad(35), math.cos(math.rad(35)) * math.sqrt(0.5)
		return {
			target[1] + sx * flat * distance,
			target[2] + math.sin(elevation) * distance,
			target[3] + sz * flat * distance,
		}
	end
	local views = {
		{ name = "se", eye = from(1, 1, center), target = center },
		{ name = "nw", eye = from(-1, -1, center), target = center },
	}
	for _, level in levels do
		-- Lift off everything above this storey's walls (upper floors, the roof).
		local top = level.Floor + math.min(level.Ceiling - level.Floor, 10) - 0.3
		local target = { center[1], level.Floor, center[3] }
		table.insert(views, { name = `level{level.Id}`, eye = from(1, 1, target), target = target, maxBottom = top })
	end
	if flags.views then
		local custom = serde.decode("json", fs.readFile(absolute(flags.views)))
		for viewName, view in custom do
			view.name = viewName
			table.insert(views, view)
		end
	end
	-- A huge baseplate stays out of 3D views; it only hides the sky and costs time.
	local function exclude(part)
		return Geometry.isGround(part)
	end
	for _, view in views do
		view.size = view.size or { viewW, viewH }
		view.fov = view.fov or fov
		view.exclude = exclude
		local path = `{OUT_DIR}/{name}-view-{view.name}.png`
		local t0 = os.clock()
		local count = Raster.render(parts, view, path)
		table.insert(written, path)
		print(string.format("[mapview] %s (%d triangles, %.1fs)", path, count, os.clock() - t0))
	end
end

-- ── Summary ───────────────────────────────────────────────────────────────────
local lines = {}
local function line(text: string)
	table.insert(lines, text)
end
line(`{file}{if flags.path then " at " .. flags.path else ""}`)
line(string.format("Parts drawn: %d%s", #parts, if approximated > 0 then string.format(" (%d MeshParts/unions drawn as their bounding boxes)", approximated) else ""))
if bounds.Outside > 0 then
	line(`{bounds.Outside} parts lie far outside the rest (scenery?) and are left out of the framing; --all includes them`)
end
line(string.format("Bounds: X %.1f..%.1f (%.0f), Y %.1f..%.1f (%.0f), Z %.1f..%.1f (%.0f)", bounds.MinX, bounds.MaxX, bounds.MaxX - bounds.MinX, bounds.MinY, bounds.MaxY, bounds.MaxY - bounds.MinY, bounds.MinZ, bounds.MaxZ, bounds.MaxZ - bounds.MinZ))
line("Levels:")
for _, level in levels do
	line(string.format("  %s: floor y=%.1f, next floor or top y=%.1f", level.Id, level.Floor, level.Ceiling))
end

local groups, order = {}, {}
local tagCounts = {}
local prompts, spawns = {}, {}
for _, part in parts do
	local g = groups[part.Group]
	if not g then
		g = { count = 0, minX = math.huge, minY = math.huge, minZ = math.huge, maxX = -math.huge, maxY = -math.huge, maxZ = -math.huge }
		groups[part.Group] = g
		table.insert(order, part.Group)
	end
	g.count += 1
	g.minX, g.maxX = math.min(g.minX, part.MinX), math.max(g.maxX, part.MaxX)
	g.minY, g.maxY = math.min(g.minY, part.MinY), math.max(g.maxY, part.MaxY)
	g.minZ, g.maxZ = math.min(g.minZ, part.MinZ), math.max(g.maxZ, part.MaxZ)
	for _, tag in part.Instance:GetTags() do
		tagCounts[tag] = (tagCounts[tag] or 0) + 1
	end
	local p = part.CFrame.Position
	if part.Class == "SpawnLocation" then
		table.insert(spawns, string.format("  %s at (%.0f, %.0f, %.0f)", part.Name, p.X, p.Y, p.Z))
	end
	for _, child in part.Instance:GetChildren() do
		if child.ClassName == "ProximityPrompt" then
			local text = child.ActionText ~= "" and child.ActionText or child.ObjectText
			table.insert(prompts, string.format("  \"%s\" on %s at (%.0f, %.0f, %.0f)", text, part.Name, p.X, p.Y, p.Z))
		end
	end
end
line(`Groups ({#order}):`)
for index, groupName in order do
	if index > 60 then
		line(`  ... and {#order - 60} more`)
		break
	end
	local g = groups[groupName]
	line(string.format("  %s: %d parts, %.0f x %.0f x %.0f at (%.0f, %.0f, %.0f)", groupName, g.count, g.maxX - g.minX, g.maxY - g.minY, g.maxZ - g.minZ, (g.minX + g.maxX) / 2, g.minY, (g.minZ + g.maxZ) / 2))
end
if #spawns > 0 then
	line(`Spawns ({#spawns}):`)
	for _, text in spawns do
		line(text)
	end
end
if #prompts > 0 then
	line(`Prompts ({#prompts}):`)
	for _, text in prompts do
		line(text)
	end
end
if next(tagCounts) then
	local list = {}
	for tag, count in tagCounts do
		table.insert(list, `{tag} ({count})`)
	end
	table.sort(list)
	line(`Tags: {table.concat(list, ", ")}`)
end
line("Files:")
for _, path in written do
	line(`  {path}`)
end
local summary = `{OUT_DIR}/{name}-summary.txt`
fs.writeFile(summary, table.concat(lines, "\n") .. "\n")
print(`[mapview] {summary}`)
print(string.format("[mapview] done in %.1fs", os.clock() - started))
process.exit(0)
