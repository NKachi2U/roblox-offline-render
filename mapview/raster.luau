--[[
	Depth-buffered 3D views of the parts (a stand-in for Studio viewport screenshots).
	Software triangle rasterizer: flat sun shading, transparency, distance fog. It shows form and
	layout, not Roblox lighting. MeshParts and unions are drawn as their bounding boxes.

	A view is { eye = {x,y,z}, target = {x,y,z}, fov = 60, size = {w,h}, ortho = px per stud?,
	maxBottom = y? (skip parts starting above this, for cutaways), sky = {r,g,b}, fog = true }.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Png = require("./png")

local Vector3 = roblox.Vector3

local Raster = {}

local SUN = { 0.35, 0.85, 0.4 }
do
	local len = math.sqrt(SUN[1] ^ 2 + SUN[2] ^ 2 + SUN[3] ^ 2)
	SUN = { SUN[1] / len, SUN[2] / len, SUN[3] / len }
end

local function sub(a, b)
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end
local function dot(a, b)
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
local function cross(a, b)
	return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
local function unit(a)
	local len = math.sqrt(dot(a, a))
	if len < 1e-9 then
		return { 0, 0, 0 }
	end
	return { a[1] / len, a[2] / len, a[3] / len }
end

-- Local-space vertices and faces for a part's shape.
local function shapeMesh(part)
	local sx, sy, sz = part.Size.X / 2, part.Size.Y / 2, part.Size.Z / 2
	local shape = part.Shape
	if shape == "Wedge" then
		return {
			{ -sx, -sy, -sz }, { sx, -sy, -sz }, { sx, -sy, sz }, { -sx, -sy, sz }, { -sx, sy, sz }, { sx, sy, sz },
		}, { { 1, 2, 6, 5 }, { 4, 3, 6, 5 }, { 1, 4, 5 }, { 2, 3, 6 }, { 1, 2, 3, 4 } }
	elseif shape == "CornerWedge" then
		return {
			{ -sx, -sy, -sz }, { sx, -sy, -sz }, { sx, -sy, sz }, { -sx, -sy, sz }, { sx, sy, -sz },
		}, { { 1, 2, 3, 4 }, { 1, 2, 5 }, { 2, 3, 5 }, { 3, 4, 5 }, { 4, 1, 5 } }
	elseif shape == "Cylinder" then
		local n = 14
		local verts, faces = {}, {}
		local r = math.min(sy, sz)
		for k = 0, n - 1 do
			local a = 2 * math.pi * k / n
			table.insert(verts, { -sx, math.cos(a) * r, math.sin(a) * r })
		end
		for k = 0, n - 1 do
			local a = 2 * math.pi * k / n
			table.insert(verts, { sx, math.cos(a) * r, math.sin(a) * r })
		end
		local capA, capB = {}, {}
		for k = 1, n do
			table.insert(capA, k)
			table.insert(capB, n + k)
			table.insert(faces, { k, k % n + 1, n + k % n + 1, n + k })
		end
		table.insert(faces, capA)
		table.insert(faces, capB)
		return verts, faces
	elseif shape == "Ball" then
		local rings, segs = 6, 10
		local r = math.min(sx, sy, sz)
		local verts, faces = {}, {}
		for i = 0, rings do
			local phi = math.pi * i / rings
			for j = 0, segs - 1 do
				local th = 2 * math.pi * j / segs
				table.insert(verts, { r * math.sin(phi) * math.cos(th), r * math.cos(phi), r * math.sin(phi) * math.sin(th) })
			end
		end
		for i = 0, rings - 1 do
			for j = 0, segs - 1 do
				local a, b = i * segs + j + 1, i * segs + (j + 1) % segs + 1
				table.insert(faces, { a, b, b + segs, a + segs })
			end
		end
		return verts, faces
	end
	local verts = {}
	for _, x in { -sx, sx } do
		for _, y in { -sy, sy } do
			for _, z in { -sz, sz } do
				table.insert(verts, { x, y, z })
			end
		end
	end
	return verts, { { 1, 2, 4, 3 }, { 5, 7, 8, 6 }, { 1, 5, 6, 2 }, { 3, 4, 8, 7 }, { 1, 3, 7, 5 }, { 2, 6, 8, 4 } }
end

-- World-space triangles with colour, alpha and glow, for the parts a view includes.
local function triangles(parts, view)
	local tris = {}
	for _, part in parts do
		if view.maxBottom and part.MinY > view.maxBottom then
			continue
		end
		if view.exclude and view.exclude(part) then
			continue
		end
		local verts, faces = shapeMesh(part)
		local cf = part.CFrame
		local world = {}
		for index, v in verts do
			local p = cf * Vector3.new(v[1], v[2], v[3])
			world[index] = { p.X, p.Y, p.Z }
		end
		local color = { part.Color.R * 255, part.Color.G * 255, part.Color.B * 255 }
		local alpha = 1 - part.Transparency
		local glow = part.Material == "Neon"
		for _, face in faces do
			for k = 2, #face - 1 do
				table.insert(tris, { world[face[1]], world[face[k]], world[face[k + 1]], color = color, alpha = alpha, glow = glow })
			end
		end
	end
	return tris
end

function Raster.render(parts, view, path: string)
	local width, height = view.size[1], view.size[2]
	local eye, target = view.eye, view.target
	local fwd = unit(sub(target, eye))
	local right = cross(fwd, { 0, 1, 0 })
	if dot(right, right) < 1e-6 then
		right = { 1, 0, 0 } -- looking straight down
	end
	right = unit(right)
	local up = cross(right, fwd)
	local ortho = view.ortho
	local focal = (width / 2) / math.tan(math.rad(view.fov or 60) / 2)
	local sky = view.sky or { 150, 170, 196 }

	local count = width * height
	local colorBuf = buffer.create(count * 12) -- f32 r, g, b
	local depthBuf = buffer.create(count * 4) -- f32, smaller = closer
	for i = 0, count - 1 do
		buffer.writef32(colorBuf, i * 12, sky[1])
		buffer.writef32(colorBuf, i * 12 + 4, sky[2])
		buffer.writef32(colorBuf, i * 12 + 8, sky[3])
		buffer.writef32(depthBuf, i * 4, math.huge)
	end

	local tris = triangles(parts, view)
	-- Camera-space positions, shading, and draw order: opaque first, then transparent far to near.
	for _, tri in tris do
		local cam = {}
		local sumZ = 0
		for k = 1, 3 do
			local rel = sub(tri[k], eye)
			local c = { dot(rel, right), dot(rel, up), dot(rel, fwd) }
			cam[k] = c
			sumZ += c[3]
		end
		tri.cam = cam
		tri.depth = sumZ / 3
		local normal = unit(cross(sub(tri[2], tri[1]), sub(tri[3], tri[1])))
		local center = { (tri[1][1] + tri[2][1] + tri[3][1]) / 3, (tri[1][2] + tri[2][2] + tri[3][2]) / 3, (tri[1][3] + tri[2][3] + tri[3][3]) / 3 }
		local toward = if ortho then { -fwd[1], -fwd[2], -fwd[3] } else sub(eye, center)
		if dot(normal, toward) < 0 then
			normal = { -normal[1], -normal[2], -normal[3] }
		end
		local light = 0.5 + 0.55 * math.clamp(dot(normal, SUN), 0, 1)
		local c = tri.color
		if tri.glow then
			tri.shade = { math.min(c[1] * 1.25 + 30, 255), math.min(c[2] * 1.25 + 30, 255), math.min(c[3] * 1.25 + 30, 255) }
		else
			tri.shade = { c[1] * light, c[2] * light, c[3] * light }
		end
	end
	table.sort(tris, function(a, b)
		local ao, bo = a.alpha >= 0.99, b.alpha >= 0.99
		if ao ~= bo then
			return ao
		end
		if ao then
			return a.depth < b.depth -- near first: more early depth rejects
		end
		return a.depth > b.depth
	end)

	local near = 0.3
	local function drawPoly(poly, tri)
		local sxs, sys, invs = {}, {}, {}
		for k = 1, 3 do
			local p = poly[k]
			if ortho then
				sxs[k] = width / 2 + p[1] * ortho
				sys[k] = height / 2 - p[2] * ortho
				invs[k] = -p[3]
			else
				sxs[k] = width / 2 + p[1] / p[3] * focal
				sys[k] = height / 2 - p[2] / p[3] * focal
				invs[k] = 1 / p[3]
			end
		end
		local x0 = math.max(math.floor(math.min(sxs[1], sxs[2], sxs[3])), 0)
		local x1 = math.min(math.ceil(math.max(sxs[1], sxs[2], sxs[3])), width - 1)
		local y0 = math.max(math.floor(math.min(sys[1], sys[2], sys[3])), 0)
		local y1 = math.min(math.ceil(math.max(sys[1], sys[2], sys[3])), height - 1)
		if x0 > x1 or y0 > y1 then
			return
		end
		local ax, ay, bx, by, cx, cy = sxs[1], sys[1], sxs[2], sys[2], sxs[3], sys[3]
		local area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
		if math.abs(area) < 1e-9 then
			return
		end
		local inv1, inv2, inv3 = invs[1], invs[2], invs[3]
		local shadeR, shadeG, shadeB = tri.shade[1], tri.shade[2], tri.shade[3]
		local alpha = tri.alpha
		local opaque = alpha >= 0.99
		for y = y0, y1 do
			local gy = y + 0.5
			for x = x0, x1 do
				local gx = x + 0.5
				local w0 = ((bx - gx) * (cy - gy) - (cx - gx) * (by - gy)) / area
				local w1 = ((cx - gx) * (ay - gy) - (ax - gx) * (cy - gy)) / area
				local w2 = 1 - w0 - w1
				if w0 >= -1e-6 and w1 >= -1e-6 and w2 >= -1e-6 then
					local d = -(w0 * inv1 + w1 * inv2 + w2 * inv3)
					local index = y * width + x
					if d < buffer.readf32(depthBuf, index * 4) then
						local at = index * 12
						if opaque then
							buffer.writef32(depthBuf, index * 4, d)
							buffer.writef32(colorBuf, at, shadeR)
							buffer.writef32(colorBuf, at + 4, shadeG)
							buffer.writef32(colorBuf, at + 8, shadeB)
						else
							buffer.writef32(colorBuf, at, buffer.readf32(colorBuf, at) * (1 - alpha) + shadeR * alpha)
							buffer.writef32(colorBuf, at + 4, buffer.readf32(colorBuf, at + 4) * (1 - alpha) + shadeG * alpha)
							buffer.writef32(colorBuf, at + 8, buffer.readf32(colorBuf, at + 8) * (1 - alpha) + shadeB * alpha)
						end
					end
				end
			end
		end
	end

	for _, tri in tris do
		local cam = tri.cam
		if ortho then
			drawPoly(cam, tri)
		else
			local z1, z2, z3 = cam[1][3], cam[2][3], cam[3][3]
			if z1 < near and z2 < near and z3 < near then
				continue
			end
			if z1 < near or z2 < near or z3 < near then
				-- Clip against the near plane.
				local pts = {}
				for k = 1, 3 do
					local a, b = cam[k], cam[k % 3 + 1]
					if a[3] >= near then
						table.insert(pts, a)
					end
					if (a[3] >= near) ~= (b[3] >= near) then
						local t = (near - a[3]) / (b[3] - a[3])
						table.insert(pts, { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t })
					end
				end
				for k = 2, #pts - 1 do
					drawPoly({ pts[1], pts[k], pts[k + 1] }, tri)
				end
			else
				drawPoly(cam, tri)
			end
		end
	end

	local rgb = buffer.create(count * 3)
	local fog = not ortho and view.fog ~= false
	for i = 0, count - 1 do
		local r, g, b = buffer.readf32(colorBuf, i * 12), buffer.readf32(colorBuf, i * 12 + 4), buffer.readf32(colorBuf, i * 12 + 8)
		if fog then
			local d = buffer.readf32(depthBuf, i * 4)
			if d < math.huge then
				local f = math.clamp((-1 / d - 60) / 500, 0, 0.6)
				r, g, b = r * (1 - f) + sky[1] * f, g * (1 - f) + sky[2] * f, b * (1 - f) + sky[3] * f
			end
		end
		buffer.writeu8(rgb, i * 3, math.clamp(math.floor(r), 0, 255))
		buffer.writeu8(rgb, i * 3 + 1, math.clamp(math.floor(g), 0, 255))
		buffer.writeu8(rgb, i * 3 + 2, math.clamp(math.floor(b), 0, 255))
	end
	fs.writeFile(path, Png.encode(width, height, rgb))
	return #tris
end

return Raster
