--[[
	Virtual time for animated renders (scenario `animate = true`).

	Normally renders are snapshots: tweens jump to their goal and task.wait uses real time.
	In animate mode game code runs on a virtual clock instead — task.wait / task.delay park
	the thread until ui.wait advances the clock, and tweens interpolate with Roblox's easing
	curves — so a shot at t = 0.3s shows exactly what the player sees 0.3s into a transition.
]]

local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Enum = roblox.Enum

local Clock = {}
Clock.now = 0
Clock.enabled = false

local sleepers = {} -- { wake, thread | fn, args, started }
local tweens = {} -- active animated tweens
local Runtime -- set by init

function Clock.init(runtime)
	Runtime = runtime
end

-- ── Scheduling ────────────────────────────────────────────────────────────────
function Clock.sleep(seconds: number?)
	local started = Clock.now
	table.insert(sleepers, { wake = Clock.now + math.max(seconds or 0, 0), thread = coroutine.running(), started = started })
	coroutine.yield()
	return Clock.now - started
end

function Clock.delay(seconds: number?, fn, args)
	table.insert(sleepers, { wake = Clock.now + math.max(seconds or 0, 0), fn = fn, args = args, started = Clock.now })
end

-- ── Easing (Roblox EasingStyle / EasingDirection) ─────────────────────────────
local function outBounce(t)
	if t < 1 / 2.75 then
		return 7.5625 * t * t
	elseif t < 2 / 2.75 then
		t -= 1.5 / 2.75
		return 7.5625 * t * t + 0.75
	elseif t < 2.5 / 2.75 then
		t -= 2.25 / 2.75
		return 7.5625 * t * t + 0.9375
	end
	t -= 2.625 / 2.75
	return 7.5625 * t * t + 0.984375
end

-- "In" curves; Out and InOut are derived from them.
local IN = {
	Linear = function(t)
		return t
	end,
	Sine = function(t)
		return 1 - math.cos(t * math.pi / 2)
	end,
	Quad = function(t)
		return t * t
	end,
	Cubic = function(t)
		return t ^ 3
	end,
	Quart = function(t)
		return t ^ 4
	end,
	Quint = function(t)
		return t ^ 5
	end,
	Exponential = function(t)
		return t == 0 and 0 or 2 ^ (10 * t - 10)
	end,
	Circular = function(t)
		return 1 - math.sqrt(1 - t * t)
	end,
	Back = function(t)
		return 2.70158 * t ^ 3 - 1.70158 * t * t
	end,
	Elastic = function(t)
		if t == 0 or t == 1 then
			return t
		end
		return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * (2 * math.pi) / 3)
	end,
	Bounce = function(t)
		return 1 - outBounce(1 - t)
	end,
}

function Clock.ease(alpha: number, style, direction): number
	local f = IN[style and style.Name or "Quad"] or IN.Quad
	local dir = direction and direction.Name or "Out"
	if dir == "In" then
		return f(alpha)
	elseif dir == "Out" then
		return 1 - f(1 - alpha)
	end
	if alpha < 0.5 then
		return f(alpha * 2) / 2
	end
	return 1 - f((1 - alpha) * 2) / 2
end

-- ── Interpolation ─────────────────────────────────────────────────────────────
local function lerp(a, b, t)
	local kind = typeof(b)
	if kind == "number" then
		return a + (b - a) * t
	elseif kind == "UDim" then
		return roblox.UDim.new(a.Scale + (b.Scale - a.Scale) * t, a.Offset + (b.Offset - a.Offset) * t)
	elseif kind == "UDim2" or kind == "Color3" or kind == "Vector2" or kind == "Vector3" or kind == "CFrame" then
		return a:Lerp(b, t)
	end
	return t >= 1 and b or a -- booleans, enums, strings snap at the end
end

-- A tween started in animate mode. Returns false when the tween isn't animatable here.
function Clock.startTween(tween)
	local info = tween.TweenInfo
	-- A new tween on the same property takes it over (Roblox cancels the older one).
	for _, other in tweens do
		if other.instance == tween.Instance then
			for key in tween._goals do
				other.goals[key] = nil
			end
		end
	end
	table.insert(tweens, {
		tween = tween,
		instance = tween.Instance,
		goals = table.clone(tween._goals),
		from = nil, -- captured when the delay elapses
		start = Clock.now + info.DelayTime,
		info = info,
		loop = 0,
	})
	return true
end

function Clock.cancelTween(tween)
	for i = #tweens, 1, -1 do
		if tweens[i].tween == tween then
			table.remove(tweens, i)
		end
	end
end

local function stepTweens()
	local finished = {}
	for i = #tweens, 1, -1 do
		local t = tweens[i]
		if Clock.now < t.start then
			continue
		end
		if not t.from then
			t.from = {}
			for key in t.goals do
				t.from[key] = t.instance[key]
			end
		end
		local info = t.info
		local span = math.max(info.Time, 1e-6)
		local raw = math.clamp((Clock.now - t.start) / span, 0, 1)
		local alpha = Clock.ease(raw, info.EasingStyle, info.EasingDirection)
		if t.reversing then
			alpha = 1 - alpha
		end
		for key, goal in t.goals do
			t.instance[key] = lerp(t.from[key], goal, alpha)
		end
		if raw >= 1 then
			if info.Reverses and not t.reversing then
				t.reversing = true
				t.start = Clock.now
			elseif info.RepeatCount < 0 or t.loop < info.RepeatCount then
				t.loop += 1
				t.reversing = false
				t.start = Clock.now + info.DelayTime
			else
				table.remove(tweens, i)
				table.insert(finished, t.tween)
			end
		end
	end
	for _, tween in finished do
		tween.PlaybackState = Enum.PlaybackState.Completed
		tween.Completed:Fire(Enum.PlaybackState.Completed)
	end
end

-- Advances virtual time by dt: wakes due threads/delays, then steps tweens.
function Clock.advance(dt: number)
	Clock.now += dt
	local due = {}
	for i = #sleepers, 1, -1 do
		if sleepers[i].wake <= Clock.now + 1e-9 then
			table.insert(due, table.remove(sleepers, i))
		end
	end
	table.sort(due, function(a, b)
		return a.wake < b.wake
	end)
	for _, s in due do
		if s.thread then
			if coroutine.status(s.thread) == "suspended" then
				task.spawn(s.thread, Clock.now - s.started)
			end
		else
			s.fn(table.unpack(s.args, 1, s.args.n))
		end
	end
	stepTweens()
	task.wait() -- let anything the woken code spawned run
end

function Clock.busy(): boolean
	return #tweens > 0
end

return Clock
