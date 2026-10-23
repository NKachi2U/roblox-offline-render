--[[
	Turns the laid-out GUI into a standalone HTML page (fonts embedded) that headless Chrome
	screenshots. Every element is absolutely positioned from layout.luau's results and every
	text line is placed exactly where the layout broke it, so the browser only paints.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Content = require("./content")

local Enum = roblox.Enum

local Paint = {}

local Runtime, STATE, Layout, Text

function Paint.init(runtime, layout, text)
	Runtime = runtime
	STATE = runtime.STATE
	Layout = layout
	Text = text
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64chars = {}
for i = 1, 64 do
	b64chars[i - 1] = string.byte(B64, i)
end

local function base64(data: string): string
	local n = #data
	local src = buffer.fromstring(data)
	local out = buffer.create(((n + 2) // 3) * 4)
	local o = 0
	for i = 0, n - 1, 3 do
		local a = buffer.readu8(src, i)
		local b = i + 1 < n and buffer.readu8(src, i + 1) or 0
		local c = i + 2 < n and buffer.readu8(src, i + 2) or 0
		local v = a * 65536 + b * 256 + c
		buffer.writeu8(out, o, b64chars[(v // 262144) % 64])
		buffer.writeu8(out, o + 1, b64chars[(v // 4096) % 64])
		buffer.writeu8(out, o + 2, i + 1 < n and b64chars[(v // 64) % 64] or 61)
		buffer.writeu8(out, o + 3, i + 2 < n and b64chars[v % 64] or 61)
		o += 4
	end
	return buffer.tostring(out)
end
Paint.base64 = base64

local function px(v: number): string
	return string.format("%.2fpx", v)
end

local function rgba(color, transparency: number?): string
	local alpha = 1 - (transparency or 0)
	return string.format(
		"rgba(%d,%d,%d,%.3f)",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255),
		math.clamp(alpha, 0, 1)
	)
end

local function escapeHtml(s: string): string
	return (string.gsub(s, "[<>&\"]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" }))
end

local function content(): string?
	return Content.dir()
end

-- ── Images ────────────────────────────────────────────────────────────────────
local imageCache = {}

local function pngSize(data: string)
	if string.sub(data, 2, 4) ~= "PNG" then
		return nil
	end
	local w = string.unpack(">I4", data, 17)
	local h = string.unpack(">I4", data, 21)
	return w, h
end

local MIME = { png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", webp = "image/webp", gif = "image/gif" }

-- Resolves an Image string to { uri, w, h } or nil when the asset isn't available offline.
local function resolveImage(image: string)
	if image == "" then
		return nil
	end
	if imageCache[image] ~= nil then
		return imageCache[image] or nil
	end
	local path
	local localPath = string.match(image, "^rbxasset://(.+)$")
	if localPath and content() then
		path = `{content()}/{localPath}`
	end
	local id = string.match(image, "^rbxassetid://(%d+)") or string.match(image, "[?&]id=(%d+)") or string.match(image, "^(%d+)$")
	if id then
		for _, dir in Paint.assetDirs do
			for _, ext in { "png", "jpg", "jpeg", "webp", "gif" } do
				local candidate = `{dir}/{id}.{ext}`
				if fs.isFile(candidate) then
					path = candidate
					break
				end
			end
			if path then
				break
			end
		end
	end
	local result = false
	if path and fs.isFile(path) then
		local data = fs.readFile(path)
		local ext = string.lower(string.match(path, "%.(%w+)$") or "png")
		local w, h = pngSize(data)
		result = { uri = `data:{MIME[ext] or "image/png"};base64,{base64(data)}`, w = w, h = h }
	else
		table.insert(Paint.missingImages, image)
	end
	imageCache[image] = result
	return result or nil
end

-- ── Element styling ───────────────────────────────────────────────────────────
local function modifierList(inst)
	local strokes, corner, gradient = {}, nil, nil
	for _, child in STATE[inst].children do
		local class = STATE[child].class
		if class == "UIStroke" and child.Enabled then
			table.insert(strokes, child)
		elseif class == "UICorner" then
			corner = corner or child
		elseif class == "UIGradient" and child.Enabled then
			gradient = gradient or child
		end
	end
	return strokes, corner, gradient
end

local function gradientCss(gradient, baseColor, baseTransparency: number): string
	-- Roblox multiplies the gradient colour with the object's colour and combines transparencies.
	local times = {}
	local seen = {}
	for _, kp in gradient.Color.Keypoints do
		if not seen[kp.Time] then
			seen[kp.Time] = true
			table.insert(times, kp.Time)
		end
	end
	for _, kp in gradient.Transparency.Keypoints do
		if not seen[kp.Time] then
			seen[kp.Time] = true
			table.insert(times, kp.Time)
		end
	end
	table.sort(times)
	local function colorAt(t)
		local kps = gradient.Color.Keypoints
		for i = 1, #kps - 1 do
			local a, b = kps[i], kps[i + 1]
			if t >= a.Time and t <= b.Time then
				local alpha = b.Time > a.Time and (t - a.Time) / (b.Time - a.Time) or 0
				return a.Value:Lerp(b.Value, alpha)
			end
		end
		return kps[#kps].Value
	end
	local function transparencyAt(t)
		local kps = gradient.Transparency.Keypoints
		for i = 1, #kps - 1 do
			local a, b = kps[i], kps[i + 1]
			if t >= a.Time and t <= b.Time then
				local alpha = b.Time > a.Time and (t - a.Time) / (b.Time - a.Time) or 0
				return a.Value + (b.Value - a.Value) * alpha
			end
		end
		return kps[#kps].Value
	end
	local offset = gradient.Offset
	local stops = {}
	for _, t in times do
		local c = colorAt(t)
		local mixed = roblox.Color3.new(c.R * baseColor.R, c.G * baseColor.G, c.B * baseColor.B)
		local tr = 1 - (1 - baseTransparency) * (1 - transparencyAt(t))
		table.insert(stops, `{rgba(mixed, tr)} {string.format("%.2f", (t + offset.X) * 100)}%`)
	end
	return `linear-gradient({90 + gradient.Rotation}deg, {table.concat(stops, ", ")})`
end

local function cornerRadius(corner, w: number, h: number, s: number): number
	if not corner then
		return 0
	end
	local r = corner.CornerRadius
	return math.min(r.Scale * math.min(w, h) + r.Offset * s, math.min(w, h) / 2)
end

local function styleString(t): string
	local parts = {}
	for _, kv in t do
		table.insert(parts, `{kv[1]}:{kv[2]}`)
	end
	return table.concat(parts, ";")
end

local usedFaces = {}

local function textHtml(inst, a, strokes)
	local layout = STATE[inst].text
	if not layout or not a.textBox then
		return ""
	end
	local s = a.s
	local box = a.textBox
	local bx, by, bw, bh = box[1] * s, box[2] * s, box[3] * s, box[4] * s
	local xAlign, yAlign = inst.TextXAlignment, inst.TextYAlignment
	local blockH = layout.height * s
	local y = by
	if yAlign == Enum.TextYAlignment.Center then
		y = by + (bh - blockH) / 2
	elseif yAlign == Enum.TextYAlignment.Bottom then
		y = by + bh - blockH
	end

	local textStroke
	for _, stroke in strokes do
		if stroke.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
			textStroke = { color = stroke.Color, thickness = stroke.Thickness * s, transparency = stroke.Transparency }
		end
	end
	if not textStroke and inst.TextStrokeTransparency < 1 then
		textStroke = { color = inst.TextStrokeColor3, thickness = 1 * s, transparency = inst.TextStrokeTransparency }
	end

	local baseTransparency = inst.TextTransparency
	local out = {}
	for _, line in layout.lines do
		local lw, lh = line.width * s, line.height * s
		local x = bx
		if xAlign == Enum.TextXAlignment.Center then
			x = bx + (bw - lw) / 2
		elseif xAlign == Enum.TextXAlignment.Right then
			x = bx + bw - lw
		end
		local spans = {}
		local i = 1
		while i <= #line.items do
			local item = line.items[i]
			local text = item.text
			local j = i + 1
			while j <= #line.items and line.items[j].style == item.style and line.items[j].face == item.face and line.items[j].size == item.size do
				text ..= line.items[j].text
				j += 1
			end
			i = j
			local face = item.face
			usedFaces[face.file] = face
			local st = item.style
			local transparency = 1 - (1 - baseTransparency) * (1 - (st.transparency or 0))
			local css = {
				{ "font-family", `'{face.cssName}'` },
				{ "font-size", px(item.size * s) },
				{ "color", rgba(st.color, transparency) },
			}
			if face.synthItalic then
				table.insert(css, { "font-style", "italic" })
			end
			local decorations = {}
			if st.underline then
				table.insert(decorations, "underline")
			end
			if st.strike then
				table.insert(decorations, "line-through")
			end
			if #decorations > 0 then
				table.insert(css, { "text-decoration", table.concat(decorations, " ") })
			end
			local stroke = st.stroke or textStroke
			if stroke then
				table.insert(css, { "-webkit-text-stroke", `{px(stroke.thickness * 2 * (st.stroke and s or 1))} {rgba(stroke.color, 1 - (1 - stroke.transparency) * (1 - transparency))}` })
				table.insert(css, { "paint-order", "stroke fill" })
			end
			if st.mark then
				table.insert(css, { "background", rgba(st.mark.color, st.mark.transparency) })
			end
			if st.smallcaps then
				table.insert(css, { "font-variant", "small-caps" })
			end
			table.insert(spans, `<span style="{styleString(css)}">{escapeHtml(text)}</span>`)
		end
		table.insert(out, `<div class="ln" style="left:{px(x)};top:{px(y)};height:{px(lh)};line-height:{px(lh)}">{table.concat(spans)}</div>`)
		y += lh
	end
	return table.concat(out)
end

local function imageCss(inst, a, css)
	local image = inst.Image
	if STATE[inst].class == "ImageButton" and inst.HoverImage ~= "" and STATE[inst].hovered then
		image = inst.HoverImage
	end
	if image == "" then
		return nil
	end
	local resolved = resolveImage(image)
	local tint = inst.ImageColor3
	local transparency = inst.ImageTransparency
	if not resolved then
		-- Placeholder: hatched box in the tint colour, labelled with the asset.
		local label = string.match(image, "(%d+)") or image
		return `<div class="img missing" style="background:repeating-linear-gradient(45deg,{rgba(tint, 0.55 + transparency * 0.45)} 0 6px,{rgba(tint, 0.85 + transparency * 0.15)} 6px 12px);outline:1px dashed {rgba(tint, 0.3 + transparency * 0.7)}"><span>{escapeHtml(label)}</span></div>`
	end
	local size, position, repeatMode = "100% 100%", "center", "no-repeat"
	local scaleType = inst.ScaleType
	local rectSize, rectOffset = inst.ImageRectSize, inst.ImageRectOffset
	if rectSize.X > 0 and rectSize.Y > 0 and resolved.w then
		local sx, sy = a.w / rectSize.X, a.h / rectSize.Y
		size = `{px(resolved.w * sx)} {px(resolved.h * sy)}`
		position = `{px(-rectOffset.X * sx)} {px(-rectOffset.Y * sy)}`
	elseif scaleType == Enum.ScaleType.Fit then
		size = "contain"
	elseif scaleType == Enum.ScaleType.Crop then
		size = "cover"
	elseif scaleType == Enum.ScaleType.Tile then
		local tile = inst.TileSize
		size = `{px(tile.X.Scale * a.w + tile.X.Offset * a.s)} {px(tile.Y.Scale * a.h + tile.Y.Offset * a.s)}`
		position = "0 0"
		repeatMode = "repeat"
	elseif scaleType == Enum.ScaleType.Slice and resolved.w then
		local c = inst.SliceCenter
		local scale = inst.SliceScale * a.s
		local t, l = c.Min.Y, c.Min.X
		local r, b = resolved.w - c.Max.X, resolved.h - c.Max.Y
		return `<div class="img" style="border-style:solid;border-width:{px(t * scale)} {px(r * scale)} {px(b * scale)} {px(l * scale)};border-image:url({resolved.uri}) {t} {r} {b} {l} fill stretch;opacity:{1 - transparency}"></div>`
	end
	local isWhite = tint.R > 0.999 and tint.G > 0.999 and tint.B > 0.999
	local bg = `url({resolved.uri})`
	local styles = {
		{ "background-image", bg },
		{ "background-size", size },
		{ "background-position", position },
		{ "background-repeat", repeatMode },
		{ "opacity", string.format("%.3f", 1 - transparency) },
	}
	if not isWhite then
		-- Multiply by the tint but keep the image's alpha.
		table.insert(styles, { "background-color", rgba(tint) })
		table.insert(styles, { "background-blend-mode", "multiply" })
		for _, prefix in { "-webkit-mask", "mask" } do
			table.insert(styles, { `{prefix}-image`, bg })
			table.insert(styles, { `{prefix}-size`, size })
			table.insert(styles, { `{prefix}-position`, position })
			table.insert(styles, { `{prefix}-repeat`, repeatMode })
		end
	end
	return `<div class="img" style="{styleString(styles)}"></div>`
end

local function elementHtml(entry, opts)
	local inst = entry.inst
	local a = entry.abs
	local s = STATE[inst]
	local class = s.class
	local strokes, corner, gradient = modifierList(inst)
	local css = {
		{ "left", px(a.x) },
		{ "top", px(a.y) },
		{ "width", px(a.w) },
		{ "height", px(a.h) },
	}
	local radius = cornerRadius(corner, a.w, a.h, a.s)
	if radius > 0 then
		table.insert(css, { "border-radius", px(radius) })
	end
	local bgT = inst.BackgroundTransparency
	if bgT < 1 then
		if gradient then
			table.insert(css, { "background", gradientCss(gradient, inst.BackgroundColor3, bgT) })
		else
			table.insert(css, { "background", rgba(inst.BackgroundColor3, bgT) })
		end
	end
	local shadows = {}
	local border = inst.BorderSizePixel
	if border > 0 and bgT < 1 then
		local mode = inst.BorderMode
		local color = rgba(inst.BorderColor3, bgT)
		if mode == Enum.BorderMode.Inset then
			table.insert(shadows, `inset 0 0 0 {px(border * a.s)} {color}`)
		elseif mode == Enum.BorderMode.Middle then
			table.insert(shadows, `0 0 0 {px(border * a.s / 2)} {color}`)
			table.insert(shadows, `inset 0 0 0 {px(border * a.s / 2)} {color}`)
		else
			table.insert(shadows, `0 0 0 {px(border * a.s)} {color}`)
		end
	end
	local isText = Layout.isTextObject(inst)
	for _, stroke in strokes do
		local mode = stroke.ApplyStrokeMode
		if mode == Enum.ApplyStrokeMode.Border or not isText then
			local thickness = stroke.Thickness * a.s
			local color = rgba(stroke.Color, stroke.Transparency)
			local position = STATE[stroke].props.BorderStrokePosition
			local posName = position and position.Name or "Outer"
			if posName == "Inner" then
				table.insert(shadows, `inset 0 0 0 {px(thickness)} {color}`)
			elseif posName == "Center" then
				table.insert(shadows, `0 0 0 {px(thickness / 2)} {color}`)
				table.insert(shadows, `inset 0 0 0 {px(thickness / 2)} {color}`)
			else
				table.insert(shadows, `0 0 0 {px(thickness)} {color}`)
			end
		end
	end
	if #shadows > 0 then
		table.insert(css, { "box-shadow", table.concat(shadows, ", ") })
	end
	if a.rot ~= 0 then
		table.insert(css, { "transform", `rotate({a.rot}deg)` })
	end
	if entry.opacity < 1 then
		table.insert(css, { "opacity", string.format("%.3f", entry.opacity) })
	end
	if inst.ClipsDescendants and isText then
		table.insert(css, { "overflow", "hidden" })
	end
	if opts.outline then
		table.insert(css, { "outline", "1px solid rgba(255,0,200,0.55)" })
	end

	local inner = {}
	if class == "ImageLabel" or class == "ImageButton" then
		local img = imageCss(inst, a, css)
		if img then
			table.insert(inner, img)
		end
	elseif class == "ViewportFrame" then
		-- Hatch only when the frame paints its own background; a transparent one shows what's behind.
		local hatch = inst.BackgroundTransparency < 1 and "" or " clear"
		table.insert(inner, `<div class="vpf{hatch}"><span>3D · ViewportFrame</span></div>`)
	elseif class == "VideoFrame" then
		table.insert(inner, `<div class="vpf"><span>VideoFrame</span></div>`)
	end
	if isText then
		table.insert(inner, textHtml(inst, a, strokes))
	end
	if opts.outline then
		table.insert(inner, `<i class="tag">{escapeHtml(inst.Name)}</i>`)
	end

	local path = escapeHtml(Runtime.methods.GetFullName(inst))
	local html = `<div class="n" data-path="{path}" title="{path} [{class}]" style="{styleString(css)}">{table.concat(inner)}</div>`
	if entry.clip then
		-- Local coordinates inside the clip wrapper.
		local c = entry.clip
		local w, h = math.max(0, c[3] - c[1]), math.max(0, c[4] - c[2])
		html = string.gsub(html, "left:[%d%.%-]+px;top:[%d%.%-]+px", `left:{px(a.x - c[1])};top:{px(a.y - c[2])}`, 1)
		html = `<div class="clip" style="left:{px(c[1])};top:{px(c[2])};width:{px(w)};height:{px(h)}">{html}</div>`
	end
	return html
end

local function scrollbarHtml(entry)
	local inst = entry.inst
	local a = entry.abs
	local sc = a.scroll
	local out = {}
	local thickness = inst.ScrollBarThickness * a.s
	local color = rgba(inst.ScrollBarImageColor3, inst.ScrollBarImageTransparency)
	if sc.barY then
		local trackH = sc.winH
		local thumbH = math.max(thickness, trackH * trackH / sc.canvasH)
		local top = (sc.posY * a.s) / math.max(1, sc.canvasH - sc.winH) * (trackH - thumbH)
		local left = inst.VerticalScrollBarPosition == Enum.VerticalScrollBarPosition.Left and a.x or (a.x + a.w - thickness)
		table.insert(out, `<div class="n" style="left:{px(left)};top:{px(a.y + top)};width:{px(thickness)};height:{px(thumbH)};background:{color}"></div>`)
	end
	if sc.barX then
		local trackW = sc.winW
		local thumbW = math.max(thickness, trackW * trackW / sc.canvasW)
		local left = (sc.posX * a.s) / math.max(1, sc.canvasW - sc.winW) * (trackW - thumbW)
		table.insert(out, `<div class="n" style="left:{px(a.x + left)};top:{px(a.y + a.h - thickness)};width:{px(thumbW)};height:{px(thickness)};background:{color}"></div>`)
	end
	local html = table.concat(out)
	if entry.clip and html ~= "" then
		local c = entry.clip
		html = string.gsub(html, "left:([%d%.%-]+)px;top:([%d%.%-]+)px", function(x, y)
			return `left:{px(tonumber(x) - c[1])};top:{px(tonumber(y) - c[2])}`
		end)
		html = `<div class="clip" style="left:{px(c[1])};top:{px(c[2])};width:{px(c[3] - c[1])};height:{px(c[4] - c[2])}">{html}</div>`
	end
	return html
end

-- The Roblox top bar buttons, drawn faintly so collisions with the UI are visible.
local function topbarHtml(): string
	local inset = Runtime.topInset
	local size = inset - 14
	local y = 7
	local items = {}
	for _, x in { 12, 12 + size + 12 } do
		table.insert(items, `<div class="tb" style="left:{x}px;top:{y}px;width:{size}px;height:{size}px"></div>`)
	end
	return table.concat(items)
end

-- Folders searched for <id>.png when an image is rbxassetid://<id>; run.luau fills it in.
Paint.assetDirs = {}
Paint.missingImages = {}

-- opts: outline, topbar (default true), backdrop (image path), title
function Paint.html(opts): string
	opts = opts or {}
	usedFaces = {}
	local list = Layout.drawList()
	local body = {}
	local pendingBars = {}
	local function flushBars(depth)
		while #pendingBars > 0 and pendingBars[#pendingBars].depth >= depth do
			table.insert(body, scrollbarHtml(table.remove(pendingBars)))
		end
	end
	for _, entry in list do
		flushBars(entry.depth)
		table.insert(body, elementHtml(entry, opts))
		local sc = entry.abs.scroll
		if sc and (sc.barX or sc.barY) and entry.inst.ScrollBarThickness > 0 then
			table.insert(pendingBars, entry)
		end
	end
	flushBars(-1)

	local fontsDir = content() and `{content()}/fonts`
	local faces = {}
	for file, face in usedFaces do
		if fontsDir and fs.isFile(`{fontsDir}/{file}`) then
			local ext = string.match(file, "%.(%w+)$")
			local format = ext == "otf" and "opentype" or "truetype"
			table.insert(faces, `@font-face\{font-family:'{face.cssName}';src:url(data:font/{ext};base64,{base64(fs.readFile(`{fontsDir}/{file}`))}) format('{format}');font-weight:normal;font-style:normal\}`)
		end
	end

	local vp = Runtime.viewport
	local backdrop = "background:radial-gradient(ellipse at 50% 40%, #3a3f47 0%, #1d2025 60%, #121417 100%)"
	if opts.backdrop and fs.isFile(opts.backdrop) then
		local ext = string.lower(string.match(opts.backdrop, "%.(%w+)$") or "png")
		backdrop = `background:#000 url(data:{MIME[ext] or "image/png"};base64,{base64(fs.readFile(opts.backdrop))}) center/cover no-repeat`
	end

	return table.concat({
		"<!doctype html><html><head><meta charset=\"utf-8\">",
		`<title>{escapeHtml(opts.title or "uikit render")}</title><style>`,
		table.concat(faces, "\n"),
		`html,body\{margin:0;padding:0;overflow:hidden\}`,
		`body\{width:{vp.X}px;height:{vp.Y}px;position:relative;{backdrop};font-kerning:none;text-rendering:geometricPrecision;-webkit-font-smoothing:antialiased\}`,
		`.n,.clip,.ln,.img,.vpf,.tb\{position:absolute;box-sizing:border-box\}`,
		`.clip\{overflow:hidden\}`,
		`.ln\{white-space:pre;font-synthesis:style\}`,
		`.img,.vpf\{inset:0;border-radius:inherit\}`,
		`.img.missing span\{position:absolute;left:3px;top:2px;font:10px monospace;color:#fff;background:rgba(0,0,0,.55);padding:0 3px;max-width:calc(100% - 6px);overflow:hidden\}`,
		`.vpf\{background:repeating-linear-gradient(135deg,rgba(255,255,255,.035) 0 10px,rgba(255,255,255,.07) 10px 20px)\}`,
		`.vpf.clear\{background:none\}`,
		`.vpf span\{position:absolute;right:4px;bottom:3px;font:9px monospace;color:rgba(255,255,255,.35);letter-spacing:.06em\}`,
		`.tag\{position:absolute;left:0;top:0;font:9px monospace;font-style:normal;color:#fff;background:rgba(255,0,200,.55);padding:0 2px;white-space:nowrap\}`,
		`.tb\{position:absolute;border-radius:10px;background:rgba(18,18,21,.55);outline:1px solid rgba(255,255,255,.18)\}`,
		"</style></head><body>",
		table.concat(body, "\n"),
		opts.topbar == false and "" or topbarHtml(),
		"</body></html>",
	})
end

return Paint
