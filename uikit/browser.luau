--[[
	Minimal headless Chrome/Edge driver over the DevTools protocol. Used instead of
	`chrome --screenshot` because that mode shrinks the viewport below the window size.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Browser = {}

local CANDIDATES = {
	"C:/Program Files/Google/Chrome/Application/chrome.exe",
	"C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
	"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
	"C:/Program Files/Microsoft/Edge/Application/msedge.exe",
	"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
	"/usr/bin/google-chrome",
	"/usr/bin/chromium",
}

function Browser.find(): string?
	for _, path in CANDIDATES do
		if fs.isFile(path) then
			return path
		end
	end
	return nil
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local decodeTable = {}
for i = 1, 64 do
	decodeTable[string.byte(B64, i)] = i - 1
end

local function base64Decode(s: string): string
	s = string.gsub(s, "[^%w%+/]", "")
	local n = #s
	local out = buffer.create((n * 3) // 4)
	local o = 0
	local src = buffer.fromstring(s)
	for i = 0, n - 1, 4 do
		local a = decodeTable[buffer.readu8(src, i)]
		local b = decodeTable[buffer.readu8(src, i + 1)]
		local c = i + 2 < n and decodeTable[buffer.readu8(src, i + 2)] or nil
		local d = i + 3 < n and decodeTable[buffer.readu8(src, i + 3)] or nil
		local v = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
		buffer.writeu8(out, o, (v // 65536) % 256)
		o += 1
		if c then
			buffer.writeu8(out, o, (v // 256) % 256)
			o += 1
		end
		if d then
			buffer.writeu8(out, o, v % 256)
			o += 1
		end
	end
	return buffer.readstring(out, 0, o)
end

local session = nil

local function send(method: string, params, sessionId: string?)
	local s = session
	s.nextId += 1
	local id = s.nextId
	s.socket:send(serde.encode("json", { id = id, method = method, params = params or {}, sessionId = sessionId }))
	while true do
		local raw = s.socket:next()
		if raw == nil then
			error(`browser closed while waiting for {method}`)
		end
		local message = serde.decode("json", raw)
		if message.id == id then
			if message.error then
				error(`{method}: {message.error.message}`)
			end
			return message.result
		elseif message.method then
			table.insert(s.events, message)
		end
	end
end

local function waitEvent(name: string, sessionId: string, timeout: number)
	local s = session
	local deadline = os.clock() + timeout
	for index, event in s.events do
		if event.method == name and event.sessionId == sessionId then
			table.remove(s.events, index)
			return event
		end
	end
	while os.clock() < deadline do
		local raw = s.socket:next()
		if raw == nil then
			return nil
		end
		local message = serde.decode("json", raw)
		if message.method == name and message.sessionId == sessionId then
			return message
		end
	end
	return nil
end

local function start(executable: string, profileDir: string)
	local child = process.create(executable, {
		"--headless=new",
		"--disable-gpu",
		"--hide-scrollbars",
		"--no-first-run",
		"--no-default-browser-check",
		"--remote-debugging-port=0",
		"--allow-file-access-from-files",
		`--user-data-dir={profileDir}`,
		"about:blank",
	})
	local log = ""
	local url
	local deadline = os.clock() + 20
	while not url and os.clock() < deadline do
		local chunk = child.stderr:read()
		if not chunk then
			break
		end
		log ..= chunk
		url = string.match(log, "DevTools listening on (ws://%S+)")
	end
	if not url then
		pcall(function()
			child:kill()
		end)
		error(`couldn't start {executable}: {log}`)
	end
	session = { child = child, socket = net.socket(url), nextId = 0, events = {} }
	local target = send("Target.createTarget", { url = "about:blank" })
	local attached = send("Target.attachToTarget", { targetId = target.targetId, flatten = true })
	session.pageSession = attached.sessionId
	send("Page.enable", {}, session.pageSession)
end

-- Screenshots a local HTML file at exactly width x height; clip = { x, y, w, h } optional.
function Browser.screenshot(executable: string, profileDir: string, htmlPath: string, pngPath: string, width: number, height: number, clip)
	if not session then
		start(executable, profileDir)
	end
	local page = session.pageSession
	send("Emulation.setDeviceMetricsOverride", { width = width, height = height, deviceScaleFactor = 1, mobile = false }, page)
	send("Page.navigate", { url = htmlPath }, page)
	waitEvent("Page.loadEventFired", page, 15)
	send("Runtime.evaluate", { expression = "document.fonts.ready.then(() => true)", awaitPromise = true }, page)
	local params = { format = "png", captureBeyondViewport = false }
	if clip then
		params.clip = { x = clip[1], y = clip[2], width = clip[3], height = clip[4], scale = 1 }
	end
	local result = send("Page.captureScreenshot", params, page)
	fs.writeFile(pngPath, base64Decode(result.data))
end

function Browser.close()
	if session then
		pcall(function()
			send("Browser.close", {})
		end)
		pcall(function()
			session.child:kill()
		end)
		session = nil
	end
end

return Browser
