--[[
	Builds fonts.json (glyph advances per font file) from the fonts that ship with the local
	Roblox install. run.luau calls this the first time, and again with --rebuild-fonts (worth doing
	after a Roblox update if text starts measuring oddly).

	The renderer measures and wraps text in Luau so AbsoluteSize / TextBounds match what the UI code
	sees in-game, and the painter draws with the same font files, so both need the real advances.
	Reads the TrueType/OpenType tables directly: head, hhea, hmtx, cmap.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Content = require("./content")

local Fonts = {}

-- Roblox retired Gotham and serves these families from other files; the family JSONs no longer ship.
local ALIASES = {
	GothamSSm = "Montserrat",
	Gotham = "Montserrat",
	Arial = "Arimo",
	SourceSans = "SourceSansPro",
	Highway = "HighwayGothic",
}

local function u16(data: string, at: number): number
	return (string.unpack(">I2", data, at + 1))
end

local function i16(data: string, at: number): number
	return (string.unpack(">i2", data, at + 1))
end

local function u32(data: string, at: number): number
	return (string.unpack(">I4", data, at + 1))
end

local function tables(data: string)
	local list = {}
	local count = u16(data, 4)
	for index = 0, count - 1 do
		local record = 12 + index * 16
		list[string.sub(data, record + 1, record + 4)] = u32(data, record + 8)
	end
	return list
end

-- Codepoint -> glyph id for the BMP, from the best Unicode cmap subtable (same order as fontTools).
local function readCmap(data: string, cmap: number): { [number]: number }
	local subtables = {}
	for index = 0, u16(data, cmap + 2) - 1 do
		local record = cmap + 4 + index * 8
		subtables[`{u16(data, record)}/{u16(data, record + 2)}`] = cmap + u32(data, record + 4)
	end
	local map = {}
	for _, key in { "3/10", "0/6", "0/4", "3/1", "0/3", "0/2", "0/1", "0/0" } do
		local at = subtables[key]
		if not at then
			continue
		end
		local format = u16(data, at)
		if format == 4 then
			local segments = u16(data, at + 6) // 2
			local ends = at + 14
			local starts = ends + segments * 2 + 2
			local deltas = starts + segments * 2
			local ranges = deltas + segments * 2
			for s = 0, segments - 1 do
				local first, last = u16(data, starts + s * 2), u16(data, ends + s * 2)
				local delta, rangeOffset = i16(data, deltas + s * 2), u16(data, ranges + s * 2)
				for code = first, last do
					if code == 0xFFFF then
						continue
					end
					local glyph
					if rangeOffset == 0 then
						glyph = (code + delta) % 65536
					else
						local glyphAt = ranges + s * 2 + rangeOffset + (code - first) * 2
						glyph = u16(data, glyphAt)
						if glyph ~= 0 then
							glyph = (glyph + delta) % 65536
						end
					end
					if glyph ~= 0 then
						map[code] = glyph
					end
				end
			end
			return map
		elseif format == 12 then
			for g = 0, u32(data, at + 12) - 1 do
				local group = at + 16 + g * 12
				local first, last, glyph = u32(data, group), u32(data, group + 4), u32(data, group + 8)
				for code = first, math.min(last, 0xFFFF) do
					map[code] = glyph + (code - first)
				end
			end
			return map
		end
	end
	return map
end

local function faceMetrics(path: string)
	local data = fs.readFile(path)
	local t = tables(data)
	local upem = u16(data, t.head + 18)
	local metricsCount = u16(data, t.hhea + 34)
	local function advance(glyph: number): number
		return u16(data, t.hmtx + math.min(glyph, metricsCount - 1) * 4)
	end
	local codes = {}
	local widths = {}
	for code, glyph in readCmap(data, t.cmap) do
		table.insert(codes, code)
		widths[code] = math.round(advance(glyph) * 1000 / upem)
	end
	table.sort(codes)
	-- Stored as compact runs: {start: [w, w, ...]} over contiguous codepoints.
	local runs, start, current = {}, nil, {}
	for _, code in codes do
		if start and code == start + #current then
			table.insert(current, widths[code])
		else
			if start then
				runs[tostring(start)] = current
			end
			start, current = code, { widths[code] }
		end
	end
	if start then
		runs[tostring(start)] = current
	end
	return {
		ascent = math.round(i16(data, t.hhea + 4) * 1000 / upem),
		descent = math.round(-i16(data, t.hhea + 6) * 1000 / upem),
		widths = runs,
	}
end

function Fonts.build(outPath: string)
	local content = Content.dir()
	if not content then
		error(
			"No Roblox install found, so there are no fonts to measure text with. Install Roblox Studio, "
				.. "or set ROBLOX_CONTENT_DIR to a folder that has fonts/families inside it.",
			0
		)
	end
	local fonts = `{content}/fonts`
	local families, files = {}, {}
	local familyFiles = {}
	for _, entry in fs.readDir(`{fonts}/families`) do
		if string.match(entry, "%.json$") then
			table.insert(familyFiles, entry)
		end
	end
	table.sort(familyFiles)
	local familyCount, fileCount = 0, 0
	for _, entry in familyFiles do
		local ok, family = pcall(serde.decode, "json", fs.readFile(`{fonts}/families/{entry}`))
		if not ok or type(family) ~= "table" or type(family.faces) ~= "table" then
			continue
		end
		local faces = {}
		for _, face in family.faces do
			local rel = string.match(face.assetId or "", "^rbxasset://fonts/(.+)$")
			-- Faces without an rbxasset:// path are downloaded on demand by the client; not on disk.
			if rel and fs.isFile(`{fonts}/{rel}`) then
				table.insert(faces, { weight = face.weight, style = face.style, file = rel })
				if not files[rel] then
					local okFace, metrics = pcall(faceMetrics, `{fonts}/{rel}`)
					if okFace then
						files[rel] = metrics
						fileCount += 1
					else
						table.remove(faces)
					end
				end
			end
		end
		if #faces > 0 then
			families[string.gsub(entry, "%.json$", "")] = faces
			familyCount += 1
		end
	end
	for alias, target in ALIASES do
		if families[target] and not families[alias] then
			families[alias] = target
		end
	end
	fs.writeFile(outPath, serde.encode("json", { families = families, files = files }))
	print(`[uikit] wrote {outPath} ({familyCount} families, {fileCount} font files) from {fonts}`)
end

return Fonts
