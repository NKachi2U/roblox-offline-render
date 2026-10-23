--[[
	Finds the content folder of the local Roblox install (fonts, rbxasset:// images).
	Windows: %LOCALAPPDATA%/Roblox/Versions/version-*/content (Player and Studio both install there).
	macOS: /Applications/RobloxStudio.app or Roblox.app, Contents/Resources/content.
	Set ROBLOX_CONTENT_DIR to point somewhere else.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Content = {}

local function hasFonts(dir: string): boolean
	return fs.isDir(`{dir}/fonts/families`)
end

local function find(): string?
	local override = process.env.ROBLOX_CONTENT_DIR
	if override and hasFonts(override) then
		return override
	end
	local local_ = process.env.LOCALAPPDATA
	if local_ then
		local root = `{local_}/Roblox/Versions`
		if fs.isDir(root) then
			-- Newest install wins; version folders don't sort by age, so compare modified times.
			local best, bestTime
			for _, entry in fs.readDir(root) do
				local dir = `{root}/{entry}/content`
				if hasFonts(dir) then
					local ok, meta = pcall(fs.metadata, `{dir}/fonts/families`)
					local t = ok and meta.modifiedAt and meta.modifiedAt.unixTimestamp or 0
					if not bestTime or t > bestTime then
						best, bestTime = dir, t
					end
				end
			end
			if best then
				return best
			end
		end
	end
	local home = process.env.HOME
	for _, dir in {
		"/Applications/RobloxStudio.app/Contents/Resources/content",
		"/Applications/Roblox.app/Contents/Resources/content",
		home and `{home}/Applications/RobloxStudio.app/Contents/Resources/content` or "",
	} do
		if dir ~= "" and hasFonts(dir) then
			return dir
		end
	end
	return nil
end

local cached = nil
function Content.dir(): string?
	if cached == nil then
		cached = find() or false
	end
	return cached or nil
end

return Content
