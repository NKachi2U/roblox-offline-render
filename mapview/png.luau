--[[
	Minimal PNG writer: 8-bit RGB, no filtering, zlib from Lune's serde.
]]

local serde = require("@lune/serde")

local Png = {}

local crcTable = {}
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	crcTable[n] = c
end

local function crc32(data: string): number
	local c = 0xFFFFFFFF
	for i = 1, #data do
		c = bit32.bxor(crcTable[bit32.band(bit32.bxor(c, string.byte(data, i)), 0xFF)], bit32.rshift(c, 8))
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

local function chunk(kind: string, data: string): string
	return string.pack(">I4", #data) .. kind .. data .. string.pack(">I4", crc32(kind .. data))
end

-- rgb: a buffer of width * height * 3 bytes, rows top to bottom.
function Png.encode(width: number, height: number, rgb: buffer): string
	local stride = width * 3
	local raw = buffer.create((stride + 1) * height)
	for y = 0, height - 1 do
		buffer.writeu8(raw, y * (stride + 1), 0)
		buffer.copy(raw, y * (stride + 1) + 1, rgb, y * stride, stride)
	end
	local header = string.pack(">I4I4BBBBB", width, height, 8, 2, 0, 0, 0)
	return "\137PNG\r\n\26\n"
		.. chunk("IHDR", header)
		.. chunk("IDAT", serde.compress("zlib", buffer.tostring(raw)))
		.. chunk("IEND", "")
end

return Png
