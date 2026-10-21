-- Per-vehicle cost history of Running Cost Breakdown: a ring of time buckets
-- holding, per cost class, the game seconds spent, plus the vehicle's static
-- (healthy) rate per year as seen in that bucket and the maintenance-state
-- surcharge charged in it. The cost per class is derived in window() as
-- seconds × factor × rate / year, so a bucket is small (the state is copied
-- on every get/set of the game script, ~400 vehicles × 13 buckets).
--
-- 7 buckets of 243 500 ms: 6 cover one default game year (1 461 000 ms of
-- game time, api.util.getDefaultYearDuration()), the 7th makes sure a full
-- window is always inside the ring. window() counts every bucket that
-- overlaps the window, the oldest one pro rata by its overlap (assuming the
-- time inside a bucket is spread evenly); coverage is the time span the
-- counted buckets stand for, capped at the window. Few, large buckets keep
-- the game-script state small: it is copied on every get/set of the
-- sampler (~400 vehicles).
--
-- The tables live in the game-script state (saved with the game), so every
-- function tolerates buckets without t/c/s and class keys it has never seen.
-- No game API, unit-tested with plain luajit (test/cost_history_test.lua).
local M = {}

M.BUCKET_MS = 243500
M.BUCKETS = 7

local function bucketStart(ms)
	return math.floor(ms / M.BUCKET_MS) * M.BUCKET_MS
end

-- History = { start = ms of the first bucket, first = ms of the first sample
-- (coverage counts from here, not from the bucket start), head = slot of the
-- newest bucket (0 = none), b = { [slot] = { t0, t = {key = s}, r = rate/year, s = surcharge } } }
function M.new(nowMs)
	return { start = bucketStart(nowMs or 0), first = nowMs or 0, head = 0, b = {} }
end

-- the bucket for nowMs, opening it (reusing the oldest slot) when needed;
-- a step back in time starts the history over
local function bucketFor(h, nowMs)
	local t0 = bucketStart(nowMs)
	local cur = h.head > 0 and h.b[h.head] or nil
	if cur and cur.t0 == t0 then return cur end
	if nowMs < h.start or (cur and t0 < cur.t0) then
		h.start, h.first, h.head, h.b = t0, nowMs, 0, {}
	end
	h.head = h.head % M.BUCKETS + 1
	local nb = { t0 = t0, t = {}, r = 0, s = 0 }
	h.b[h.head] = nb
	return nb
end

-- dtMs of game time spent in class `key` at costPerYearStatic (the healthy
-- rate; a consist change inside one bucket is attributed to the new rate)
-- with surchargePerYear on top, charged at `factor`
function M.add(h, nowMs, dtMs, key, costPerYearStatic, surchargePerYear, factor, yearMs)
	local b = bucketFor(h, nowMs)
	b.t = b.t or {}
	local before = 0
	for __, v in pairs(b.t) do before = before + v end
	local dt = dtMs / 1000
	b.t[key] = (b.t[key] or 0) + dt
	-- the bucket's rate is the seconds-weighted mean, so a consist change
	-- inside a bucket keeps the old rate for the seconds before it
	if before + dt > 0 then
		b.r = ((b.r or 0) * before + (costPerYearStatic or 0) * dt) / (before + dt)
	end
	b.s = (b.s or 0) + (surchargePerYear or 0) * dtMs / yearMs * factor
end

-- factorOf(key) -> the class factor, yearMs -> the default year ->
-- Summary = { cov = covered ms (<= windowMs), t = {key = s}, c = {key = cost},
--   s = surcharge, total = sum of c + s }
function M.window(h, nowMs, windowMs, factorOf, yearMs)
	local out = { cov = 0, t = {}, c = {}, s = 0, total = 0 }
	if not h or type(h.b) ~= "table" then return out end
	local from = nowMs - windowMs
	local oldest = nil
	for __, b in pairs(h.b) do
		if type(b) == "table" and b.t0 and b.t0 + M.BUCKET_MS > from and b.t0 <= nowMs then
			if oldest == nil or b.t0 < oldest then oldest = b.t0 end
			-- share of the bucket's data inside the window (only the oldest one is
			-- cut); the data of the history's first bucket starts at `first`
			local weight = 1
			local dataStart = b.t0
			if h.first and h.first > dataStart then dataStart = h.first end
			if from > dataStart then
				local span = b.t0 + M.BUCKET_MS - dataStart
				weight = span > 0 and math.max(0, (b.t0 + M.BUCKET_MS - from) / span) or 0
			end
			local perSecond = (b.r or 0) / yearMs * 1000
			for k, v in pairs(b.t or {}) do
				local sec = v * weight
				out.t[k] = (out.t[k] or 0) + sec
				local cost = sec * factorOf(k) * perSecond
				out.c[k] = (out.c[k] or 0) + cost
				out.total = out.total + cost
			end
			out.s = out.s + (b.s or 0) * weight
		end
	end
	out.total = out.total + out.s
	if oldest ~= nil then
		local begin = math.max(oldest, from)
		if h.first and h.first > begin then begin = h.first end
		out.cov = math.min(windowMs, nowMs - begin)
	end
	return out
end

return M
