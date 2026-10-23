--[[
	Offline UI renderer (Lune). Runs a place's real client scripts against a stand-in Roblox
	client, lays the GUI out with Roblox's rules and screenshots it with headless Chrome/Edge.

	Run it from your Rojo project (the folder with default.project.json):

	    lune run path/to/uikit/run.luau shop-open
	    lune run path/to/uikit/run.luau shop-open --size 1366x768 --outline
	    lune run path/to/uikit/run.luau ui-scenarios/hud.luau --place places/main

	A bare name is looked up in ./ui-scenarios/<name>.luau (change it with --scenarios <dir>).
	Outputs: artifacts/uikit/<scenario>-<shot>.png and .html (change it with --out <dir>).
	Flags: --place <dir>  --size WxH  --studio  --outline  --no-png  --echo (show script prints)
	       --backdrop <image>   drawn behind the UI instead of the neutral gradient
	       --placefile <.rbxl>  merge a saved place's non-Rojo content (maps, assets, Studio-built UI)
	       --assets <dir>       where <id>.png files for rbxassetid:// images live (default ./uikit-assets)
	       --animate            run tweens over time (needed for ui.filmstrip)
	       --rebuild-fonts      re-read font metrics from the Roblox install
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Runtime = require("./runtime")
local World = require("./world")
local Text = require("./text")
local Layout = require("./layout")
local Paint = require("./paint")
local Harness = require("./harness")
local Browser = require("./browser")
local Clock = require("./clock")
local Fonts = require("./fonts")

-- ── Paths ─────────────────────────────────────────────────────────────────────
-- Forward slashes, with "." and ".." folded away ("C:\a\b/../c" -> "C:/a/c").
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

local function isAbsolute(path: string): boolean
	return string.match(path, "^%a:/") ~= nil or string.sub(path, 1, 1) == "/"
end

local CWD = normalize(process.cwd)

local function absolute(path: string): string
	path = normalize(path)
	if isAbsolute(path) then
		return path
	end
	return normalize(`{CWD}/{path}`)
end

-- This script's folder, so the tool works wherever it was cloned and whatever the cwd is.
local TOOL_DIR = normalize(string.match(normalize(debug.info(1, "s")), "^(.*)/[^/]*$") or ".")

-- Lune only requires relative paths, so reach the scenario from this folder.
local function relativeFromTool(target: string): string
	local function split(path: string)
		local parts = {}
		for part in string.gmatch(path, "[^/]+") do
			table.insert(parts, part)
		end
		return parts
	end
	local from, to = split(TOOL_DIR), split(target)
	local windows = string.match(TOOL_DIR, "^%a:") ~= nil
	local function same(a: string, b: string): boolean
		return if windows then string.lower(a) == string.lower(b) else a == b
	end
	assert(same(from[1], to[1]), `The scenario must be on the same drive as the tool ({target})`)
	local common = 0
	while common < #from and common < #to and same(from[common + 1], to[common + 1]) do
		common += 1
	end
	local parts = {}
	for _ = common + 1, #from do
		table.insert(parts, "..")
	end
	for index = common + 1, #to do
		table.insert(parts, to[index])
	end
	local rel = table.concat(parts, "/")
	return if string.sub(rel, 1, 2) == ".." then rel else `./{rel}`
end

local function fileUrl(path: string): string
	return if string.sub(path, 1, 1) == "/" then `file://{path}` else `file:///{path}`
end

-- ── Arguments ─────────────────────────────────────────────────────────────────
local args = process.args
local VALUE_FLAGS = { place = true, size = true, backdrop = true, placefile = true, out = true, scenarios = true, assets = true }
local flags = {}
local positional = {}
local i = 1
while i <= #args do
	local arg = args[i]
	local key = string.match(arg, "^%-%-(.+)$")
	if key and VALUE_FLAGS[key] then
		flags[key] = args[i + 1]
		i += 2
	elseif key then
		flags[key] = true
		i += 1
	else
		table.insert(positional, arg)
		i += 1
	end
end

local SCENARIO_DIR = absolute(flags.scenarios or "ui-scenarios")
local OUT_DIR = absolute(flags.out or "artifacts/uikit")

local scenarioArg = positional[1]
if not scenarioArg then
	print("usage: lune run <path>/uikit/run.luau <scenario> [--place <dir>] [--size 1920x1080] [--outline] [--studio] [--no-png] [--echo]")
	if fs.isDir(SCENARIO_DIR) then
		print(`scenarios in {SCENARIO_DIR}:`)
		for _, entry in fs.readDir(SCENARIO_DIR) do
			if string.match(entry, "%.luau$") and string.sub(entry, 1, 1) ~= "_" then
				print(`  {string.gsub(entry, "%.luau$", "")}`)
			end
		end
	else
		print(`(no {SCENARIO_DIR} folder here; pass a scenario file path or --scenarios <dir>)`)
	end
	process.exit(1)
end

local scenarioPath = absolute(scenarioArg)
if not fs.isFile(scenarioPath) then
	scenarioPath = `{SCENARIO_DIR}/{string.gsub(scenarioArg, "%.luau$", "")}.luau`
end
assert(fs.isFile(scenarioPath), `No scenario {scenarioArg} (looked for {scenarioPath})`)
local scenarioName = string.gsub(string.match(scenarioPath, "([^/]+)$"), "%.luau$", "")

-- Scenarios are plain Lune modules returning { place?, size?, studio?, run = function(ui) } or a function.
local scenarioModule = require(relativeFromTool((string.gsub(scenarioPath, "%.luau$", ""))))
local scenario = type(scenarioModule) == "function" and { run = scenarioModule } or scenarioModule

local place = absolute(flags.place or scenario.place or ".")
assert(fs.isFile(`{place}/default.project.json`), `No default.project.json in {place} (run from your Rojo project, or pass --place <dir>)`)

local width, height = 1920, 1080
local sizeText = flags.size or scenario.size
if sizeText then
	local w, h = string.match(sizeText, "^(%d+)x(%d+)$")
	assert(w, "--size must look like 1920x1080")
	width, height = tonumber(w), tonumber(h)
end

-- ── Screenshots ───────────────────────────────────────────────────────────────
local browser = Browser.find()

local function screenshot(htmlPath: string, pngPath: string, cropInst, size)
	if not browser then
		print("\27[33m[uikit] no Chrome/Edge found — wrote HTML only\27[0m")
		return
	end
	local clip
	if cropInst then
		Layout.ensure()
		local a = Runtime.STATE[cropInst].abs
		local pad = 8
		local x, y = math.max(0, math.floor(a.x - pad)), math.max(0, math.floor(a.y - pad))
		clip = { x, y, math.min(width - x, math.ceil(a.w + pad * 2)), math.min(height - y, math.ceil(a.h + pad * 2)) }
	end
	local w, h = width, height
	if size then
		w, h = size[1], size[2]
	end
	local ok, err = pcall(Browser.screenshot, browser, `{OUT_DIR}/.browser-profile`, fileUrl(htmlPath), pngPath, w, h, clip)
	if not ok then
		print(`\27[31m[uikit] screenshot failed: {err}\27[0m`)
	end
end

-- ── Boot ──────────────────────────────────────────────────────────────────────
if not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end
local FONTS = `{TOOL_DIR}/fonts.json`
if flags["rebuild-fonts"] or not fs.isFile(FONTS) then
	local ok, err = pcall(Fonts.build, FONTS)
	if not ok then
		print(`[31m[uikit] {err}[0m`)
		process.exit(1)
	end
end
for _, entry in fs.readDir(OUT_DIR) do
	if string.sub(entry, 1, #scenarioName + 1) == scenarioName .. "-" then
		fs.removeFile(`{OUT_DIR}/{entry}`)
	end
end

Text.load(FONTS)
Runtime.text = Text
Runtime.layout = Layout
Runtime.echo = flags.echo == true
Layout.init(Runtime, Text)
Paint.init(Runtime, Layout, Text)
Paint.assetDirs = { absolute(flags.assets or "uikit-assets"), `{TOOL_DIR}/assets` }

Clock.init(Runtime)
Clock.enabled = flags.animate == true or scenario.animate == true
World.create({
	viewport = roblox.Vector2.new(width, height),
	studio = flags.studio == true or scenario.studio == true,
	playerName = scenario.playerName,
})
Runtime.mountProject(place)
if flags.placefile then
	assert(fs.isFile(flags.placefile), `--placefile {flags.placefile} not found`)
	local t0 = os.clock()
	local added = Runtime.mountPlaceFile(flags.placefile)
	print(string.format("[uikit] merged %d top-level instance(s) from %s in %.1fs", added, flags.placefile, os.clock() - t0))
end
World.installRed()
Runtime.setEnvironment("client", World.environment("client"))
Runtime.setEnvironment("server", World.environment("server"))

local ui = Harness.create({
	outDir = OUT_DIR,
	scenario = scenarioName,
	outline = flags.outline == true,
	png = not flags["no-png"],
	backdrop = flags.backdrop,
	screenshot = screenshot,
})

print(`[uikit] {scenarioName} — {place} at {width}x{height}`)
local started = os.clock()
local ok, err = xpcall(scenario.run, function(e)
	return tostring(e) .. "\n" .. debug.traceback(nil, 2)
end, ui)
Browser.close()

print(string.format("[uikit] done in %.1fs — %d shot(s), %d script error(s), %d warning(s)", os.clock() - started, #ui.shots, #Runtime.errors, #Runtime.warnings))
if #Paint.missingImages > 0 then
	local seen, list = {}, {}
	for _, image in Paint.missingImages do
		if not seen[image] then
			seen[image] = true
			table.insert(list, image)
		end
	end
	print(`[uikit] {#list} image(s) not available offline (drawn hatched; drop <id>.png into {Paint.assetDirs[1]}/): {table.concat(list, ", ")}`)
end
if not ok then
	print(`\27[31m[uikit] scenario failed: {err}\27[0m`)
	process.exit(1)
end
process.exit(0)
