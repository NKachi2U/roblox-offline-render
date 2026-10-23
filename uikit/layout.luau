--[[
	Roblox GUI layout, re-implemented: UDim2 sizing/positioning, AnchorPoint, SizeConstraint,
	UIScale, UIPadding, UIListLayout (incl. wrapping and flex), UIGridLayout, AutomaticSize,
	ScrollingFrame canvases, UIAspectRatioConstraint / UISizeConstraint / UITextSizeConstraint,
	and text layout. Results live in STATE[inst].abs and back the Absolute* properties.

	Coordinates: each object lays out its children in its own "units"; a frame {x0, y0, s}
	maps units to screen pixels (s only differs from 1 under a UIScale).
]]

local roblox = require("@lune/roblox")

local Enum = roblox.Enum
local Vector2 = roblox.Vector2

local Layout = {}

local Runtime, STATE, Text

function Layout.init(runtime, text)
	Runtime = runtime
	STATE = runtime.STATE
	Text = text
end

local gen = 0

local function modifiers(inst)
	local mods = {}
	for _, child in STATE[inst].children do
		local cs = STATE[child]
		local class = cs.class
		if class == "UIPadding" then
			mods.padding = mods.padding or child
		elseif class == "UIListLayout" or class == "UIGridLayout" or class == "UIPageLayout" or class == "UITableLayout" then
			mods.layout = mods.layout or child
		elseif class == "UIScale" then
			mods.scale = mods.scale or child
		elseif class == "UIAspectRatioConstraint" then
			mods.aspect = mods.aspect or child
		elseif class == "UISizeConstraint" then
			mods.sizeC = mods.sizeC or child
		elseif class == "UITextSizeConstraint" then
			mods.textC = mods.textC or child
		elseif class == "UIFlexItem" then
			mods.flex = mods.flex or child
		end
	end
	return mods
end
Layout.modifiers = modifiers

local function isTextObject(inst)
	local class = STATE[inst].class
	return class == "TextLabel" or class == "TextButton" or class == "TextBox"
end
Layout.isTextObject = isTextObject

local function guiChildren(inst)
	local out = {}
	for _, child in STATE[inst].children do
		if STATE[child].info.isa.GuiObject then
			table.insert(out, child)
		end
	end
	return out
end
Layout.guiChildren = guiChildren

local function paddingOf(mods, w: number, h: number)
	local p = mods.padding
	if not p then
		return 0, 0, 0, 0
	end
	local l, r, t, b = p.PaddingLeft, p.PaddingRight, p.PaddingTop, p.PaddingBottom
	return l.Scale * w + l.Offset, t.Scale * h + t.Offset, r.Scale * w + r.Offset, b.Scale * h + b.Offset
end

local function resolveSize(inst, box)
	local size = inst.Size
	local constraint = inst.SizeConstraint
	local refX, refY = box.w, box.h
	if constraint == Enum.SizeConstraint.RelativeXX then
		refY = box.w
	elseif constraint == Enum.SizeConstraint.RelativeYY then
		refX = box.h
	end
	return size.X.Scale * refX + size.X.Offset, size.Y.Scale * refY + size.Y.Offset
end

local function applyConstraints(w: number, h: number, mods)
	local aspect = mods.aspect
	if aspect then
		local r = aspect.AspectRatio
		if r <= 0 then
			r = 1
		end
		if aspect.AspectType == Enum.AspectType.ScaleWithParentSize then
			if aspect.DominantAxis == Enum.DominantAxis.Height then
				w = h * r
			else
				h = w / r
			end
		elseif h > 0 and w / h > r then
			w = h * r
		else
			h = w / r
		end
	end
	local sc = mods.sizeC
	if sc then
		local minS, maxS = sc.MinSize, sc.MaxSize
		w = math.clamp(w, minS.X, math.max(minS.X, maxS.X))
		h = math.clamp(h, minS.Y, math.max(minS.Y, maxS.Y))
	end
	return math.max(w, 0), math.max(h, 0)
end

local function textProps(inst, mods)
	local font = inst.FontFace
	local text = inst.Text
	local color, transparency = inst.TextColor3, inst.TextTransparency
	if STATE[inst].class == "TextBox" and text == "" and inst.PlaceholderText ~= "" then
		text = inst.PlaceholderText
		color = inst.PlaceholderColor3
	end
	local textC = mods.textC
	return {
		text = text,
		rich = inst.RichText,
		family = Text.familyName(font),
		weight = Text.WEIGHTS[font.Weight.Name] or 400,
		italic = font.Style.Name == "Italic",
		size = inst.TextSize,
		lineHeight = inst.LineHeight,
		wrapped = inst.TextWrapped,
		scaled = inst.TextScaled,
		truncate = inst.TextTruncate ~= Enum.TextTruncate.None,
		minSize = textC and textC.MinTextSize or 1,
		maxSize = textC and textC.MaxTextSize or 100,
		color = color,
		transparency = transparency,
	}
end
Layout.textProps = textProps

-- Moves an already-placed subtree by (dx, dy) screen pixels.
local function translate(inst, dx: number, dy: number)
	local a = STATE[inst].abs
	if a and a.gen == gen then
		a.x += dx
		a.y += dy
	end
	for _, child in STATE[inst].children do
		if STATE[child].info.isa.GuiObject then
			translate(child, dx, dy)
		end
	end
end

local place -- forward

local function sortItems(layout, items)
	local order = layout.SortOrder
	local indexed = {}
	for i, item in items do
		indexed[i] = { item = item, i = i, order = item.LayoutOrder, name = item.Name }
	end
	table.sort(indexed, function(a, b)
		if order == Enum.SortOrder.LayoutOrder then
			if a.order ~= b.order then
				return a.order < b.order
			end
		elseif order == Enum.SortOrder.Name then
			if a.name ~= b.name then
				return a.name < b.name
			end
		end
		return a.i < b.i
	end)
	local out = {}
	for i, entry in indexed do
		out[i] = entry.item
	end
	return out
end

local function flexOf(item)
	for _, child in STATE[item].children do
		if STATE[child].class == "UIFlexItem" then
			return child
		end
	end
	return nil
end

-- UIListLayout (UIPageLayout / UITableLayout fall back to this too).
local function listLayout(layout, children, cb, frame, hidden)
	local visible = {}
	for _, child in children do
		if child.Visible then
			table.insert(visible, child)
		else
			place(child, cb, frame, { hidden = true })
		end
	end
	local items = sortItems(layout, visible)
	local isList = STATE[layout].class == "UIListLayout"
	local vertical = layout.FillDirection == Enum.FillDirection.Vertical
	local mainAvail = vertical and cb.h or cb.w
	local crossAvail = vertical and cb.w or cb.h
	local gapUDim = isList and layout.Padding or roblox.UDim.new(0, 0)
	local gap = gapUDim.Scale * mainAvail + gapUDim.Offset
	local wraps = isList and layout.Wraps or false

	-- Measure each item at a provisional spot.
	local sizes = {}
	for i, item in items do
		local _, _, w, h = place(item, cb, frame, { hidden = hidden, pos = { cb.x, cb.y } })
		sizes[i] = { main = vertical and h or w, cross = vertical and w or h }
	end

	-- Split into lines.
	local lines = {}
	local line = { items = {}, main = 0, cross = 0 }
	for i, item in items do
		local size = sizes[i]
		local addition = (#line.items > 0 and gap or 0) + size.main
		if wraps and #line.items > 0 and line.main + addition > mainAvail + 0.01 then
			table.insert(lines, line)
			line = { items = {}, main = 0, cross = 0 }
			addition = size.main
		end
		table.insert(line.items, i)
		line.main += addition
		line.cross = math.max(line.cross, size.cross)
	end
	if #line.items > 0 then
		table.insert(lines, line)
	end

	local mainFlex = isList and (vertical and layout.VerticalFlex or layout.HorizontalFlex) or nil
	local crossFlex = isList and (vertical and layout.HorizontalFlex or layout.VerticalFlex) or nil
	local mainAlign = vertical and layout.VerticalAlignment or layout.HorizontalAlignment
	local crossAlign = vertical and layout.HorizontalAlignment or layout.VerticalAlignment
	local itemLineAlign = isList and layout.ItemLineAlignment or nil
	local F = Enum.UIFlexAlignment

	local contentMain, contentCross = 0, 0
	local crossCursor = 0
	local positions = {}
	for lineIndex, ln in lines do
		local lineCross = (#lines == 1 and not wraps) and math.max(ln.cross, crossAvail) or ln.cross
		local mains = {}
		for _, i in ln.items do
			mains[i] = sizes[i].main
		end
		local free = mainAvail - ln.main

		-- Grow / shrink along the main axis.
		if free > 0.01 or free < -0.01 then
			local weights, total = {}, 0
			for _, i in ln.items do
				local flex = flexOf(items[i])
				local mode = flex and flex.FlexMode or Enum.UIFlexMode.None
				local weight = 0
				if free > 0 then
					if mode == Enum.UIFlexMode.Grow or mode == Enum.UIFlexMode.Fill then
						weight = 1
					elseif mode == Enum.UIFlexMode.Custom then
						weight = flex.GrowRatio
					elseif mode == Enum.UIFlexMode.None and mainFlex == F.Fill then
						weight = 1
					end
				else
					if mode == Enum.UIFlexMode.Shrink or mode == Enum.UIFlexMode.Fill then
						weight = mains[i]
					elseif mode == Enum.UIFlexMode.Custom then
						weight = flex.ShrinkRatio * mains[i]
					elseif mode == Enum.UIFlexMode.None and mainFlex == F.Fill then
						weight = mains[i]
					end
				end
				weights[i] = weight
				total += weight
			end
			if total > 0 then
				for _, i in ln.items do
					mains[i] = math.max(0, mains[i] + free * weights[i] / total)
				end
				free = 0
			end
		end

		-- Distribute leftover space.
		local start, spacing = 0, gap
		local n = #ln.items
		if free > 0 and mainFlex == F.SpaceBetween and n > 1 then
			spacing = gap + free / (n - 1)
		elseif free > 0 and mainFlex == F.SpaceAround then
			spacing = gap + free / n
			start = free / n / 2
		elseif free > 0 and mainFlex == F.SpaceEvenly then
			spacing = gap + free / (n + 1)
			start = free / (n + 1)
		elseif mainAlign == Enum.HorizontalAlignment.Center or mainAlign == Enum.VerticalAlignment.Center then
			start = free / 2
		elseif mainAlign == Enum.HorizontalAlignment.Right or mainAlign == Enum.VerticalAlignment.Bottom then
			start = free
		end

		local cursor = start
		local usedMain = 0
		for _, i in ln.items do
			local item = items[i]
			local cross = sizes[i].cross
			local itemCross = cross
			if crossFlex == F.Fill then
				itemCross = lineCross
			end
			local align = crossAlign
			local ila = itemLineAlign and itemLineAlign ~= Enum.ItemLineAlignment.Automatic and itemLineAlign or nil
			local flex = flexOf(item)
			if flex then
				local own = flex.ItemLineAlignment
				if own and own ~= Enum.ItemLineAlignment.Automatic then
					ila = own
				end
			end
			local crossOffset
			if ila == Enum.ItemLineAlignment.Stretch then
				itemCross = lineCross
				crossOffset = 0
			elseif ila == Enum.ItemLineAlignment.Start then
				crossOffset = 0
			elseif ila == Enum.ItemLineAlignment.Center then
				crossOffset = (lineCross - itemCross) / 2
			elseif ila == Enum.ItemLineAlignment["End"] then
				crossOffset = lineCross - itemCross
			elseif align == Enum.HorizontalAlignment.Center or align == Enum.VerticalAlignment.Center then
				crossOffset = (lineCross - itemCross) / 2
			elseif align == Enum.HorizontalAlignment.Right or align == Enum.VerticalAlignment.Bottom then
				crossOffset = lineCross - itemCross
			else
				crossOffset = 0
			end
			positions[i] = {
				main = cursor,
				cross = crossCursor + crossOffset,
				mainSize = mains[i],
				crossSize = itemCross,
				resized = math.abs(mains[i] - sizes[i].main) > 0.01 or math.abs(itemCross - cross) > 0.01,
			}
			cursor += mains[i] + spacing
			usedMain = cursor - spacing
		end
		contentMain = math.max(contentMain, usedMain - start)
		crossCursor += ln.cross + (lineIndex < #lines and gap or 0)
		contentCross = math.max(contentCross, crossCursor)
	end

	-- Multi-line blocks align as a whole on the cross axis.
	local crossShift = 0
	if wraps and #lines > 1 then
		local freeCross = crossAvail - contentCross
		if crossAlign == Enum.HorizontalAlignment.Center or crossAlign == Enum.VerticalAlignment.Center then
			crossShift = freeCross / 2
		elseif crossAlign == Enum.HorizontalAlignment.Right or crossAlign == Enum.VerticalAlignment.Bottom then
			crossShift = freeCross
		end
	end

	local extW, extH = 0, 0
	for i, item in items do
		local p = positions[i]
		local x = vertical and (p.cross + crossShift) or p.main
		local y = vertical and p.main or (p.cross + crossShift)
		local w = vertical and p.crossSize or p.mainSize
		local h = vertical and p.mainSize or p.crossSize
		if p.resized then
			local k = STATE[item].abs and STATE[item].abs.k or 1
			place(item, cb, frame, { hidden = hidden, pos = { cb.x + x, cb.y + y }, size = { w / k, h / k } })
		else
			local a = STATE[item].abs
			local tx = frame.x0 + (cb.x + x) * frame.s
			local ty = frame.y0 + (cb.y + y) * frame.s
			translate(item, tx - a.x, ty - a.y)
		end
		extW = math.max(extW, x + w)
		extH = math.max(extH, y + h)
	end

	local contentW = vertical and contentCross or contentMain
	local contentH = vertical and contentMain or contentCross
	STATE[layout].abs = { gen = gen, contentW = contentW * frame.s, contentH = contentH * frame.s }
	return math.max(extW, contentW), math.max(extH, contentH)
end

local function gridLayout(layout, children, cb, frame, hidden)
	local visible = {}
	for _, child in children do
		if child.Visible then
			table.insert(visible, child)
		else
			place(child, cb, frame, { hidden = true })
		end
	end
	local items = sortItems(layout, visible)
	local cell, pad = layout.CellSize, layout.CellPadding
	local cw = cell.X.Scale * cb.w + cell.X.Offset
	local ch = cell.Y.Scale * cb.h + cell.Y.Offset
	local px = pad.X.Scale * cb.w + pad.X.Offset
	local py = pad.Y.Scale * cb.h + pad.Y.Offset
	for _, child in STATE[layout].children do
		if STATE[child].class == "UIAspectRatioConstraint" then
			cw, ch = applyConstraints(cw, ch, { aspect = child })
		elseif STATE[child].class == "UISizeConstraint" then
			cw, ch = applyConstraints(cw, ch, { sizeC = child })
		end
	end
	local horizontal = layout.FillDirection == Enum.FillDirection.Horizontal
	local maxCells = layout.FillDirectionMaxCells
	local perLine
	if horizontal then
		perLine = math.max(1, math.floor((cb.w + px) / math.max(cw + px, 1e-6)))
	else
		perLine = math.max(1, math.floor((cb.h + py) / math.max(ch + py, 1e-6)))
	end
	if maxCells and maxCells > 0 then
		perLine = math.min(perLine, maxCells)
	end
	local n = #items
	local lineCount = math.ceil(n / perLine)
	local cols = horizontal and math.min(n, perLine) or lineCount
	local rows = horizontal and lineCount or math.min(n, perLine)
	local bw = math.max(0, cols * cw + (cols - 1) * px)
	local bh = math.max(0, rows * ch + (rows - 1) * py)
	local ox, oy = 0, 0
	if layout.HorizontalAlignment == Enum.HorizontalAlignment.Center then
		ox = (cb.w - bw) / 2
	elseif layout.HorizontalAlignment == Enum.HorizontalAlignment.Right then
		ox = cb.w - bw
	end
	if layout.VerticalAlignment == Enum.VerticalAlignment.Center then
		oy = (cb.h - bh) / 2
	elseif layout.VerticalAlignment == Enum.VerticalAlignment.Bottom then
		oy = cb.h - bh
	end
	local corner = layout.StartCorner
	local flipX = corner == Enum.StartCorner.TopRight or corner == Enum.StartCorner.BottomRight
	local flipY = corner == Enum.StartCorner.BottomLeft or corner == Enum.StartCorner.BottomRight
	for index, item in items do
		local i = index - 1
		local col, row
		if horizontal then
			col, row = i % perLine, i // perLine
		else
			row, col = i % perLine, i // perLine
		end
		if flipX then
			col = cols - 1 - col
		end
		if flipY then
			row = rows - 1 - row
		end
		place(item, cb, frame, {
			hidden = hidden,
			pos = { cb.x + ox + col * (cw + px), cb.y + oy + row * (ch + py) },
			size = { cw, ch },
		})
	end
	STATE[layout].abs = { gen = gen, contentW = bw * frame.s, contentH = bh * frame.s, cellW = cw * frame.s, cellH = ch * frame.s, cols = cols, rows = rows }
	return ox + bw, oy + bh
end

-- Lays out every GuiObject child inside content box cb; returns the content extent (units, from cb origin).
local function layoutChildren(inst, cb, frame, hidden, mods)
	local children = guiChildren(inst)
	local layout = mods.layout
	if layout then
		if STATE[layout].class == "UIGridLayout" then
			return gridLayout(layout, children, cb, frame, hidden)
		end
		return listLayout(layout, children, cb, frame, hidden)
	end
	local extW, extH = 0, 0
	for _, child in children do
		local x, y, w, h = place(child, cb, frame, { hidden = hidden })
		if child.Visible then
			extW = math.max(extW, x + w - cb.x)
			extH = math.max(extH, y + h - cb.y)
		end
	end
	return extW, extH
end

-- Lune hands out a fresh EnumItem userdata per access, so compare with == rather than table keys.
local function AUTO_X_(v)
	return v == Enum.AutomaticSize.X or v == Enum.AutomaticSize.XY
end
local function AUTO_Y_(v)
	return v == Enum.AutomaticSize.Y or v == Enum.AutomaticSize.XY
end

-- Places inst inside parent content box `box` (parent units) under `frame`.
-- ctx.pos = top-left override (parent units, set by layouts); ctx.size = size override (own units).
-- Returns top-left x, y and the scaled size w, h, all in parent units.
function place(inst, box, frame, ctx)
	local s = STATE[inst]
	local mods = modifiers(inst)
	local w, h
	if ctx.size then
		w, h = ctx.size[1], ctx.size[2]
	else
		local rw, rh = resolveSize(inst, box)
		w, h = applyConstraints(rw, rh, mods)
	end
	local k = mods.scale and mods.scale.Scale or 1
	local hidden = ctx.hidden or not inst.Visible
	local isText = isTextObject(inst)
	local isScroll = s.class == "ScrollingFrame"
	local auto = inst.AutomaticSize

	local tx, ty
	local function topLeft()
		if ctx.pos then
			return ctx.pos[1], ctx.pos[2]
		end
		local p, ap = inst.Position, inst.AnchorPoint
		return box.x + p.X.Scale * box.w + p.X.Offset - ap.X * w * k, box.y + p.Y.Scale * box.h + p.Y.Offset - ap.Y * h * k
	end

	local textLayout
	local function run()
		tx, ty = topLeft()
		local f = { x0 = frame.x0 + tx * frame.s, y0 = frame.y0 + ty * frame.s, s = frame.s * k }
		local a = {
			gen = gen,
			x = f.x0,
			y = f.y0,
			w = w * f.s,
			h = h * f.s,
			s = f.s,
			k = k,
			units = { w, h },
			hidden = hidden,
			rot = inst.Rotation,
		}
		s.abs = a
		local pl, pt, pr, pb = paddingOf(mods, w, h)
		local cb = { x = pl, y = pt, w = math.max(0, w - pl - pr), h = math.max(0, h - pt - pb) }
		local extW, extH
		if isScroll then
			local canvas = inst.CanvasSize
			-- The canvas is never smaller than the window.
			local cw = math.max(w, canvas.X.Scale * w + canvas.X.Offset)
			local chh = math.max(h, canvas.Y.Scale * h + canvas.Y.Offset)
			local thickness = inst.ScrollBarThickness
			local dir = inst.ScrollingDirection
			local canY = dir ~= Enum.ScrollingDirection.X
			local canX = dir ~= Enum.ScrollingDirection.Y
			local autoCanvas = inst.AutomaticCanvasSize
			local winW, winH = w, h
			local function contentBox()
				local pos = inst.CanvasPosition
				local cpx = math.clamp(pos.X, 0, math.max(0, cw - winW))
				local cpy = math.clamp(pos.Y, 0, math.max(0, chh - winH))
				local cpl, cpt, cpr, cpb = paddingOf(mods, cw, chh)
				return { x = cpl - cpx, y = cpt - cpy, w = math.max(0, cw - cpl - cpr), h = math.max(0, chh - cpt - cpb) }, cpl + cpr, cpt + cpb, cpx, cpy
			end
			local ccb, padW, padH, cpx, cpy = contentBox()
			extW, extH = layoutChildren(inst, ccb, f, hidden, mods)
			local needW, needH = extW + padW, extH + padH
			local grew = false
			if AUTO_X_(autoCanvas) and needW > cw + 0.01 then
				cw, grew = needW, true
			end
			if AUTO_Y_(autoCanvas) and needH > chh + 0.01 then
				chh, grew = needH, true
			end
			local barY = canY and thickness > 0 and chh > h + 0.5
			local barX = canX and thickness > 0 and cw > w + 0.5
			local insetY = inst.VerticalScrollBarInset
			if (insetY == Enum.ScrollBarInset.Always and canY) or (insetY == Enum.ScrollBarInset.ScrollBar and barY) then
				winW = w - thickness
				if AUTO_X_(autoCanvas) or canvas.X.Scale > 0 then
					grew = true
				end
			end
			local insetX = inst.HorizontalScrollBarInset
			if (insetX == Enum.ScrollBarInset.Always and canX) or (insetX == Enum.ScrollBarInset.ScrollBar and barX) then
				winH = h - thickness
			end
			if grew then
				ccb, padW, padH, cpx, cpy = contentBox()
				extW, extH = layoutChildren(inst, ccb, f, hidden, mods)
			end
			a.scroll = {
				canvasW = cw * f.s,
				canvasH = chh * f.s,
				winW = winW * f.s,
				winH = winH * f.s,
				posX = cpx,
				posY = cpy,
				barY = barY,
				barX = barX,
			}
		else
			extW, extH = layoutChildren(inst, cb, f, hidden, mods)
		end
		if isText then
			local props = textProps(inst, mods)
			local tw = AUTO_X_(auto) and not ctx.size and math.huge or cb.w
			if AUTO_X_(auto) and mods.sizeC then
				tw = math.max(0, mods.sizeC.MaxSize.X - pl - pr)
			end
			textLayout = Text.layout(props, tw, cb.h)
			if AUTO_X_(auto) and tw ~= cb.w then
				-- Lay out again at the final width for alignment/truncation.
				textLayout.measuredW, textLayout.measuredH = textLayout.width, textLayout.height
			end
			s.text = textLayout
			a.textBox = { cb.x, cb.y, cb.w, cb.h }
			extW = math.max(extW, textLayout.width)
			extH = math.max(extH, textLayout.height)
		end
		return extW, extH, pl + pr, pt + pb
	end

	local extW, extH, padW, padH = run()
	if auto ~= Enum.AutomaticSize.None and not ctx.size then
		local nw, nh = w, h
		if AUTO_X_(auto) then
			nw = math.max(w, extW + padW)
		end
		if AUTO_Y_(auto) then
			nh = math.max(h, extH + padH)
		end
		if mods.sizeC then
			nw, nh = applyConstraints(nw, nh, { sizeC = mods.sizeC })
		end
		if math.abs(nw - w) > 0.01 or math.abs(nh - h) > 0.01 then
			w, h = nw, nh
			run()
		end
	end
	if isText and textLayout and textLayout.measuredW then
		-- Auto-width text: redo the final layout inside the settled box.
		local a = s.abs
		local cbw, cbh = a.textBox[3], a.textBox[4]
		s.text = Text.layout(textProps(inst, mods), math.max(cbw, textLayout.measuredW), cbh)
	end
	return tx, ty, w * k, h * k
end

-- ── Whole-screen pass ─────────────────────────────────────────────────────────
function Layout.run()
	Runtime.dirty = false
	gen += 1
	Runtime.generation = gen
	local vp = Runtime.viewport
	local playerGui = Runtime.playerGui
	if not playerGui then
		return
	end
	for _, sg in STATE[playerGui].children do
		local ss = STATE[sg]
		if ss.class ~= "ScreenGui" then
			continue
		end
		local inset = sg.IgnoreGuiInset and 0 or Runtime.topInset
		local w, h = vp.X, vp.Y - inset
		local mods = modifiers(sg)
		local k = mods.scale and mods.scale.Scale or 1
		ss.abs = { gen = gen, x = 0, y = inset, w = w, h = h, s = 1, k = 1, hidden = not sg.Enabled, rot = 0 }
		local frame = { x0 = 0, y0 = inset, s = k }
		layoutChildren(sg, { x = 0, y = 0, w = w / k, h = h / k }, frame, not sg.Enabled, mods)
	end
end

local function ensure()
	if Runtime.dirty then
		Layout.run()
	end
end
Layout.ensure = ensure

local function valid(a)
	return a ~= nil and a.gen == gen
end
Layout.valid = function(inst)
	return valid(STATE[inst].abs)
end

-- Detached text objects still report TextBounds in Roblox; measure them standalone.
local function standaloneText(inst)
	local size = inst.Size
	local props = textProps(inst, modifiers(inst))
	return Text.layout(props, size.X.Offset > 0 and size.X.Offset or math.huge, size.Y.Offset > 0 and size.Y.Offset or math.huge)
end

function Layout.read(inst, key)
	ensure()
	local s = STATE[inst]
	local a = s.abs
	local ok = valid(a)
	if key == "AbsoluteSize" then
		return ok and a.w and Vector2.new(a.w, a.h) or Vector2.zero
	elseif key == "AbsolutePosition" then
		-- Roblox reports positions relative to the area below the top bar.
		return ok and a.x and Vector2.new(a.x, a.y - Runtime.topInset) or Vector2.zero
	elseif key == "AbsoluteRotation" then
		return ok and a.rot or 0
	elseif key == "AbsoluteContentSize" then
		return ok and a.contentW and Vector2.new(a.contentW, a.contentH) or Vector2.zero
	elseif key == "AbsoluteCellSize" then
		return ok and a.cellW and Vector2.new(a.cellW, a.cellH) or Vector2.zero
	elseif key == "AbsoluteCellCount" then
		return ok and a.cols and Vector2.new(a.cols, a.rows) or Vector2.zero
	elseif key == "AbsoluteCanvasSize" then
		return ok and a.scroll and Vector2.new(a.scroll.canvasW, a.scroll.canvasH) or Vector2.zero
	elseif key == "AbsoluteWindowSize" then
		return ok and a.scroll and Vector2.new(a.scroll.winW, a.scroll.winH) or Vector2.zero
	elseif key == "TextBounds" or key == "TextFits" or key == "ContentText" then
		local t = (ok and s.text) or standaloneText(inst)
		if key == "TextBounds" then
			return Vector2.new(t.width, t.height)
		elseif key == "TextFits" then
			return t.fits
		end
		return t.contentText
	end
	return nil
end

-- ── Draw order ────────────────────────────────────────────────────────────────
local function intersect(a, b)
	if not a then
		return b
	end
	if not b then
		return a
	end
	return { math.max(a[1], b[1]), math.max(a[2], b[2]), math.min(a[3], b[3]), math.min(a[4], b[4]) }
end

local function sortedByZ(list)
	local indexed = {}
	for i, inst in list do
		indexed[i] = { inst = inst, i = i, z = inst.ZIndex }
	end
	table.sort(indexed, function(a, b)
		if a.z ~= b.z then
			return a.z < b.z
		end
		return a.i < b.i
	end)
	local out = {}
	for i, e in indexed do
		out[i] = e.inst
	end
	return out
end

-- Returns every visible GuiObject in paint order: { inst, abs, clip = {x1,y1,x2,y2}?, opacity, depth }
function Layout.drawList()
	ensure()
	local out = {}
	local playerGui = Runtime.playerGui
	local guis = {}
	for i, child in STATE[playerGui].children do
		if STATE[child].class == "ScreenGui" and child.Enabled then
			table.insert(guis, { inst = child, i = i, order = child.DisplayOrder })
		end
	end
	table.sort(guis, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.i < b.i
	end)
	for _, entry in guis do
		local sg = entry.inst
		local global = sg.ZIndexBehavior == Enum.ZIndexBehavior.Global
		local collected = {}
		local function visit(node, clip, opacity, depth, rot)
			local kids = {}
			for _, child in STATE[node].children do
				if STATE[child].info.isa.GuiObject and child.Visible and valid(STATE[child].abs) then
					table.insert(kids, child)
				end
			end
			if not global then
				kids = sortedByZ(kids)
			end
			for _, child in kids do
				local a = STATE[child].abs
				local op = opacity
				if STATE[child].class == "CanvasGroup" then
					op *= 1 - child.GroupTransparency
				end
				table.insert(collected, { inst = child, abs = a, clip = clip, opacity = op, depth = depth, z = child.ZIndex, gui = sg })
				local childClip = clip
				if child.ClipsDescendants or STATE[child].class == "ScrollingFrame" then
					local cr = { a.x, a.y, a.x + a.w, a.y + a.h }
					if a.scroll then
						cr = { a.x, a.y, a.x + a.scroll.winW, a.y + a.scroll.winH }
					end
					childClip = intersect(clip, cr)
				end
				visit(child, childClip, op, depth + 1)
			end
		end
		visit(sg, nil, 1, 0)
		if global then
			local indexed = {}
			for i, e in collected do
				e.i = i
				indexed[i] = e
			end
			table.sort(indexed, function(a, b)
				if a.z ~= b.z then
					return a.z < b.z
				end
				return a.i < b.i
			end)
			collected = indexed
		end
		for _, e in collected do
			table.insert(out, e)
		end
	end
	return out
end

-- GuiObjects under a screen point (screen pixels, top bar included), topmost first.
function Layout.hitTest(x: number, y: number, screenCoords: boolean?)
	if not screenCoords then
		y += Runtime.topInset
	end
	local list = Layout.drawList()
	local out = {}
	for i = #list, 1, -1 do
		local e = list[i]
		local a = e.abs
		local inside = x >= a.x and x < a.x + a.w and y >= a.y and y < a.y + a.h
		if inside and e.clip then
			local c = e.clip
			inside = x >= c[1] and x < c[3] and y >= c[2] and y < c[4]
		end
		if inside then
			table.insert(out, e.inst)
		end
	end
	return out
end

return Layout
