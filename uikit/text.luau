--[[
	Text measurement and line layout with the real Roblox font files (metrics from fonts.json).
	Layout decides every line break here, and the painter draws those exact lines, so what the
	UI code reads back (TextBounds, AutomaticSize) matches the picture.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Color3 = roblox.Color3

local Text = {}

local data
local widthTables = {}
local faceCache = {}
local warned = {}

local WEIGHTS = {
	Thin = 100,
	ExtraLight = 200,
	Light = 300,
	Regular = 400,
	Medium = 500,
	SemiBold = 600,
	Bold = 700,
	ExtraBold = 800,
	Heavy = 900,
}
Text.WEIGHTS = WEIGHTS

local MISSING_ADVANCE = 600 -- per-mille of an em for glyphs the face doesn't have

function Text.load(path: string)
	data = serde.decode("json", fs.readFile(path))
end

function Text.data()
	return data
end

local function widthTable(file: string)
	local t = widthTables[file]
	if t then
		return t
	end
	t = {}
	for start, list in data.files[file].widths do
		local base = tonumber(start)
		for i, w in list do
			t[base + i - 1] = w
		end
	end
	widthTables[file] = t
	return t
end

local function familyFaces(family: string)
	local faces = data.families[family]
	local hops = 0
	while type(faces) == "string" and hops < 4 do
		faces = data.families[faces]
		hops += 1
	end
	return faces
end

-- Family name from a Font (rbxasset://fonts/families/X.json -> X).
function Text.familyName(font): string
	local family = font.Family
	local name = string.match(family, "families/([%w_%-]+)%.json$")
	if name then
		return name
	end
	if not warned[family] then
		warned[family] = true
		print(`\27[33m[uikit] font family {family} isn't on disk; using Builder Sans\27[0m`)
	end
	return "BuilderSans"
end

-- Picks the on-disk face closest to the requested family / weight / style.
function Text.face(family: string, weight: number, italic: boolean)
	local key = `{family}|{weight}|{italic}`
	local cached = faceCache[key]
	if cached then
		return cached
	end
	local faces = familyFaces(family)
	if not faces then
		if not warned[family] then
			warned[family] = true
			print(`\27[33m[uikit] no local files for font family {family}; using Arimo\27[0m`)
		end
		faces = familyFaces("Arimo")
	end
	local best, bestScore = nil, math.huge
	for _, face in faces do
		local score = math.abs(face.weight - weight) * 2
		if face.weight < weight then
			score += 1 -- prefer the heavier face on ties
		end
		if (face.style == "italic") ~= italic then
			score += 10000
		end
		if score < bestScore then
			best, bestScore = face, score
		end
	end
	local result = {
		file = best.file,
		weight = best.weight,
		italic = italic,
		synthItalic = italic and best.style ~= "italic",
		cssName = "rbx_" .. string.gsub(best.file, "[^%w]", "_"),
		widths = widthTable(best.file),
		ascent = data.files[best.file].ascent,
		descent = data.files[best.file].descent,
	}
	faceCache[key] = result
	return result
end

function Text.faceForFont(font, boldOverride: boolean?)
	local weight = WEIGHTS[font.Weight.Name] or 400
	if boldOverride then
		weight = math.max(weight, 700)
	end
	return Text.face(Text.familyName(font), weight, font.Style.Name == "Italic")
end

function Text.measure(face, size: number, str: string): number
	local w = 0
	local widths = face.widths
	for _, code in utf8.codes(str) do
		w += widths[code] or MISSING_ADVANCE
	end
	return w * size / 1000
end

-- ── Rich text ─────────────────────────────────────────────────────────────────
local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", amp = "&" }

local function unescape(s: string): string
	return (string.gsub(s, "&(%a+);", function(name)
		return ENTITIES[name] or `&{name};`
	end))
end

local function parseColor(value: string?)
	if not value then
		return nil
	end
	local hex = string.match(value, "^#(%x+)$")
	if hex and (#hex == 6 or #hex == 3) then
		return Color3.fromHex(hex)
	end
	local r, g, b = string.match(value, "rgb%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)")
	if r then
		return Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
	end
	return nil
end

local function parseAttributes(s: string)
	local attrs = {}
	for key, value in string.gmatch(s, "([%w_]+)%s*=%s*\"([^\"]*)\"") do
		attrs[string.lower(key)] = value
	end
	for key, value in string.gmatch(s, "([%w_]+)%s*=%s*'([^']*)'") do
		attrs[string.lower(key)] = value
	end
	return attrs
end

local function faceFamilyFromEnumName(name: string): string?
	local ok, font = pcall(function()
		return roblox.Font.fromEnum((roblox.Enum.Font :: any)[name])
	end)
	if ok and font then
		return Text.familyName(font)
	end
	return nil
end

-- Style: { family, weight, italic, size, color, transparency, underline, strike, stroke, mark, upper, smallcaps }
local function parseRuns(text: string, base, rich: boolean)
	if not rich then
		return { { text = text, style = base } }
	end
	text = string.gsub(text, "<!%-%-.-%-%->", "")
	local runs = {}
	local stack = { base }
	local pos = 1
	local function top()
		return stack[#stack]
	end
	local function push(changes)
		local style = table.clone(top())
		for k, v in changes do
			style[k] = v
		end
		table.insert(stack, style)
	end
	local function emit(s: string)
		if s ~= "" then
			local style = top()
			s = unescape(s)
			if style.upper then
				s = string.upper(s)
			end
			table.insert(runs, { text = s, style = style })
		end
	end
	while pos <= #text do
		local s, e, closing, tag, rest = string.find(text, "<(/?)(%a+)([^>]*)>", pos)
		if not s then
			emit(string.sub(text, pos))
			break
		end
		emit(string.sub(text, pos, s - 1))
		pos = e + 1
		tag = string.lower(tag)
		if tag == "br" then
			table.insert(runs, { text = "\n", style = top() })
		elseif closing == "/" then
			if #stack > 1 then
				table.remove(stack)
			end
		else
			local attrs = parseAttributes(rest)
			if tag == "b" then
				push({ weight = math.max(top().weight, 700) })
			elseif tag == "i" then
				push({ italic = true })
			elseif tag == "u" then
				push({ underline = true })
			elseif tag == "s" then
				push({ strike = true })
			elseif tag == "uppercase" or tag == "uc" then
				push({ upper = true })
			elseif tag == "smallcaps" or tag == "sc" then
				push({ smallcaps = true })
			elseif tag == "font" then
				local changes = {}
				changes.color = parseColor(attrs.color)
				changes.size = tonumber(attrs.size)
				changes.transparency = tonumber(attrs.transparency)
				if attrs.face then
					changes.family = faceFamilyFromEnumName(attrs.face) or attrs.face
				end
				if attrs.family then
					changes.family = string.match(attrs.family, "families/([%w_%-]+)%.json") or changes.family
				end
				if attrs.weight then
					local w = tonumber(attrs.weight)
					if not w then
						for name, value in WEIGHTS do
							if string.lower(name) == string.lower(attrs.weight) then
								w = value
							end
						end
					end
					changes.weight = w
				end
				push(changes)
			elseif tag == "stroke" then
				push({
					stroke = {
						color = parseColor(attrs.color) or Color3.new(0, 0, 0),
						thickness = tonumber(attrs.thickness) or 1,
						transparency = tonumber(attrs.transparency) or 0,
					},
				})
			elseif tag == "mark" then
				push({ mark = { color = parseColor(attrs.color) or Color3.new(1, 1, 0), transparency = tonumber(attrs.transparency) or 0 } })
			else
				push({})
			end
			if string.match(rest, "/%s*$") and #stack > 1 then
				table.remove(stack) -- self-closing
			end
		end
	end
	return runs
end
Text.parseRuns = parseRuns

function Text.stripRich(text: string): string
	local runs = parseRuns(text, {}, true)
	local parts = {}
	for _, run in runs do
		table.insert(parts, run.text)
	end
	return table.concat(parts)
end

-- ── Line layout ───────────────────────────────────────────────────────────────
local function tokenize(runs, scale: number)
	local tokens = {}
	for _, run in runs do
		local style = run.style
		local face = Text.face(style.family, style.weight, style.italic)
		local size = style.size * scale
		local s = run.text
		local i = 1
		while i <= #s do
			local c = string.sub(s, i, i)
			local kind, j
			if c == "\n" then
				kind, j = "nl", i
			elseif string.match(c, "[ \t]") then
				kind = "space"
				j = (string.find(s, "[^ \t]", i) or #s + 1) - 1
			else
				kind = "word"
				j = (string.find(s, "[ \t\n]", i) or #s + 1) - 1
			end
			local piece = string.sub(s, i, j)
			table.insert(tokens, {
				kind = kind,
				text = piece,
				style = style,
				face = face,
				size = size,
				width = kind == "nl" and 0 or Text.measure(face, size, piece),
			})
			i = j + 1
		end
	end
	return tokens
end

local function splitWord(token, maxWidth: number)
	-- Breaks one over-long word into pieces that each fit (at least one character each).
	local pieces = {}
	local current, currentW = {}, 0
	for _, code in utf8.codes(token.text) do
		local ch = utf8.char(code)
		local w = Text.measure(token.face, token.size, ch)
		if currentW + w > maxWidth and #current > 0 then
			local text = table.concat(current)
			table.insert(pieces, { kind = "word", text = text, style = token.style, face = token.face, size = token.size, width = currentW })
			current, currentW = {}, 0
		end
		table.insert(current, ch)
		currentW += w
	end
	if #current > 0 then
		table.insert(pieces, { kind = "word", text = table.concat(current), style = token.style, face = token.face, size = token.size, width = currentW })
	end
	return pieces
end

local function newLine()
	return { items = {}, width = 0, size = 0 }
end

local function trimTrailing(line)
	while #line.items > 0 and line.items[#line.items].kind == "space" do
		local item = table.remove(line.items)
		line.width -= item.width
	end
end

local function breakLines(tokens, maxWidth: number, wrap: boolean, allowSplit: boolean, baseSize: number)
	local lines = {}
	local line = newLine()
	local afterWrap = false
	local overflowWord = false
	local function finish()
		if line.size == 0 then
			line.size = baseSize
		end
		table.insert(lines, line)
		line = newLine()
	end
	local queue = table.clone(tokens)
	local index = 1
	while index <= #queue do
		local token = queue[index]
		index += 1
		if token.kind == "nl" then
			line.size = math.max(line.size, token.size)
			finish()
			afterWrap = false
			continue
		end
		if token.kind == "space" and afterWrap and #line.items == 0 then
			continue
		end
		if wrap and token.kind == "word" and line.width + token.width > maxWidth + 0.01 then
			local hasWord = false
			for _, item in line.items do
				if item.kind == "word" then
					hasWord = true
				end
			end
			if hasWord then
				trimTrailing(line)
				finish()
				afterWrap = true
				index -= 1
				continue
			end
			if token.width > maxWidth + 0.01 then
				if allowSplit and utf8.len(token.text) > 1 then
					local pieces = splitWord(token, maxWidth)
					for k = #pieces, 1, -1 do
						table.insert(queue, index, pieces[k])
					end
					-- The first piece fits on this line; the rest flow to new lines.
					token = table.remove(queue, index)
					table.insert(line.items, token)
					line.width += token.width
					line.size = math.max(line.size, token.size)
					if index <= #queue and queue[index].kind == "word" then
						finish()
						afterWrap = true
					end
					continue
				end
				overflowWord = true
			end
		end
		table.insert(line.items, token)
		line.width += token.width
		line.size = math.max(line.size, token.size)
		afterWrap = false
	end
	finish()
	return lines, overflowWord
end

local function measureLines(lines, lineHeight: number)
	local w, h = 0, 0
	for _, line in lines do
		w = math.max(w, line.width)
		line.height = line.size * lineHeight
		h += line.height
	end
	return w, h
end

local ELLIPSIS = "…"

local function truncateLine(line, maxWidth: number)
	if line.width <= maxWidth + 0.01 or #line.items == 0 then
		return
	end
	local last = line.items[#line.items]
	local ellW = Text.measure(last.face, last.size, ELLIPSIS)
	while #line.items > 0 and line.width + ellW > maxWidth do
		local item = line.items[#line.items]
		local chars = {}
		for _, code in utf8.codes(item.text) do
			table.insert(chars, utf8.char(code))
		end
		if #chars <= 1 then
			table.remove(line.items)
			line.width -= item.width
		else
			table.remove(chars)
			local text = table.concat(chars)
			local w = Text.measure(item.face, item.size, text)
			line.width += w - item.width
			item.text, item.width = text, w
		end
	end
	trimTrailing(line)
	local style = #line.items > 0 and line.items[#line.items] or last
	table.insert(line.items, { kind = "word", text = ELLIPSIS, style = style.style, face = style.face, size = style.size, width = ellW })
	line.width += ellW
end

-- props: text, rich, family, weight, italic, size, lineHeight, wrapped, scaled, truncate,
--        minSize, maxSize, color, transparency
-- Returns { lines, width, height, size, fits, contentText }
function Text.layout(props, boxW: number, boxH: number)
	local base = {
		family = props.family,
		weight = props.weight,
		italic = props.italic,
		size = props.size,
		color = props.color,
		transparency = props.transparency,
	}
	local runs = parseRuns(props.text, base, props.rich)
	local lineHeight = props.lineHeight or 1

	local contentParts = {}
	for _, run in runs do
		table.insert(contentParts, run.text)
	end
	local contentText = table.concat(contentParts)

	local function attempt(size: number, allowSplit: boolean)
		local scale = size / props.size
		local tokens = tokenize(runs, scale)
		local lines, overflow = breakLines(tokens, boxW, props.wrapped or props.scaled, allowSplit, size)
		local w, h = measureLines(lines, lineHeight)
		return lines, w, h, overflow
	end

	local size = props.size
	local lines, w, h
	if props.scaled then
		local lo, hi = math.max(1, props.minSize or 1), math.min(100, props.maxSize or 100)
		local best = lo
		while lo <= hi do
			local mid = (lo + hi) // 2
			local l, lw, lh, overflow = attempt(mid, false)
			if not overflow and lw <= boxW + 0.5 and lh <= boxH + 0.5 then
				best = mid
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
		size = best
		lines, w, h = attempt(size, true)
	else
		lines, w, h = attempt(size, true)
	end

	local fits = w <= boxW + 0.5 and h <= boxH + 0.5
	if props.truncate and not fits then
		if not (props.wrapped or props.scaled) then
			for _, line in lines do
				truncateLine(line, boxW)
			end
		else
			local kept, used = {}, 0
			for _, line in lines do
				if used + line.height > boxH + 0.5 and #kept > 0 then
					break
				end
				table.insert(kept, line)
				used += line.height
			end
			if #kept < #lines then
				local last = kept[#kept]
				truncateLine(last, math.max(0, boxW - 1))
				if last.width + 1 <= boxW then
					-- truncateLine only trims when too wide; force the ellipsis on the cut line
					local tail = last.items[#last.items]
					if not tail or tail.text ~= ELLIPSIS then
						last.width = math.huge
						truncateLine(last, boxW)
					end
				end
			end
			lines = kept
		end
		w, h = measureLines(lines, lineHeight)
	end

	return { lines = lines, width = w, height = h, size = size, fits = fits, contentText = contentText }
end

-- TextService:GetTextSize equivalent.
function Text.getTextSize(text: string, size: number, font, frameSize, rich: boolean?)
	local face = Text.faceForFont(font)
	local result = Text.layout({
		text = text,
		rich = rich == true,
		family = Text.familyName(font),
		weight = face.weight,
		italic = face.italic,
		size = size,
		lineHeight = 1,
		wrapped = frameSize and frameSize.X < 1e8,
	}, frameSize and frameSize.X or math.huge, frameSize and frameSize.Y or math.huge)
	return roblox.Vector2.new(math.ceil(result.width), math.ceil(result.height))
end

return Text
